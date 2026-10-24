//! End-to-end DNSSEC tests of [`secure_txt`]: a private DNS hierarchy, with its
//! own root key as the only trust anchor, answered from a loopback TCP server,
//! and a resolver set up as `build_resolver` sets up the real one
//! (`validate = true`). Only the transport and the trust anchor differ. Nothing
//! leaves 127.0.0.1.
//!
//! The forgeries all come from someone who controls the answers and owns one
//! honestly delegated, signed zone (`attacker.com.`, or a sibling of the
//! recipient's), for a record and for a denial that there is one. The zone
//! signs them directly, or through a key it vouches for with a DS record, so
//! that the signer on the record itself looks like the right zone. Every one
//! must be refused.
//!
//! Two layers refuse them. hickory's validation (RFC 4035 §5.3.1, from 0.26.2)
//! refuses a signer that does not contain the record it signs; hickory before
//! 0.26.2 accepted the DS forms. But hickory 0.26.3 still takes an NSEC as a
//! denial of the name asked about when the attacker's zone signed it over a
//! name of its own and its next name spans the asked one, as long as the answer
//! carries no SOA, or the real zone's, replayed: nothing ties an NSEC to the
//! zone the SOA names. The same NSEC lets a zone's signed wildcard stand at a
//! name that has a record of its own. So the wallet requires every signer over
//! a denial, and over the record, to be a zone containing the name that was
//! asked (`denial_signers_enclose`, `secure_txt_answers`). Each test below that
//! only this check stops says so.
//!
//! RFC 6840 §4.1: an NSEC or NSEC3 that a parent zone publishes at a delegation
//! (NS without SOA), or one at a DNAME, does not deny names below it. hickory
//! enforces this, and `denies_below_a_cut` checks it again. Without the rule, a
//! replay of org.'s signed NSEC at example.org. would prove every name under
//! example.org. absent, since org. contains them all. The delegation tests
//! assert that hickory itself refuses these, so the wallet's check does not
//! hide a hickory regression.

use super::secure_txt;

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hickory_proto::dnssec::crypto::Ed25519SigningKey;
use hickory_proto::dnssec::rdata::{DNSSECRData, SigInput, DNSKEY, DS, NSEC, NSEC3, RRSIG};
use hickory_proto::dnssec::{
    Algorithm, DigestType, Nsec3HashAlgorithm, PublicKeyBuf, SigningKey, TrustAnchors, TBS,
};
use hickory_proto::op::{Message, OpCode, ResponseCode};
use hickory_proto::rr::rdata::{SOA, TXT};
use hickory_proto::rr::{DNSClass, Name, RData, Record, RecordType, SerialNumber};
use hickory_resolver::config::{NameServerConfig, ResolverConfig, ResolverOpts};
use hickory_resolver::net::runtime::TokioRuntimeProvider;
use hickory_resolver::Resolver;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// The name the wallet asks first for the OA2 alias `donate.example.org`.
const N: &str = "_openalias-payment.donate.example.org.";
/// The alias itself, where an OA1 record lives.
const N1: &str = "donate.example.org.";
const HONEST: &str = "oa_version=2; network=xmr; address=888honest;";
const FORGED: &str = "oa_version=2; network=xmr; address=888forged;";
/// A catch-all a zone owner might publish at `*.example.org.`.
const WILDCARD: &str = "oa1:xmr recipient_address=888catchall;";

fn name(s: &str) -> Name {
    Name::from_utf8(s).unwrap()
}

struct Zone {
    name: Name,
    key: Ed25519SigningKey,
    pk: PublicKeyBuf,
}

impl Zone {
    fn new(n: &str) -> Self {
        let pkcs8 = Ed25519SigningKey::generate_pkcs8().unwrap();
        let key = Ed25519SigningKey::from_pkcs8(&pkcs8).unwrap();
        let pk = key.to_public_key().unwrap();
        Zone { name: name(n), key, pk }
    }

    fn dnskey(&self) -> DNSKEY {
        DNSKEY::from_key(&self.pk)
    }

    fn dnskey_record(&self) -> Record {
        Record::from_rdata(self.name.clone(), 300, RData::DNSSEC(DNSSECRData::DNSKEY(self.dnskey())))
    }

    fn ds_record(&self) -> Record {
        // Built from the DNSKEY: DS::from_key's key tag does not match
        // DNSKEY::calculate_key_tag.
        let key = self.dnskey();
        let digest = key.to_digest(&self.name, DigestType::SHA256).unwrap();
        let ds = DS::new(
            key.calculate_key_tag().unwrap(),
            Algorithm::ED25519,
            DigestType::SHA256,
            digest.as_ref().to_vec(),
        );
        Record::from_rdata(self.name.clone(), 300, RData::DNSSEC(DNSSECRData::DS(ds)))
    }
}

/// An RRSIG by `signer` over `rrset`, all owned by `owner` and of type `rtype`.
fn sign(rrset: &[Record], owner: &Name, rtype: RecordType, signer: &Zone) -> Record {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as u32;
    let input = SigInput {
        type_covered: rtype,
        algorithm: Algorithm::ED25519,
        num_labels: owner.num_labels(),
        original_ttl: 300,
        sig_expiration: SerialNumber::new(now + 86_400),
        sig_inception: SerialNumber::new(now - 3_600),
        key_tag: signer.dnskey().calculate_key_tag().unwrap(),
        signer_name: signer.name.clone(),
    };
    let tbs = TBS::from_input(owner, DNSClass::IN, &input, rrset.iter()).unwrap();
    let sig = signer.key.sign(&tbs).unwrap();
    Record::from_rdata(
        owner.clone(),
        300,
        RData::DNSSEC(DNSSECRData::RRSIG(RRSIG::from_sig(input, sig))),
    )
}

/// What the server says to one question: records, or an empty answer whose
/// authority section proves there are none.
#[derive(Default)]
struct Response {
    rcode: ResponseCode,
    answers: Vec<Record>,
    authorities: Vec<Record>,
}

/// The server's responses, by (owner, type).
type Store = HashMap<(Name, RecordType), Response>;

/// `rrset` with an RRSIG by `signer`.
fn signed(rrset: Vec<Record>, signer: &Zone) -> Vec<Record> {
    let owner = rrset[0].name.clone();
    let rtype = rrset[0].record_type();
    let rrsig = sign(&rrset, &owner, rtype, signer);
    let mut all = rrset;
    all.push(rrsig);
    all
}

/// Answers `rrset`, signed by `signer`, replacing any earlier response.
fn put(store: &mut Store, rrset: Vec<Record>, signer: &Zone) {
    let key = (rrset[0].name.to_lowercase(), rrset[0].record_type());
    store.insert(key, Response { answers: signed(rrset, signer), ..Response::default() });
}

/// Answers the `rtype` question at `owner` with no records and `authorities`.
fn deny(store: &mut Store, owner: &str, rtype: RecordType, authorities: Vec<Record>) {
    store.insert((name(owner).to_lowercase(), rtype), Response { authorities, ..Response::default() });
}

/// Answers the `rtype` question at `owner` with NXDOMAIN and `authorities`.
fn nxdomain(store: &mut Store, owner: &str, rtype: RecordType, authorities: Vec<Record>) {
    let response = Response { rcode: ResponseCode::NXDomain, authorities, ..Response::default() };
    store.insert((name(owner).to_lowercase(), rtype), response);
}

/// Answers the `rtype` question at `owner` with `answers` and `authorities`,
/// exactly as given.
fn answer(store: &mut Store, owner: &str, rtype: RecordType, answers: Vec<Record>, authorities: Vec<Record>) {
    store.insert((name(owner).to_lowercase(), rtype), Response { answers, authorities, ..Response::default() });
}

/// A zone's SOA record.
fn soa(zone: &str) -> Record {
    let soa = SOA::new(name(&format!("ns.{zone}")), name(&format!("hostmaster.{zone}")), 1, 7200, 600, 3_600_000, 300);
    Record::from_rdata(name(zone), 300, RData::SOA(soa))
}

/// An NSEC record saying `owner` exists with no records but its NSEC and RRSIG,
/// and that the next name in the zone is `next`.
fn nsec(owner: &str, next: &str) -> Record {
    let nsec = NSEC::new(name(next), [RecordType::RRSIG, RecordType::NSEC]);
    Record::from_rdata(name(owner), 300, RData::DNSSEC(DNSSECRData::NSEC(nsec)))
}

/// An NSEC that `zone` really signs, owned by `owner` inside it, whose next name
/// is `zzzz.`. In canonical order that spans every name after `owner` up to a
/// top-level `zzzz`: from `a.attacker.com.` it covers `N`, the alias, and the
/// wildcards that could have produced either (`com` < `org` < `zzzz`).
fn spanning_nsec(owner: &str, zone: &Zone) -> Vec<Record> {
    signed(vec![nsec(owner, "zzzz.")], zone)
}

/// The NSEC3 owner name for `n` in `zone`: the base32hex SHA-1 of `n`, with no
/// salt and no extra iterations.
fn nsec3_owner(n: &str, zone: &str) -> String {
    let hash = Nsec3HashAlgorithm::SHA1.hash(&[], &name(n), 0).unwrap();
    // NSEC3 writes its next hashed owner name the way an owner label is
    // written, so this borrows that encoding instead of repeating it.
    let encoded = NSEC3::new(Nsec3HashAlgorithm::SHA1, false, 0, Vec::new(), hash.as_ref().to_vec(), []);
    format!("{}.{zone}", encoded.next_hashed_owner_name_base32().unwrap())
}

/// An NSEC3 record at `owner` saying its name holds an A record and nothing
/// else.
fn nsec3(owner: &str) -> Record {
    let next = Nsec3HashAlgorithm::SHA1.hash(&[], &name("zz.example.org."), 0).unwrap();
    let nsec3 = NSEC3::new(
        Nsec3HashAlgorithm::SHA1,
        false,
        0,
        Vec::new(),
        next.as_ref().to_vec(),
        [RecordType::A, RecordType::RRSIG],
    );
    Record::from_rdata(name(owner), 300, RData::DNSSEC(DNSSECRData::NSEC3(nsec3)))
}

fn txt(owner: &str, text: &str) -> Record {
    Record::from_rdata(name(owner), 300, RData::TXT(TXT::new(vec![text.to_string()])))
}

/// `example.org.`'s `*.example.org.` TXT record and its signature, served at
/// `N`. A wildcard's signed data is valid at any name it could have produced;
/// the signature's label count, two, is what marks it as an expansion.
fn wildcard_at_n(example: &Zone) -> Vec<Record> {
    let wildcard = vec![txt("*.example.org.", WILDCARD)];
    let mut rrsig = sign(&wildcard, &name("*.example.org."), RecordType::TXT, example);
    rrsig.name = name(N);
    vec![txt(N, WILDCARD), rrsig]
}

struct World {
    root: Zone,
    store: Store,
}

/// The honest part of the DNS: root → org → example.org, and root → com →
/// attacker.com, a domain its owner registered and signed legitimately.
fn honest_world() -> (World, Zone, Zone) {
    let (world, _org, example, attacker) = honest_world_with_org();
    (world, example, attacker)
}

/// [`honest_world`], also handing back org., for a test that needs its
/// signature.
fn honest_world_with_org() -> (World, Zone, Zone, Zone) {
    let root = Zone::new(".");
    let org = Zone::new("org.");
    let example = Zone::new("example.org.");
    let com = Zone::new("com.");
    let attacker = Zone::new("attacker.com.");

    let mut store = Store::new();
    put(&mut store, vec![root.dnskey_record()], &root);
    put(&mut store, vec![org.dnskey_record()], &org);
    put(&mut store, vec![org.ds_record()], &root);
    put(&mut store, vec![example.dnskey_record()], &example);
    put(&mut store, vec![example.ds_record()], &org);
    put(&mut store, vec![com.dnskey_record()], &com);
    put(&mut store, vec![com.ds_record()], &root);
    put(&mut store, vec![attacker.dnskey_record()], &attacker);
    put(&mut store, vec![attacker.ds_record()], &com);
    (World { root, store }, org, example, attacker)
}

/// A loopback DNS-over-TCP server answering from `store`; anything not in it
/// gets SERVFAIL.
async fn serve(store: Store) -> u16 {
    serve_counted(store, Arc::new(AtomicUsize::new(0))).await
}

/// [`serve`], counting the questions it answers in `count`.
async fn serve_counted(store: Store, count: Arc<AtomicUsize>) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let store = Arc::new(store);
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            let store = store.clone();
            let count = count.clone();
            tokio::spawn(async move {
                loop {
                    let mut len = [0u8; 2];
                    if sock.read_exact(&mut len).await.is_err() {
                        return;
                    }
                    let mut buf = vec![0u8; u16::from_be_bytes(len) as usize];
                    if sock.read_exact(&mut buf).await.is_err() {
                        return;
                    }
                    count.fetch_add(1, Ordering::SeqCst);
                    let request = Message::from_vec(&buf).unwrap();
                    let query = request.queries[0].clone();
                    let mut response = Message::response(request.metadata.id, OpCode::Query);
                    response.metadata.recursion_desired = true;
                    response.metadata.recursion_available = true;
                    response.add_query(query.clone());
                    match store.get(&(query.name().to_lowercase(), query.query_type())) {
                        Some(found) => {
                            response.metadata.response_code = found.rcode;
                            for record in &found.answers {
                                response.add_answer(record.clone());
                            }
                            for record in &found.authorities {
                                response.add_authority(record.clone());
                            }
                        }
                        None => response.metadata.response_code = ResponseCode::ServFail,
                    }
                    let out = response.to_vec().unwrap();
                    let mut framed = (out.len() as u16).to_be_bytes().to_vec();
                    framed.extend_from_slice(&out);
                    if sock.write_all(&framed).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    port
}

/// Validating as `build_resolver` does, but over plain TCP to the loopback
/// server, with this world's root key as the trust anchor.
fn resolver(port: u16, root: &Zone) -> Resolver<TokioRuntimeProvider> {
    let mut server = NameServerConfig::tcp(IpAddr::V4(Ipv4Addr::LOCALHOST));
    for connection in server.connections.iter_mut() {
        connection.port = port;
    }
    let config = ResolverConfig::from_parts(None, vec![], vec![server]);
    let mut opts = ResolverOpts::default();
    opts.validate = true;
    opts.timeout = Duration::from_secs(5);
    opts.attempts = 1;
    let mut anchors = TrustAnchors::empty();
    anchors.insert(&root.pk);
    Resolver::builder_with_config(config, TokioRuntimeProvider::new())
        .with_options(opts)
        .with_trust_anchor(Arc::new(anchors))
        .build()
        .unwrap()
}

/// What `secure_txt` makes of `N` in `world`.
fn lookup(world: World) -> Result<Vec<String>, String> {
    lookup_at(world, N)
}

/// What `secure_txt` makes of `at` in `world`.
fn lookup_at(world: World, at: &'static str) -> Result<Vec<String>, String> {
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    rt.block_on(async move {
        let port = serve(world.store).await;
        secure_txt(at, &resolver(port, &world.root)).await
    })
}

/// A forgery must fail outright: not resolve, and above all not to `FORGED`.
fn assert_refused(result: Result<Vec<String>, String>) {
    assert!(result.is_err(), "the forged record resolved: {result:?}");
}

#[test]
fn the_zones_own_record_resolves() {
    // The harness itself: keys, signatures and chain are what hickory expects.
    let (mut world, example, _attacker) = honest_world();
    put(&mut world.store, vec![txt(N, HONEST)], &example);
    assert_eq!(lookup(world), Ok(vec![HONEST.to_string()]));
}

#[test]
fn refuses_a_record_signed_by_a_foreign_zone() {
    let (mut world, _example, attacker) = honest_world();
    put(&mut world.store, vec![txt(N, FORGED)], &attacker);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_made_up_zone_cut_whose_ds_a_foreign_zone_signed() {
    let (mut world, _example, attacker) = honest_world();
    // A key for a zone cut that does not exist, between example.org. and N.
    let fake = Zone::new("donate.example.org.");
    put(&mut world.store, vec![txt(N, FORGED)], &fake);
    put(&mut world.store, vec![fake.dnskey_record()], &fake);
    put(&mut world.store, vec![fake.ds_record()], &attacker);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_made_up_zone_at_the_queried_name() {
    let (mut world, _example, attacker) = honest_world();
    let fake = Zone::new(N);
    put(&mut world.store, vec![txt(N, FORGED)], &fake);
    put(&mut world.store, vec![fake.dnskey_record()], &fake);
    put(&mut world.store, vec![fake.ds_record()], &attacker);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_forged_key_for_the_real_zones_own_name() {
    // The signer name is example.org., the same as on the honest record: only
    // the DS that vouches for the forged key, signed by attacker.com., differs.
    let (mut world, _example, attacker) = honest_world();
    let fake = Zone::new("example.org.");
    put(&mut world.store, vec![txt(N, FORGED)], &fake);
    put(&mut world.store, vec![fake.dnskey_record()], &fake);
    put(&mut world.store, vec![fake.ds_record()], &attacker);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_foreign_signature_beside_one_from_the_zone() {
    // An RRSIG from the zone, carried over from the honest record, next to the
    // attacker's: the zone's does not verify over the forged data, and the
    // attacker's must not count.
    let (mut world, example, attacker) = honest_world();
    let owner = name(N);
    let honest = vec![txt(N, HONEST)];
    let forged = vec![txt(N, FORGED)];
    let mut answers = forged.clone();
    answers.push(sign(&honest, &owner, RecordType::TXT, &example));
    answers.push(sign(&forged, &owner, RecordType::TXT, &attacker));
    answer(&mut world.store, N, RecordType::TXT, answers, Vec::new());
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_record_carrying_a_foreign_signature_beside_the_zones() {
    // The zone's own record and signature, plus attacker.com.'s signature over
    // the same record. hickory 0.26.3 skips the foreign one, so the zone's is
    // what counts, but which signature counts is hickory's choice: the wallet
    // refuses any answer where a foreign one could have. Refusing it costs a
    // lookup that someone able to add a signature could have dropped anyway.
    // Only the wallet's check stops this.
    let (mut world, example, attacker) = honest_world();
    let owner = name(N);
    let record = vec![txt(N, HONEST)];
    let mut answers = signed(record.clone(), &example);
    answers.push(sign(&record, &owner, RecordType::TXT, &attacker));
    answer(&mut world.store, N, RecordType::TXT, answers, Vec::new());
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_record_signed_by_a_sibling_zone() {
    // `other.example.org.` is honestly delegated and shares a parent with N, but
    // N is not in it.
    let (mut world, example, _attacker) = honest_world();
    let sibling = Zone::new("other.example.org.");
    put(&mut world.store, vec![sibling.dnskey_record()], &sibling);
    put(&mut world.store, vec![sibling.ds_record()], &example);
    put(&mut world.store, vec![txt(N, FORGED)], &sibling);
    assert_refused(lookup(world));
}

#[test]
fn a_signed_denial_proves_there_is_no_record() {
    // The state the OA2 → OA1 fallback exists for: the name exists, publishes no
    // TXT record, and its zone signs that.
    let (mut world, example, _attacker) = honest_world();
    let mut authorities = signed(vec![soa("example.org.")], &example);
    authorities.extend(signed(vec![nsec(N, "zz.example.org.")], &example));
    deny(&mut world.store, N, RecordType::TXT, authorities);
    assert_eq!(lookup(world), Ok(Vec::new()));
}

#[test]
fn an_nsec3_denial_proves_there_is_no_record() {
    // An NSEC3 is owned by a hashed label under the apex, never by the name it
    // denies, so what places it in the zone is its signer.
    let (mut world, example, _attacker) = honest_world();
    let mut authorities = signed(vec![soa("example.org.")], &example);
    authorities.extend(signed(vec![nsec3(&nsec3_owner(N, "example.org."))], &example));
    deny(&mut world.store, N, RecordType::TXT, authorities);
    assert_eq!(lookup(world), Ok(Vec::new()));
}

#[test]
fn a_denial_from_a_zone_further_up_proves_there_is_no_record() {
    // With no zone cut at example.org., org. holds N and signs that it has no
    // TXT record. The signer has to contain N, not be the closest zone to it.
    let root = Zone::new(".");
    let org = Zone::new("org.");
    let mut store = Store::new();
    put(&mut store, vec![root.dnskey_record()], &root);
    put(&mut store, vec![org.dnskey_record()], &org);
    put(&mut store, vec![org.ds_record()], &root);
    let mut authorities = signed(vec![soa("org.")], &org);
    authorities.extend(signed(vec![nsec(N, "zz.example.org.")], &org));
    deny(&mut store, N, RecordType::TXT, authorities);
    assert_eq!(lookup(World { root, store }), Ok(Vec::new()));
}

#[test]
fn a_record_from_the_zones_wildcard_resolves() {
    // example.org. publishes `*.example.org. TXT` and no name under donate, so
    // N is produced from the wildcard, and the zone's NSEC from `*` to `www`
    // proves no closer name exists. Aliases served this way keep working.
    let (mut world, example, _attacker) = honest_world();
    let types = [RecordType::TXT, RecordType::RRSIG, RecordType::NSEC];
    let next = NSEC::new(name("www.example.org."), types);
    let wildcard_nsec =
        Record::from_rdata(name("*.example.org."), 300, RData::DNSSEC(DNSSECRData::NSEC(next)));
    answer(&mut world.store, N, RecordType::TXT, wildcard_at_n(&example), signed(vec![wildcard_nsec], &example));
    assert_eq!(lookup(world), Ok(vec![WILDCARD.to_string()]));
}

#[test]
fn refuses_a_denial_signed_by_a_foreign_zone() {
    // No SOA, so nothing names the zone but the signature.
    let (mut world, _example, attacker) = honest_world();
    let authorities = signed(vec![nsec(N, "zz.example.org.")], &attacker);
    deny(&mut world.store, N, RecordType::TXT, authorities);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_denial_from_a_forged_key_for_the_real_zone() {
    let (mut world, _example, attacker) = honest_world();
    let fake = Zone::new("example.org.");
    put(&mut world.store, vec![fake.dnskey_record()], &fake);
    put(&mut world.store, vec![fake.ds_record()], &attacker);
    let mut authorities = signed(vec![soa("example.org.")], &fake);
    authorities.extend(signed(vec![nsec(N, "zz.example.org.")], &fake));
    deny(&mut world.store, N, RecordType::TXT, authorities);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_denial_taken_from_another_zone() {
    // Genuinely signed by its own zone, and about names in it, not this one.
    let (mut world, _example, attacker) = honest_world();
    let mut authorities = signed(vec![soa("attacker.com.")], &attacker);
    authorities.extend(signed(vec![nsec("a.attacker.com.", "z.attacker.com.")], &attacker));
    deny(&mut world.store, N, RecordType::TXT, authorities);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_foreign_denial_spanning_the_name() {
    // The gap in hickory 0.26.3 (2026-10-20 audit, L-16): attacker.com. signs
    // an NSEC over a name in its own zone, so hickory marks it Secure, and its
    // next name spans N. With no SOA there is no zone to hold it to, and hickory
    // takes it as proof that N does not exist, which is what moves the wallet
    // from OA2 to OA1. Only the wallet's check stops this.
    let (mut world, _example, attacker) = honest_world();
    nxdomain(&mut world.store, N, RecordType::TXT, spanning_nsec("a.attacker.com.", &attacker));
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_foreign_denial_of_the_alias_itself() {
    // The same, at the OA1 name. Only the wallet's check stops this.
    let (mut world, _example, attacker) = honest_world();
    nxdomain(&mut world.store, N1, RecordType::TXT, spanning_nsec("a.attacker.com.", &attacker));
    assert_refused(lookup_at(world, N1));
}

#[test]
fn refuses_a_foreign_denial_beside_the_zones_own_soa() {
    // example.org.'s SOA and its signature are public, so they can be replayed.
    // hickory checks that the SOA's zone contains N, not that the NSEC comes
    // from that zone. Only the wallet's check stops this.
    let (mut world, example, attacker) = honest_world();
    let mut authorities = signed(vec![soa("example.org.")], &example);
    authorities.extend(spanning_nsec("a.attacker.com.", &attacker));
    nxdomain(&mut world.store, N, RecordType::TXT, authorities);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_foreign_denial_behind_an_unsigned_soa_for_the_zone() {
    // An SOA for example.org. that nobody signed names no zone: hickory ignores
    // it, so the denial is from whoever signed the NSEC. Only the wallet's check
    // stops this.
    let (mut world, _example, attacker) = honest_world();
    let mut authorities = vec![soa("example.org.")];
    authorities.extend(spanning_nsec("a.attacker.com.", &attacker));
    nxdomain(&mut world.store, N, RecordType::TXT, authorities);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_foreign_denial_from_a_sibling_zone() {
    // `a.example.org.` is honestly delegated, shares a parent with N, and sorts
    // before it, so an NSEC at its apex can span N. Only the wallet's check
    // stops this.
    let (mut world, example, _attacker) = honest_world();
    let sibling = Zone::new("a.example.org.");
    put(&mut world.store, vec![sibling.dnskey_record()], &sibling);
    put(&mut world.store, vec![sibling.ds_record()], &example);
    nxdomain(&mut world.store, N, RecordType::TXT, spanning_nsec("a.example.org.", &sibling));
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_foreign_denial_proving_a_wildcard_expansion() {
    // N publishes HONEST, and example.org. also publishes `*.example.org. TXT`.
    // RFC 4035 §5.3.4 lets the wildcard's data stand at N only where an NSEC
    // proves no closer name exists, and the zone has no such NSEC, so the
    // attacker supplies one from its own zone and replaces HONEST with the
    // catch-all. Only the wallet's check stops this.
    let (mut world, example, attacker) = honest_world();
    let proof = spanning_nsec("a.attacker.com.", &attacker);
    answer(&mut world.store, N, RecordType::TXT, wildcard_at_n(&example), proof);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_denial_carrying_a_foreign_signature_beside_the_zones() {
    // The zone's own denial, with attacker.com.'s signature over the same NSEC
    // beside the zone's. As for a record, which signature counts is hickory's
    // choice, so the wallet refuses any denial where a foreign one could have.
    // Only the wallet's check stops this.
    let (mut world, example, attacker) = honest_world();
    let denial = vec![nsec(N, "zz.example.org.")];
    let mut authorities = signed(vec![soa("example.org.")], &example);
    authorities.extend(signed(denial.clone(), &example));
    authorities.push(sign(&denial, &name(N), RecordType::NSEC, &attacker));
    deny(&mut world.store, N, RecordType::TXT, authorities);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_spanning_denial_with_the_attackers_own_soa() {
    // hickory refuses this one itself: the SOA's zone must contain N.
    let (mut world, _example, attacker) = honest_world();
    let mut authorities = signed(vec![soa("attacker.com.")], &attacker);
    authorities.extend(spanning_nsec("a.attacker.com.", &attacker));
    nxdomain(&mut world.store, N, RecordType::TXT, authorities);
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_spanning_nsec_as_proof_that_a_name_has_no_txt_record() {
    // An answer saying N exists without a TXT record needs an NSEC at N itself;
    // one that only spans N proves nothing about it. hickory refuses this one
    // itself.
    let (mut world, _example, attacker) = honest_world();
    deny(&mut world.store, N, RecordType::TXT, spanning_nsec("a.attacker.com.", &attacker));
    assert_refused(lookup(world));
}

#[test]
fn refuses_a_wildcard_record_with_no_proof_that_the_name_is_absent() {
    // hickory refuses this one itself.
    let (mut world, example, _attacker) = honest_world();
    answer(&mut world.store, N, RecordType::TXT, wildcard_at_n(&example), Vec::new());
    assert_refused(lookup(world));
}

/// org.'s own NSEC at its delegation point example.org.: NS and DS, no SOA,
/// next name example0.org., signed by org. In canonical order it spans every
/// name under example.org., and its signer contains all of them.
fn delegation_nsec(org: &Zone) -> Vec<Record> {
    let types = [RecordType::NS, RecordType::DS, RecordType::RRSIG, RecordType::NSEC];
    let nsec = NSEC::new(name("example0.org."), types);
    signed(vec![Record::from_rdata(name("example.org."), 300, RData::DNSSEC(DNSSECRData::NSEC(nsec)))], org)
}

/// What a refusal says when it comes from the wallet's own copy of the RFC 6840
/// §4.1 rule (`denies_below_a_cut`) rather than from hickory.
const REFUSED_BY_THE_WALLET_AT_A_CUT: &str = "above a zone cut";

/// Asserts that hickory refused `result`, not the wallet's `denies_below_a_cut`,
/// so the tests using this catch a hickory release that drops RFC 6840 §4.1.
fn assert_refused_by_hickory(result: Result<Vec<String>, String>) {
    match result {
        Err(e) => assert!(!e.contains(REFUSED_BY_THE_WALLET_AT_A_CUT), "only the wallet refused this: {e}"),
        Ok(records) => panic!("the forged denial was accepted: {records:?}"),
    }
}

#[test]
fn refuses_the_parents_delegation_nsec_as_a_denial_below_the_cut() {
    // Genuinely signed by org., which contains N, so every signer check the
    // wallet makes passes. Without RFC 6840 §4.1, replaying this public record
    // proves any name under example.org. absent.
    let (mut world, org, _example, _attacker) = honest_world_with_org();
    nxdomain(&mut world.store, N, RecordType::TXT, delegation_nsec(&org));
    assert_refused_by_hickory(lookup(world));
}

#[test]
fn refuses_the_parents_delegation_nsec_beside_the_parents_soa() {
    let (mut world, org, _example, _attacker) = honest_world_with_org();
    let mut authorities = signed(vec![soa("org.")], &org);
    authorities.extend(delegation_nsec(&org));
    nxdomain(&mut world.store, N, RecordType::TXT, authorities);
    assert_refused_by_hickory(lookup(world));
}

#[test]
fn refuses_the_parents_delegation_nsec_as_a_denial_of_the_alias() {
    let (mut world, org, _example, _attacker) = honest_world_with_org();
    nxdomain(&mut world.store, N1, RecordType::TXT, delegation_nsec(&org));
    assert_refused_by_hickory(lookup_at(world, N1));
}

#[test]
fn refuses_the_parents_delegation_nsec_as_proof_of_a_wildcard_expansion() {
    // example.org.'s genuine wildcard at N, with org.'s delegation NSEC as the
    // proof that no closer name exists.
    let (mut world, org, example, _attacker) = honest_world_with_org();
    answer(&mut world.store, N, RecordType::TXT, wildcard_at_n(&example), delegation_nsec(&org));
    assert_refused_by_hickory(lookup(world));
}

#[test]
fn control_the_same_nsec_without_ns_is_taken_as_a_denial() {
    // The same record from org., minus NS, so not a delegation: org. holds N
    // and may say it is absent. The refusals above are therefore the RFC 6840
    // §4.1 rule at work, not a malformed record.
    let (mut world, org, _example, _attacker) = honest_world_with_org();
    let types = [RecordType::DS, RecordType::RRSIG, RecordType::NSEC];
    let nsec = NSEC::new(name("example0.org."), types);
    let record = Record::from_rdata(name("example.org."), 300, RData::DNSSEC(DNSSECRData::NSEC(nsec)));
    nxdomain(&mut world.store, N, RecordType::TXT, signed(vec![record], &org));
    assert_eq!(lookup(world), Ok(Vec::new()));
}

#[test]
fn a_repeat_lookup_from_the_cache_resolves_the_same() {
    // The second lookup must come from hickory's cache (no new question) and
    // still resolve: `secure_txt_answers` needs the Secure mark on the RRSIG
    // hickory used, so that mark has to survive the cache.
    let (mut world, example, _attacker) = honest_world();
    put(&mut world.store, vec![txt(N, HONEST)], &example);
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    rt.block_on(async move {
        let count = Arc::new(AtomicUsize::new(0));
        let port = serve_counted(world.store, count.clone()).await;
        let r = resolver(port, &world.root);
        assert_eq!(secure_txt(N, &r).await, Ok(vec![HONEST.to_string()]));
        let after_first = count.load(Ordering::SeqCst);
        assert_eq!(secure_txt(N, &r).await, Ok(vec![HONEST.to_string()]));
        assert_eq!(count.load(Ordering::SeqCst), after_first, "the second lookup was not served from the cache");
    });
}

/// The base32hex owner label NSEC3 writes for `hash`.
fn hashed_label(hash: &[u8]) -> String {
    let encoded = NSEC3::new(Nsec3HashAlgorithm::SHA1, false, 0, Vec::new(), hash.to_vec(), []);
    encoded.next_hashed_owner_name_base32().unwrap().to_string()
}

/// `hash` one up (`delta` > 0) or one down, as a big-endian number of the same
/// width.
fn offset(hash: &[u8], delta: i8) -> Vec<u8> {
    let mut out = hash.to_vec();
    for byte in out.iter_mut().rev() {
        let (value, carry) = if delta > 0 { byte.overflowing_add(1) } else { byte.overflowing_sub(1) };
        *byte = value;
        if !carry {
            break;
        }
    }
    out
}

/// An NSEC3 in `zone`, signed by `signer`, whose hashed owner is `owner_hash`
/// and that lists `types`.
fn nsec3_at(owner_hash: &[u8], next_hash: Vec<u8>, zone: &str, types: &[RecordType], signer: &Zone) -> Vec<Record> {
    let nsec3 = NSEC3::new(Nsec3HashAlgorithm::SHA1, false, 0, Vec::new(), next_hash, types.iter().copied());
    let owner = name(&format!("{}.{zone}", hashed_label(owner_hash)));
    signed(vec![Record::from_rdata(owner, 300, RData::DNSSEC(DNSSECRData::NSEC3(nsec3)))], signer)
}

fn nsec3_hash(n: &str) -> Vec<u8> {
    Nsec3HashAlgorithm::SHA1.hash(&[], &name(n), 0).unwrap().as_ref().to_vec()
}

/// An NSEC3 in `zone` whose hash interval covers only the hash of `n`, proving
/// `n` absent.
fn covering_nsec3(n: &str, zone: &str, signer: &Zone) -> Vec<Record> {
    let hash = nsec3_hash(n);
    nsec3_at(&offset(&hash, -1), offset(&hash, 1), zone, &[RecordType::A, RecordType::RRSIG], signer)
}

/// org.'s NSEC3 closest-encloser proof that a name under example.org. does not
/// exist: example.org. is the closest encloser, listing `encloser_types`, and
/// `next_closer` and the wildcard at example.org. are covered.
fn org_nsec3_denial(org: &Zone, next_closer: &str, encloser_types: &[RecordType]) -> Vec<Record> {
    let encloser = nsec3_hash("example.org.");
    let mut authorities = signed(vec![soa("org.")], org);
    authorities.extend(nsec3_at(&encloser, offset(&encloser, 1), "org.", encloser_types, org));
    authorities.extend(covering_nsec3(next_closer, "org.", org));
    authorities.extend(covering_nsec3("*.example.org.", "org.", org));
    authorities
}

const NSEC3_DELEGATION: [RecordType; 3] = [RecordType::NS, RecordType::DS, RecordType::RRSIG];

#[test]
fn refuses_the_parents_delegation_nsec3_as_a_closest_encloser() {
    // The NSEC3 form: org.'s hashed record for its delegation of example.org.,
    // offered as the closest encloser of N (RFC 5155 §8.3, RFC 6840 §4.1).
    let (mut world, org, _example, _attacker) = honest_world_with_org();
    let authorities = org_nsec3_denial(&org, "donate.example.org.", &NSEC3_DELEGATION);
    nxdomain(&mut world.store, N, RecordType::TXT, authorities);
    assert_refused_by_hickory(lookup(world));
}

#[test]
fn refuses_the_parents_delegation_nsec3_as_a_denial_of_the_alias() {
    let (mut world, org, _example, _attacker) = honest_world_with_org();
    let authorities = org_nsec3_denial(&org, N1, &NSEC3_DELEGATION);
    nxdomain(&mut world.store, N1, RecordType::TXT, authorities);
    assert_refused_by_hickory(lookup_at(world, N1));
}

#[test]
fn refuses_the_parents_delegation_nsec3_at_the_cut_as_a_denial_of_its_txt() {
    // donate.example.org. delegated by example.org.: the parent's NSEC3 at the
    // cut proves only that there is no DS there, not that there is no TXT.
    let (mut world, _org, example, _attacker) = honest_world_with_org();
    let at_cut = nsec3_hash(N1);
    let mut authorities = signed(vec![soa("example.org.")], &example);
    authorities.extend(nsec3_at(&at_cut, offset(&at_cut, 1), "example.org.", &NSEC3_DELEGATION, &example));
    deny(&mut world.store, N1, RecordType::TXT, authorities);
    assert_refused_by_hickory(lookup_at(world, N1));
}

#[test]
fn control_the_same_nsec3_without_ns_is_taken_as_a_denial() {
    // Without NS, example.org. is an ordinary name in org., which may then
    // prove N absent: the refusals above are the rule at work.
    let (mut world, org, _example, _attacker) = honest_world_with_org();
    let authorities = org_nsec3_denial(&org, "donate.example.org.", &[RecordType::DS, RecordType::RRSIG]);
    nxdomain(&mut world.store, N, RecordType::TXT, authorities);
    assert_eq!(lookup(world), Ok(Vec::new()));
}
