//! OpenAlias resolver with end-to-end DNSSEC validation, routed over Tor's
//! SOCKS proxy. DNS is fetched via TCP through the proxy (Tor has no UDP) and
//! validated locally by hickory (RRSIG → DS → root trust anchor), so no
//! resolver is trusted and no DNS leaks outside Tor.
//!
//! The FFI surface is deliberately thin: it returns the DNSSEC-validated TXT
//! records at a name, and Dart parses the OpenAlias v1 and v2 grammars on top
//! (see `lib/src/openalias_records.dart`). That split keeps the record parsing
//! and selection unit-testable without a native build, while the part that has
//! to be trustworthy — "these bytes really are what the signed zone published"
//! — stays here.

mod error;

use std::ffi::{c_char, CStr, CString};
use std::future::Future;
use std::io;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hickory_proto::dnssec::rdata::RRSIG;
use hickory_proto::dnssec::Proof;
use hickory_proto::rr::{Name, RData, Record, RecordType};
use hickory_resolver::config::{NameServerConfig, ResolverConfig, ResolverOpts};
use hickory_resolver::net::runtime::iocompat::AsyncIoTokioAsStd;
use hickory_resolver::net::runtime::{RuntimeProvider, TokioHandle, TokioTime};
use hickory_resolver::net::{DnsError, NetError};
use hickory_resolver::Resolver;
use lazy_static::lazy_static;
use tokio::net::{TcpStream as TokioTcpStream, UdpSocket as TokioUdpSocket};
use tokio::runtime::{Builder, Runtime};
use tokio_socks::tcp::Socks5Stream;

use crate::error::set_last_error;

lazy_static! {
    static ref RUNTIME: io::Result<Runtime> = Builder::new_multi_thread().enable_all().build();

    /// Resolvers already built, keyed by the SOCKS port they dial through.
    ///
    /// One alias resolution asks for three names at once (the two OA2 prefixes
    /// and the bare FQDN), each from its own Dart isolate but all in this
    /// process. Building a resolver per query made each of them open its own
    /// DoH connection through Tor and validate the whole chain from the root
    /// down, so the shared part of that chain was fetched three times over.
    ///
    /// Sharing one resolver gives them a connection pool and a DNSSEC cache in
    /// common: the root, TLD and domain keys are fetched once, and a repeat
    /// lookup inside the record TTL costs nothing.
    ///
    /// Keyed by port so that turning Tor on or off, or a restarted Tor picking
    /// a new port, builds a fresh one rather than dialing a dead proxy.
    static ref RESOLVERS: Mutex<HashMap<u16, Arc<Resolver<SocksRuntimeProvider>>>> =
        Mutex::new(HashMap::new());
}

/// Public recursive resolvers queried (over Tor) for the signed records, as
/// DNS-over-HTTPS (port 443) — Tor exits reject plain DNS (53). They only
/// transport the signed data — validation happens locally — so a malicious
/// resolver can withhold an answer but cannot forge one. Each entry is the
/// resolver IP and the TLS/host name used for its certificate + DoH endpoint.
///
/// "Cannot forge one" is a claim about [`secure_txt_answers`] as much as about
/// DNSSEC: a signature chain to the root says who signed a record, and it takes
/// a check of its own to establish that they were entitled to answer for the
/// name that was asked. Read that function before touching this one.
const UPSTREAMS: &[(Ipv4Addr, &str)] = &[
    (Ipv4Addr::new(9, 9, 9, 9), "dns.quad9.net"),
    (Ipv4Addr::new(1, 1, 1, 1), "cloudflare-dns.com"),
];

/// Per-upstream-query deadline, handed to hickory.
const TCP_TIMEOUT: Duration = Duration::from_secs(30);

/// Deadline for one whole call to [`secure_txt`].
///
/// [`TCP_TIMEOUT`] bounds a *single* query to a *single* upstream, which is not
/// the same thing and was the only bound there was. One alias lookup fans out
/// into a chain — the TXT query, then the DNSKEY and DS records at every zone cut
/// from the name up to the root, each retried across two upstreams — and every
/// one of those restarts its own 30 seconds. A slow or deliberately-stalling
/// nameserver could hold a resolution open for as long as it liked, over Tor,
/// with nothing above it counting: the Dart side has no timeout either, and the
/// FFI takes no timeout argument to honour.
///
/// 60s is a whole-operation ceiling, not a tuning knob: DNS over Tor is slow
/// enough that a chain of legitimate queries can take tens of seconds, and a
/// user staring at a spinner needs an answer eventually more than they need one
/// fast. Anything past this is reported as a timeout rather than absence.
const OVERALL_TIMEOUT: Duration = Duration::from_secs(60);

/// Earliest system clock reading at which DNSSEC validation is attempted:
/// 2026-01-01T00:00:00Z.
///
/// RRSIG validity is a pair of absolute timestamps, so validation is only as
/// honest as the clock. Two failure modes, both real on mobile:
///
///   - **Rolled back.** Set the clock far enough into the past and expired
///     signatures verify again, which lets an attacker replay a correctly-signed
///     answer whose key has since been rotated or revoked. hickory takes the
///     system time as given and has no opinion about whether it is plausible.
///   - **Before the epoch.** A device with a dead battery can come up at or
///     before 1970. `duration_since(UNIX_EPOCH)` then fails, and the arithmetic
///     built on it in the validation path is where a panic comes from — which,
///     before [`ffi_guard`], took the whole wallet process down.
///
/// A fixed constant rather than the build time on purpose: embedding the build
/// time would make the artifact non-reproducible, and F-Droid rebuilds this from
/// source (D12/D14). It only has to be far enough in the past to be certainly
/// true and recent enough to catch a grossly wrong clock; it never needs bumping
/// for correctness, only for tightness.
const MIN_PLAUSIBLE_UNIX_TIME: u64 = 1767225600;

/// A hickory runtime provider whose TCP connections are dialed through a
/// SOCKS5 proxy (Tor). UDP is unused (resolver is configured TCP-only).
#[derive(Clone)]
struct SocksRuntimeProvider {
    proxy: SocketAddr,
    // A persistent handle whose JoinSet outlives the spawned connection driver.
    // Returning a fresh TokioHandle per call would drop the JoinSet and abort
    // the h2 driver task → "receiver was canceled". hickory's own provider keeps
    // one shared handle for exactly this reason.
    handle: TokioHandle,
}

impl RuntimeProvider for SocksRuntimeProvider {
    type Handle = TokioHandle;
    type Timer = TokioTime;
    type Udp = TokioUdpSocket;
    type Tcp = AsyncIoTokioAsStd<Socks5Stream<TokioTcpStream>>;

    fn create_handle(&self) -> Self::Handle {
        self.handle.clone()
    }

    fn connect_tcp(
        &self,
        server_addr: SocketAddr,
        _bind_addr: Option<SocketAddr>,
        _timeout: Option<Duration>,
    ) -> Pin<Box<dyn Send + Future<Output = io::Result<Self::Tcp>>>> {
        let proxy = self.proxy;
        Box::pin(async move {
            let stream = Socks5Stream::connect(proxy, server_addr)
                .await
                .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
            Ok(AsyncIoTokioAsStd(stream))
        })
    }

    fn bind_udp(
        &self,
        _local_addr: SocketAddr,
        _server_addr: SocketAddr,
    ) -> Pin<Box<dyn Send + Future<Output = io::Result<Self::Udp>>>> {
        // Refused, never bound. Tor carries no UDP, so a UDP query could only
        // leave over clearnet. The resolver is configured with DoH name servers
        // exclusively and never asks for UDP; failing here means that if that
        // ever changed, the lookup would fail closed instead of leaking which
        // alias the user is resolving.
        Box::pin(async move {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "UDP is unavailable: OpenAlias DNS must go through the Tor SOCKS proxy",
            ))
        })
    }
}

/// Fetches the TXT records at `name` over Tor, requiring a DNSSEC-secure answer.
///
/// Three outcomes, and the caller must keep them apart:
///
///   - **A JSON array of strings** — one entry per TXT record, each already
///     concatenated from its DNS character-strings (RFC 7208 §3.3). Every record
///     was owned by `name` and proved Secure.
///   - **An empty JSON array** — DNSSEC *proved* there is nothing here: a
///     validated NSEC/NSEC3 denial of existence. Not "we found nothing".
///   - **NULL** — nothing could be established, with a reason in
///     `openalias_last_error_message`. Covers a timeout, a reset, SERVFAIL, a
///     denial that failed to validate, an unsigned zone, and an answer that was
///     not an answer to the question.
///
/// The distinction is load-bearing, not cosmetic. The OpenAlias v2 → v1 fallback
/// is only correct when the recipient publishes no v2 record, so it must be
/// driven by the empty array and never by NULL — otherwise anything that can
/// break one connection (a hostile Tor exit needs no more than a reset) forces
/// this wallet back to a v1 address the recipient may have superseded.
///
/// Caller frees the returned string with `openalias_string_free`.
///
/// # Safety
/// `name` must be a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn openalias_secure_txt(
    name: *const c_char,
    socks_port: u16,
) -> *mut c_char {
    ffi_guard("openalias_secure_txt", std::ptr::null_mut(), || unsafe {
        secure_txt_entry(name, socks_port)
    })
}

/// The body of [`openalias_secure_txt`], separated so the guard above wraps
/// every path out of it including the ones that panic.
///
/// # Safety
/// `name` must be a valid NUL-terminated C string.
unsafe fn secure_txt_entry(name: *const c_char, socks_port: u16) -> *mut c_char {
    let name = match cstr(name) {
        Some(s) => s,
        None => return ret_err("invalid name"),
    };

    let runtime = match RUNTIME.as_ref() {
        Ok(rt) => rt,
        Err(e) => return ret_err(format!("tokio runtime: {e}")),
    };

    match runtime.block_on(secure_txt(&name, socks_port)) {
        Ok(records) => match CString::new(json_string_array(&records)) {
            Ok(c) => c.into_raw(),
            Err(_) => ret_err("record contained NUL"),
        },
        Err(msg) => ret_err(msg),
    }
}

/// Frees a string returned by this library.
///
/// # Safety
/// `ptr` must have been returned by this library and not already freed.
#[no_mangle]
pub unsafe extern "C" fn openalias_string_free(ptr: *mut c_char) {
    ffi_guard("openalias_string_free", (), || unsafe {
        if !ptr.is_null() {
            drop(CString::from_raw(ptr));
        }
    });
}

/// Runs `body`, converting a panic into `on_panic` instead of letting it cross
/// the FFI boundary.
///
/// A panic that reaches an `extern "C"` frame does not unwind into the caller —
/// it aborts the process. So any panic anywhere under here took the whole wallet
/// down: no error, no dialog, no chance to save state. That matters more than
/// usual because of *what* is under here. This crate parses DNS wire data and
/// drives a TLS stack, and the bytes come from a DNS answer an attacker can
/// influence; a bad slice index or an overflow in that stack is otherwise a
/// remote app-kill with no memory-safety bug required.
///
/// This is a seatbelt, not a fix: a panic here is still a defect worth chasing.
/// What it buys is that the defect surfaces as a failed alias lookup, which the
/// Dart side already treats as "could not resolve".
///
/// **Only effective while this crate unwinds.** Building with
/// `panic = "abort"` makes `catch_unwind` a no-op and restores the old
/// behaviour; `Cargo.toml` deliberately sets no `panic` profile key.
fn ffi_guard<T>(function: &'static str, on_panic: T, body: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => value,
        Err(payload) => {
            // Only a `&'static str` payload is quoted, because those are
            // literals in source. A `String` payload was formatted at panic time
            // and can interpolate the data being parsed — which here is an
            // attacker-supplied DNS answer, and `docs/logging.md` rule 5 keeps
            // that out of logs. The function name is the diagnostic part.
            let detail = payload
                .downcast_ref::<&'static str>()
                .copied()
                .unwrap_or("panic payload withheld (not a static string)");
            set_last_error(format!("{function} panicked: {detail}"));
            on_panic
        }
    }
}

/// Refuses to validate against a system clock that cannot be right.
///
/// See [`MIN_PLAUSIBLE_UNIX_TIME`] for why. Split from [`check_clock`] so the
/// boundaries are testable without touching the real clock.
fn check_clock_at(now: SystemTime) -> Result<(), String> {
    let unix = now.duration_since(UNIX_EPOCH).map_err(|_| {
        "the system clock reads a time before 1970, so DNSSEC signature validity \
             cannot be checked. Set the device clock and try again."
            .to_string()
    })?;
    if unix.as_secs() < MIN_PLAUSIBLE_UNIX_TIME {
        return Err(
            "the system clock is too far in the past for DNSSEC signature validity to \
             mean anything (an expired signature would verify). Set the device clock \
             and try again."
                .to_string(),
        );
    }
    Ok(())
}

fn check_clock() -> Result<(), String> {
    check_clock_at(SystemTime::now())
}

/// The resolver dialing through `socks_port`, building it on first use.
///
/// See [`RESOLVERS`] for why this is shared rather than built per query.
fn resolver_for(socks_port: u16) -> Result<Arc<Resolver<SocksRuntimeProvider>>, String> {
    let mut cache = RESOLVERS
        .lock()
        .map_err(|_| "resolver cache poisoned".to_string())?;
    if let Some(existing) = cache.get(&socks_port) {
        return Ok(Arc::clone(existing));
    }

    let proxy = SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), socks_port);

    // DNS-over-HTTPS (default /dns-query on 443). The TLS cert is verified
    // against `host`; the answer's DNSSEC chain is validated locally.
    let name_servers = UPSTREAMS
        .iter()
        .map(|(ip, host)| NameServerConfig::https(IpAddr::V4(*ip), Arc::from(*host), None))
        .collect();
    let config = ResolverConfig::from_parts(None, vec![], name_servers);

    let mut opts = ResolverOpts::default();
    opts.validate = true; // local DNSSEC validation against the root trust anchor
    opts.timeout = TCP_TIMEOUT;

    let provider = SocksRuntimeProvider { proxy, handle: TokioHandle::default() };
    let resolver = Arc::new(
        Resolver::builder_with_config(config, provider)
            .with_options(opts)
            .build()
            .map_err(|e| format!("resolver build failed: {e}"))?,
    );
    cache.insert(socks_port, Arc::clone(&resolver));
    Ok(resolver)
}

/// The TXT records at `name`, or an empty vector when their absence was proved.
///
/// Those are different answers and only two call sites may produce them: the
/// `Ok` arm below never returns an empty vector — [`secure_txt_answers`] fails
/// instead — so an empty vector means the denial arm and nothing else.
async fn secure_txt(name: &str, socks_port: u16) -> Result<Vec<String>, String> {
    // Before anything is built or any circuit opened: a clock this wrong makes
    // every signature check downstream meaningless, so there is no point paying
    // for the lookup.
    check_clock()?;

    let resolver = resolver_for(socks_port)?;

    // Non-ASCII labels are converted to their A-label (Punycode) form by
    // hickory when it parses the name, as OpenAlias requires (RFC 5890).
    // Parsed once and reused: the same value is both what gets asked and what
    // the answer is checked against, so the two cannot drift apart.
    let fqdn = if name.ends_with('.') { name.to_string() } else { format!("{name}.") };
    let fqdn = Name::from_utf8(&fqdn).map_err(|e| format!("not a DNS name: {e}"))?;

    // hickory retries on its own before this resolves: `attempts` defaults to 2
    // and both upstreams are in the pool, so a single dropped connection is
    // already retried rather than reported.
    let lookup = match tokio::time::timeout(
        OVERALL_TIMEOUT,
        resolver.lookup(fqdn.clone(), RecordType::TXT),
    )
    .await
    {
        Ok(result) => result,
        // Unknown, emphatically not absent: a timeout must not drive the
        // OA2 → OA1 fallback, or stalling one query would be enough to walk a
        // recipient back to a v1 address they may have superseded.
        Err(_) => {
            return Err(format!(
                "resolving {} did not finish within {}s",
                fqdn.to_ascii(),
                OVERALL_TIMEOUT.as_secs()
            ))
        }
    };

    match lookup {
        Ok(lookup) => secure_txt_answers(&fqdn, lookup.answers()),

        // "There are no records here" — but only trustworthy if the zone said so
        // and signed it. hickory reaches this variant *through* the DNSSEC
        // handler: `verify_response` turns a negative answer back into a message,
        // validates the NSEC/NSEC3 denial, and hands back `Nsec` (below) when the
        // proof fails. So the only thing left to separate here is a validated
        // denial from a zone that is provably not signed at all.
        Err(NetError::Dns(DnsError::NoRecordsFound(no_records))) => {
            let authorities = no_records.authorities.as_deref().unwrap_or(&[]);
            if denial_is_proven(&fqdn, authorities) {
                Ok(Vec::new())
            } else {
                // Fails closed rather than reading as absence, and says which it
                // is: an unsigned domain publishes nothing this resolver can use
                // — at this name or at the alias itself — which is a different
                // thing to tell the user than "publishes no v2 record". The
                // second clause covers the corner where an answer came back that
                // did not answer the question and left no denial either.
                Err(format!(
                    "nothing was proved about {}: no signed denial of existence \
                     (the zone is unsigned, or the answer did not answer the query)",
                    fqdn.to_ascii()
                ))
            }
        }

        // A denial of existence that did not validate. Never absence: this is
        // what a stripped or forged NSEC looks like.
        Err(NetError::Dns(DnsError::Nsec { proof, .. })) => Err(format!(
            "denial of existence for {} is not DNSSEC-secure (proof={proof:?})",
            fqdn.to_ascii()
        )),

        // Timeout, reset, Refused, SERVFAIL, TLS failure: unknown, not absent.
        Err(e) => Err(format!("lookup failed: {e}")),
    }
}

/// Whether a "no records" answer carried a validated denial of existence
/// **from a zone entitled to deny `name`**.
///
/// Reaching `NoRecordsFound` at all under `validate = true` means the denial
/// either validated or the zone was proved insecure. Telling those apart needs
/// a Secure NSEC/NSEC3 record — but that alone is what [`secure_txt_answers`]
/// exists to explain is not enough. `Proof::Secure` says "someone whose key
/// chains to the root signed this"; it does not say they were entitled to speak
/// about the name that was asked. This function used to ask only the first
/// question, and did not even take `name` as an argument, so a denial signed by
/// any attacker-controlled signed zone was accepted as proof that a recipient
/// publishes no OpenAlias record.
///
/// What that forges is a *suppression*, not a redirection — an attacker cannot
/// point a payment somewhere with it. But it drives the OA2 → OA1 fallback and,
/// together with a silent `_openalias-metadata` failure, the lookalike-name
/// defence, so a forged absence is worth refusing.
///
/// Two differences from its sibling on the positive path, both deliberate:
///
///   - **The owner name is not checked**, because it is not supposed to match. An
///     NSEC is owned by the name that sorts immediately before the queried one,
///     and an NSEC3 by a hashed label under the zone apex; neither equals
///     `name`. The RRSIG's signer name is the only trustworthy statement of
///     which zone this denial came from — hickory's own `soa_name` is derived
///     from the first SOA owner in the section with no proof check at all, so a
///     fabricated unsigned SOA passes it and omitting the SOA leaves nothing to
///     check.
///   - **Every covering RRSIG must be in bailiwick, not just one.** Same reason
///     as the positive path: hickory takes the first signature that verifies, so
///     an attacker's RRSIG sitting beside an honest one could be the one that
///     counted. The cost is that injecting a foreign signature turns a real
///     denial into "unknown" — a fail-closed denial of service, which is the
///     right way round.
fn denial_is_proven(name: &Name, authorities: &[Record]) -> bool {
    let mut covering_rrsigs = 0usize;
    for record in authorities {
        let Some(rrsig) = record.try_borrow::<RRSIG>() else { continue };
        let input = rrsig.data().input();
        if !matches!(input.type_covered, RecordType::NSEC | RecordType::NSEC3) {
            continue;
        }
        covering_rrsigs += 1;
        if !input.signer_name.zone_of(name) {
            return false;
        }
    }

    // No signature over the denial at all. Unreachable while a Secure proof
    // implies a verified RRSIG, and here for the same reason as the positive
    // path's equivalent: were a later hickory to stop returning the RRSIGs it
    // verified, the signer check above would quietly become a no-op and the
    // forgery it exists to stop would work again. (Checked against 0.26.1:
    // `verify_rrsets` pushes every RRSIG back into the records it returns, and
    // `NoRecordsFound` carries the post-validation authority section.)
    if covering_rrsigs == 0 {
        return false;
    }

    authorities.iter().any(|record| {
        record.proof == Proof::Secure
            && matches!(record.record_type(), RecordType::NSEC | RecordType::NSEC3)
    })
}

/// The TXT records in `answers` that are an answer to the question asked about
/// `name`, or why there are none.
///
/// `Proof::Secure` says "this RRset has a signature chain to the root trust
/// anchor". It does **not** say "this RRset is what you asked for", and on
/// hickory 0.26.1's stub-resolver path neither of the two checks that would
/// close that gap is performed:
///
///   - The answer section comes back as the server sent it. `handle_noerror`
///     rewrites it only when a CNAME had to be followed, so in the ordinary case
///     an RRset at *any* owner name rides along, and `verify_rrsets` groups by
///     `(name, type)` and validates each group on its own.
///   - RFC 4035 §5.3.1 requires an RRSIG's signer name to be the zone that
///     contains the RRset. `RrsigValidity::check` does not implement it — the
///     rule is there as a `TODO` — so an RRset at our *exact* name, signed by
///     some other zone whose DNSKEY chains to the root, also proves Secure.
///
/// Either gap on its own is enough for anyone who owns one DNSSEC-signed domain
/// and can inject into a DoH answer to replace the address this returns, which
/// is precisely the attacker the module header describes: the upstreams are
/// public resolvers trusted to carry bytes and nothing else.
///
/// So a record is used only when all three hold — it is a TXT record owned by
/// exactly `name`, its RRset proved Secure, and every RRSIG offered over that
/// RRset was made from inside a zone that contains `name`.
fn secure_txt_answers(name: &Name, answers: &[Record]) -> Result<Vec<String>, String> {
    // `zone_of` is ancestor-or-equal, which is as close to §5.3.1 as a stub can
    // get: the zone cut is in the SOA, and this answer need not carry one. It
    // still leaves a parent zone able to sign for a delegated child — inherent
    // to DNSSEC, since a parent can replace the child's DS anyway — while
    // rejecting the signer that matters here, an unrelated domain.
    //
    // *Every* RRSIG, not "at least one in bailiwick": hickory takes the first
    // signature that verifies, so one honest-looking RRSIG next to the
    // attacker's would let theirs be the one that counted.
    let mut covering_rrsigs = 0usize;
    for record in answers {
        let Some(rrsig) = record.try_borrow::<RRSIG>() else { continue };
        let input = rrsig.data().input();
        if &record.name != name || input.type_covered != RecordType::TXT {
            continue;
        }
        covering_rrsigs += 1;
        if !input.signer_name.zone_of(name) {
            return Err(format!(
                "TXT records at {} carry an RRSIG signed by {}, which is not a zone containing it",
                name.to_ascii(),
                // Attacker-chosen, and this reaches a send screen: the A-label
                // form is ASCII, so it cannot smuggle bidi or control characters.
                clip(&input.signer_name.to_ascii()),
            ));
        }
    }

    let mut records = Vec::new();
    let mut other_names = 0usize;
    for record in answers {
        let RData::TXT(txt) = &record.data else { continue };
        if &record.name != name {
            other_names += 1;
            continue;
        }
        if record.proof != Proof::Secure {
            // Fail closed, and note what this covers: hickory's `validate`
            // rejects only *bogus* answers on its own, so an unsigned zone still
            // hands back records proven Insecure. This is the check that turns
            // "not signed" into "no answer".
            return Err(format!(
                "TXT records at {} are not DNSSEC-secure (proof={:?})",
                name.to_ascii(),
                record.proof
            ));
        }
        // A TXT record is one or more character-strings; concatenate them in
        // order, with no separator, before the record is parsed.
        records.push(
            txt.txt_data
                .iter()
                .map(|b| String::from_utf8_lossy(b).into_owned())
                .collect::<String>(),
        );
    }

    if records.is_empty() {
        // A CNAME'd alias lands here: hickory follows the chain and returns the
        // target's records, owned by the target's name. Rejecting that is
        // deliberate — the chain is not in this answer, so it cannot be checked
        // — and it is reported separately from a name that simply has no TXT.
        return Err(match other_names {
            0 => format!("no TXT records at {}", name.to_ascii()),
            n => format!(
                "no TXT records at {} ({n} TXT record(s) in the answer belong to other names)",
                name.to_ascii()
            ),
        });
    }
    if covering_rrsigs == 0 {
        // Unreachable while a Secure proof implies a verified RRSIG, and here on
        // purpose: were a later hickory to strip RRSIGs from the answers it
        // returns, the signer check above would quietly become a no-op and the
        // forgery it exists to stop would work again. Fail instead.
        return Err(format!(
            "TXT records at {} arrived with no RRSIG covering them",
            name.to_ascii()
        ));
    }
    Ok(records)
}

/// Bounds a value quoted in an error message. Mirrors `_clip` on the Dart side.
fn clip(value: &str) -> String {
    match value.char_indices().nth(64) {
        Some((cut, _)) => format!("{}…", &value[..cut]),
        None => value.to_string(),
    }
}

/// Encodes `items` as a JSON array of strings. TXT records are attacker-chosen
/// bytes, so they are escaped rather than framed with a separator that a record
/// could contain.
fn json_string_array(items: &[String]) -> String {
    let mut out = String::from("[");
    for (i, item) in items.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        json_escape_into(item, &mut out);
    }
    out.push(']');
    out
}

fn json_escape_into(s: &str, out: &mut String) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

unsafe fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string())
}

fn ret_err(msg: impl Into<String>) -> *mut c_char {
    set_last_error(msg);
    std::ptr::null_mut()
}

#[cfg(test)]
mod tests {
    use super::{
        check_clock_at, denial_is_proven, ffi_guard, json_string_array, resolver_for,
        secure_txt_answers, MIN_PLAUSIBLE_UNIX_TIME, OVERALL_TIMEOUT, TCP_TIMEOUT,
    };
    use crate::error::take_last_error;

    use std::ffi::c_char;
    use std::panic;
    use std::sync::Arc;
    use std::ptr;
    use std::time::{Duration, UNIX_EPOCH};

    use hickory_proto::dnssec::rdata::{DNSSECRData, SigInput, NSEC, RRSIG};
    use hickory_proto::dnssec::{Algorithm, Proof};
    use hickory_proto::rr::rdata::{TXT, SOA};
    use hickory_proto::rr::{Name, RData, Record, RecordType, SerialNumber};

    const ALIAS: &str = "_openalias-payment.donate.example.org.";

    fn name(s: &str) -> Name {
        Name::from_utf8(s).expect("test name parses")
    }

    /// A TXT record with the proof hickory would have attached to it.
    fn txt(owner: &str, text: &str, proof: Proof) -> Record {
        let mut record = Record::from_rdata(name(owner), 300, RData::TXT(TXT::new(vec![
            text.to_string(),
        ])));
        record.proof = proof;
        record
    }

    /// An RRSIG over the TXT RRset at `owner`, made by `signer`, marked the way
    /// hickory marks the signature it verified with.
    ///
    /// The signature bytes are never looked at — what is under test is the check
    /// that hickory does not make, that the signer was entitled to sign for this
    /// owner name. A real attacker's signature verifies; that is the point.
    fn rrsig(owner: &str, signer: &str) -> Record {
        let mut record = unproven_rrsig(owner, signer);
        record.proof = Proof::Secure;
        record
    }

    /// An RRSIG hickory did not use — a second signature over the same RRset,
    /// which keeps the proof a parsed record starts with. Ordinary during a key
    /// or algorithm rollover.
    fn unproven_rrsig(owner: &str, signer: &str) -> Record {
        rrsig_covering(owner, signer, RecordType::TXT)
    }

    /// An RRSIG over `covered` at `owner`, made by `signer`, unproven.
    fn rrsig_covering(owner: &str, signer: &str, covered: RecordType) -> Record {
        let input = SigInput {
            type_covered: covered,
            algorithm: Algorithm::ED25519,
            num_labels: name(owner).num_labels(),
            original_ttl: 300,
            sig_expiration: SerialNumber::new(u32::MAX),
            sig_inception: SerialNumber::new(0),
            key_tag: 1234,
            signer_name: name(signer),
        };
        Record::from_rdata(
            name(owner),
            300,
            RData::DNSSEC(DNSSECRData::RRSIG(RRSIG::from_sig(input, vec![0u8; 64]))),
        )
    }

    #[test]
    fn accepts_a_signed_answer_at_the_queried_name() {
        let answers = [
            txt(ALIAS, "oa_version=2; network=xmr; address=888real;", Proof::Secure),
            rrsig(ALIAS, "example.org."),
        ];
        assert_eq!(
            secure_txt_answers(&name(ALIAS), &answers),
            Ok(vec!["oa_version=2; network=xmr; address=888real;".to_string()])
        );
    }

    #[test]
    fn ignores_a_secure_rrset_at_another_name() {
        // The injected RRset: signed by a zone the attacker really controls, so
        // Secure, and never an answer to what was asked. Before the owner-name
        // check this was returned alongside the genuine record, and `priority=0`
        // put it first on the send screen.
        let answers = [
            txt(ALIAS, "oa_version=2; network=xmr; address=888real;", Proof::Secure),
            rrsig(ALIAS, "example.org."),
            txt(
                "oa.attacker.test.",
                "oa_version=2; network=xmr; address=888evil; priority=0;",
                Proof::Secure,
            ),
            rrsig("oa.attacker.test.", "attacker.test."),
        ];
        assert_eq!(
            secure_txt_answers(&name(ALIAS), &answers),
            Ok(vec!["oa_version=2; network=xmr; address=888real;".to_string()])
        );
    }

    #[test]
    fn rejects_a_foreign_signer_at_the_queried_name() {
        // The forgery hickory 0.26.1 accepts: the owner name is ours, the signer
        // is not, and RFC 4035 §5.3.1's signer-name rule is the check it skips.
        let answers = [
            txt(ALIAS, "oa_version=2; network=xmr; address=888evil;", Proof::Secure),
            rrsig(ALIAS, "attacker.test."),
        ];
        let err = secure_txt_answers(&name(ALIAS), &answers).expect_err("must not resolve");
        assert!(err.contains("attacker.test"), "{err}");
    }

    #[test]
    fn rejects_a_foreign_signer_hidden_behind_an_honest_one() {
        // hickory takes the first RRSIG that verifies, so "some RRSIG here is in
        // bailiwick" proves nothing about the one that counted.
        let answers = [
            txt(ALIAS, "oa_version=2; network=xmr; address=888evil;", Proof::Secure),
            rrsig(ALIAS, "example.org."),
            rrsig(ALIAS, "attacker.test."),
        ];
        assert!(secure_txt_answers(&name(ALIAS), &answers).is_err());
    }

    #[test]
    fn accepts_a_second_signature_from_within_the_zone() {
        // Two RRSIGs over one RRset is ordinary — a ZSK or algorithm rollover —
        // and only the one hickory verified with is marked Secure; the other keeps
        // the proof it was parsed with. So the proof check has to be about the
        // records being returned. Applying it to the whole answer section, as
        // this did before, rejected every rolling zone outright.
        let answers = [
            txt(ALIAS, "oa_version=2; network=xmr; address=888real;", Proof::Secure),
            rrsig(ALIAS, "example.org."),
            unproven_rrsig(ALIAS, "example.org."),
        ];
        assert!(secure_txt_answers(&name(ALIAS), &answers).is_ok());
    }

    #[test]
    fn rejects_an_unsigned_or_bogus_rrset() {
        for proof in [Proof::Insecure, Proof::Bogus, Proof::Indeterminate] {
            let answers = [
                txt(ALIAS, "oa_version=2; network=xmr; address=888evil;", proof),
                rrsig(ALIAS, "example.org."),
            ];
            assert!(
                secure_txt_answers(&name(ALIAS), &answers).is_err(),
                "{proof:?} must not resolve"
            );
        }
    }

    #[test]
    fn rejects_a_secure_rrset_with_no_signature_in_the_answer() {
        // Guards the guard: if RRSIGs ever stop reaching us, the signer check
        // above silently passes on every answer.
        let answers = [txt(ALIAS, "oa_version=2; network=xmr; address=888real;", Proof::Secure)];
        assert!(secure_txt_answers(&name(ALIAS), &answers).is_err());
    }

    #[test]
    fn reports_a_cname_target_separately_from_an_empty_name() {
        let followed = [
            txt("oa.provider.test.", "oa1:xmr recipient_address=888;", Proof::Secure),
            rrsig("oa.provider.test.", "provider.test."),
        ];
        let err = secure_txt_answers(&name(ALIAS), &followed).expect_err("must not resolve");
        assert!(err.contains("belong to other names"), "{err}");

        let empty: [Record; 0] = [];
        let err = secure_txt_answers(&name(ALIAS), &empty).expect_err("must not resolve");
        assert!(err.contains("no TXT records"), "{err}");
        assert!(!err.contains("belong to other names"), "{err}");
    }

    #[test]
    fn matches_the_owner_name_case_insensitively() {
        // DNS names are case-insensitive, and a server may echo them in any case
        // (0x20 encoding does this deliberately).
        let answers = [
            txt("_OpenAlias-Payment.Donate.Example.ORG.", "oa1:xmr recipient_address=888;", Proof::Secure),
            rrsig("_openalias-payment.DONATE.example.org.", "EXAMPLE.org."),
        ];
        assert!(secure_txt_answers(&name(ALIAS), &answers).is_ok());
    }

    /// An NSEC record in an authority section, with the proof hickory would have
    /// left on it.
    fn nsec(owner: &str, proof: Proof) -> Record {
        let mut record = Record::from_rdata(
            name(owner),
            300,
            RData::DNSSEC(DNSSECRData::NSEC(NSEC::new(
                name("zz.example.org."),
                [RecordType::A, RecordType::RRSIG, RecordType::NSEC],
            ))),
        );
        record.proof = proof;
        record
    }

    /// The RRSIG a zone publishes over its NSEC, marked the way hickory marks the
    /// signature it verified with.
    fn nsec_rrsig(owner: &str, signer: &str) -> Record {
        let mut record = rrsig_covering(owner, signer, RecordType::NSEC);
        record.proof = Proof::Secure;
        record
    }

    /// The authority section of a genuine validated denial for [`ALIAS`]: the
    /// zone's SOA, the covering NSEC, and the signature over it.
    fn proven_denial() -> Vec<Record> {
        vec![
            soa("example.org.", Proof::Secure),
            nsec("donate.example.org.", Proof::Secure),
            nsec_rrsig("donate.example.org.", "example.org."),
        ]
    }

    fn soa(owner: &str, proof: Proof) -> Record {
        let mut record = Record::from_rdata(
            name(owner),
            300,
            RData::SOA(SOA::new(
                name("ns.example.org."),
                name("hostmaster.example.org."),
                1,
                7200,
                600,
                3600000,
                300,
            )),
        );
        record.proof = proof;
        record
    }

    #[test]
    fn a_validated_denial_is_proven_absence() {
        // The state the OA2 → OA1 fallback exists for: an OA1-only recipient has
        // no `_openalias-payment` name, and their signed zone proves it.
        assert!(denial_is_proven(&name(ALIAS), &proven_denial()));
    }

    #[test]
    fn an_unsigned_zone_is_not_proven_absence() {
        // Nothing was proved, so nothing may be inferred — least of all that it
        // is safe to pay a v1 record from the same unsigned zone.
        let alias = name(ALIAS);
        assert!(!denial_is_proven(&alias, &[soa("example.org.", Proof::Insecure)]));
        assert!(!denial_is_proven(&alias, &[nsec("donate.example.org.", Proof::Insecure)]));
        assert!(!denial_is_proven(&alias, &[]));
    }

    #[test]
    fn a_secure_soa_alone_is_not_proven_absence() {
        // A signed SOA says the zone exists, not that the name does not. Only the
        // NSEC/NSEC3 chain denies a name.
        assert!(!denial_is_proven(&name(ALIAS), &[soa("example.org.", Proof::Secure)]));
    }

    #[test]
    fn rejects_a_denial_signed_by_a_foreign_zone() {
        // The forgery this check exists for, and the exact shape the positive
        // path already refuses. Everything here is genuinely Secure — the
        // attacker owns `attacker.example.net` and signed it properly — and none
        // of it says anything about `example.org`.
        let answers = vec![
            soa("attacker.example.net.", Proof::Secure),
            nsec("donate.example.org.", Proof::Secure),
            nsec_rrsig("donate.example.org.", "attacker.example.net."),
        ];
        assert!(!denial_is_proven(&name(ALIAS), &answers));
    }

    #[test]
    fn rejects_a_foreign_signed_denial_hidden_behind_an_honest_one() {
        // hickory takes the first signature that verifies, so "at least one in
        // bailiwick" would let the attacker's be the one that counted. Both
        // orderings, because "first" is not something this code should depend on.
        let honest = nsec_rrsig("donate.example.org.", "example.org.");
        let foreign = nsec_rrsig("donate.example.org.", "attacker.example.net.");
        let alias = name(ALIAS);

        for pair in [
            vec![honest.clone(), foreign.clone()],
            vec![foreign.clone(), honest.clone()],
        ] {
            let mut answers = vec![
                soa("example.org.", Proof::Secure),
                nsec("donate.example.org.", Proof::Secure),
            ];
            answers.extend(pair);
            assert!(!denial_is_proven(&alias, &answers));
        }
    }

    #[test]
    fn an_unsigned_soa_does_not_establish_the_denying_zone() {
        // hickory's own zone check derives the zone from the first SOA owner name
        // with no proof check at all, so a fabricated SOA passes it. The signer
        // name on the signature is what this function trusts instead, and here
        // there is none.
        let answers = vec![
            soa("example.org.", Proof::Insecure),
            nsec("donate.example.org.", Proof::Secure),
        ];
        assert!(!denial_is_proven(&name(ALIAS), &answers));
    }

    #[test]
    fn a_denial_with_no_signature_at_all_is_not_proven() {
        // Guards the guard: if a future hickory stopped returning the RRSIGs it
        // verified, the signer check would silently become a no-op. Then this
        // fails instead.
        let answers = vec![
            soa("example.org.", Proof::Secure),
            nsec("donate.example.org.", Proof::Secure),
        ];
        assert!(!denial_is_proven(&name(ALIAS), &answers));
    }

    #[test]
    fn a_parent_zone_may_deny_a_name_in_its_child() {
        // `zone_of` is ancestor-or-equal, the same latitude the positive path
        // takes: a parent can replace a child's DS anyway, so refusing it would
        // buy nothing and would break a name denied at a zone cut above it.
        let answers = vec![
            soa("example.org.", Proof::Secure),
            nsec("donate.example.org.", Proof::Secure),
            nsec_rrsig("donate.example.org.", "org."),
        ];
        assert!(denial_is_proven(&name(ALIAS), &answers));
    }

    #[test]
    fn a_sibling_zone_may_not_deny_the_name() {
        // The near miss `zone_of` has to get right: `other.example.org` shares a
        // parent with the queried name and contains none of it.
        let answers = vec![
            soa("example.org.", Proof::Secure),
            nsec("donate.example.org.", Proof::Secure),
            nsec_rrsig("donate.example.org.", "other.example.org."),
        ];
        assert!(!denial_is_proven(&name(ALIAS), &answers));
    }

    #[test]
    fn an_nsec3_denial_is_judged_by_its_signer_not_its_owner() {
        // An NSEC3 is owned by a hashed label under the apex, so its owner name
        // never matches the queried name. Checking the owner would reject every
        // NSEC3 denial; the signer is what carries the zone.
        let hashed = "2vptu5timamqttgl4luu9kg21e0aor3s.example.org.";
        let mut record = Record::from_rdata(
            name(hashed),
            300,
            RData::DNSSEC(DNSSECRData::NSEC(NSEC::new(
                name("zz.example.org."),
                [RecordType::A, RecordType::RRSIG],
            ))),
        );
        record.proof = Proof::Secure;

        let answers = vec![record, rrsig_covering(hashed, "example.org.", RecordType::NSEC)];
        // The RRSIG helper leaves the proof unset, which is what a second
        // signature looks like; the record itself is the Secure one.
        assert!(denial_is_proven(&name(ALIAS), &answers));
    }

    #[test]
    fn a_signature_over_something_other_than_a_denial_does_not_count() {
        // A TXT signature in the authority section is not a denial of anything,
        // and must not satisfy the "there was a signature" requirement.
        let answers = vec![
            soa("example.org.", Proof::Secure),
            nsec("donate.example.org.", Proof::Secure),
            rrsig("donate.example.org.", "example.org."),
        ];
        assert!(!denial_is_proven(&name(ALIAS), &answers));
    }

    #[test]
    fn a_panic_becomes_an_error_instead_of_killing_the_process() {
        // Without the guard this is an abort, not a failure: a panic reaching an
        // `extern "C"` frame takes the whole wallet down.
        //
        // One test rather than several, because the panic hook is process-global
        // and `cargo test` runs tests on parallel threads — two tests each
        // swapping it race, and whichever restores first exposes the other's
        // deliberate panic to the harness, which then fails it. So this is the
        // only test in the crate that touches the hook, and it holds it for the
        // whole body.
        let previous = panic::take_hook();
        panic::set_hook(Box::new(|_| {}));

        let from_static = ffi_guard("unit_test", ptr::null_mut::<c_char>(), || {
            panic!("a static panic message");
        });
        let static_message = take_last_error();

        // Interpolating a *runtime* value, not a literal: rustc const-folds
        // `panic!("a {}", "literal")` into a single `&'static str` payload, so a
        // literal-only format string would take the quoted path and this test
        // would pass while asserting nothing.
        let secret = String::from("888attackeraddress");
        let from_format = ffi_guard("unit_test", ptr::null_mut::<c_char>(), || {
            panic!("secret {secret}");
        });
        let formatted_message = take_last_error();

        let unpanicked = ffi_guard("unit_test", ptr::null_mut::<c_char>(), || 1 as *mut c_char);

        panic::set_hook(previous);

        assert!(from_static.is_null(), "a panic must return the sentinel");
        assert!(from_format.is_null());
        assert!(!unpanicked.is_null(), "a body that does not panic is returned untouched");

        // A `&'static str` payload is a literal in source, so quoting it is safe
        // and useful.
        assert!(
            static_message.contains("a static panic message"),
            "got: {static_message}"
        );

        // A formatted payload was built at panic time and can interpolate the
        // data being parsed — here, an attacker-supplied DNS answer. Rule 5 in
        // docs/logging.md keeps that out of the log.
        assert!(
            !formatted_message.contains("888attackeraddress"),
            "got: {formatted_message}"
        );
        assert!(formatted_message.contains("withheld"), "got: {formatted_message}");
        assert!(
            formatted_message.contains("unit_test"),
            "the function name is the diagnostic part"
        );
    }

    #[test]
    fn a_plausible_clock_validates() {
        // 2026-06-01, comfortably after the floor.
        assert!(check_clock_at(UNIX_EPOCH + Duration::from_secs(1780272000)).is_ok());
    }

    #[test]
    fn a_rolled_back_clock_refuses_to_validate() {
        // The replay this stops: wind the clock far enough back and an expired
        // signature — one whose key has since been rotated or revoked — verifies
        // again. hickory takes the system time as given.
        let err = check_clock_at(UNIX_EPOCH + Duration::from_secs(1_000_000_000))
            .expect_err("a 2001 clock must not validate DNSSEC");
        assert!(err.contains("past"), "got: {err}");
        // Actionable, and names no attacker-supplied data.
        assert!(err.contains("clock"), "got: {err}");
    }

    #[test]
    fn the_epoch_and_before_it_refuse_to_validate() {
        // A device with a dead battery can come up here. Before the check this
        // was where the time arithmetic underflowed and panicked — which, before
        // `ffi_guard`, was an abort.
        assert!(check_clock_at(UNIX_EPOCH).is_err());
        let before = UNIX_EPOCH
            .checked_sub(Duration::from_secs(86400))
            .expect("a pre-epoch SystemTime is representable here");
        let err = check_clock_at(before).expect_err("a pre-1970 clock must not validate");
        assert!(err.contains("1970"), "got: {err}");
    }

    #[test]
    fn the_clock_floor_is_where_it_claims_to_be() {
        // Pins the constant against its documented meaning, so a typo in the
        // timestamp shows up here rather than as a wallet that refuses to resolve
        // an alias until 2098.
        assert_eq!(MIN_PLAUSIBLE_UNIX_TIME, 1767225600, "2026-01-01T00:00:00Z");
        assert!(check_clock_at(UNIX_EPOCH + Duration::from_secs(MIN_PLAUSIBLE_UNIX_TIME)).is_ok());
        assert!(
            check_clock_at(UNIX_EPOCH + Duration::from_secs(MIN_PLAUSIBLE_UNIX_TIME - 1)).is_err()
        );
    }

    #[test]
    fn the_overall_timeout_bounds_more_than_one_query() {
        // The bug was a per-query deadline standing in for a per-resolution one.
        // A total that is not larger than a single query would make the two the
        // same thing again.
        assert!(
            OVERALL_TIMEOUT > TCP_TIMEOUT,
            "an overall deadline no larger than one query's is not an overall deadline"
        );
    }

    #[test]
    fn one_resolver_is_shared_per_socks_port() {
        // The three lookups a single alias resolution makes run in separate Dart
        // isolates but land in this one process, so they must come back with the
        // same resolver: that is what gives them a shared connection pool and a
        // shared DNSSEC cache instead of validating the chain three times.
        let first = resolver_for(9050).expect("build");
        let second = resolver_for(9050).expect("cached");
        assert!(Arc::ptr_eq(&first, &second), "same port must reuse one resolver");

        // A different port is a different proxy, so it gets its own.
        let other = resolver_for(9051).expect("build");
        assert!(!Arc::ptr_eq(&first, &other), "a new port must not reuse the old proxy");
    }

    #[test]
    fn encodes_records() {
        let records = vec![
            "oa_version=2; network=xmr; address=888tNk;".to_string(),
            "oa1:xmr recipient_address=888tNk;".to_string(),
        ];
        assert_eq!(
            json_string_array(&records),
            r#"["oa_version=2; network=xmr; address=888tNk;","oa1:xmr recipient_address=888tNk;"]"#
        );
    }

    #[test]
    fn escapes_quotes_backslashes_and_controls() {
        let records = vec!["a\"b\\c\nd\te\u{1}f".to_string()];
        assert_eq!(json_string_array(&records), r#"["a\"b\\c\nd\te\u0001f"]"#);
    }

    #[test]
    fn encodes_empty_and_unicode() {
        assert_eq!(json_string_array(&[]), "[]");
        assert_eq!(json_string_array(&["münchen".to_string()]), "[\"münchen\"]");
    }
}
