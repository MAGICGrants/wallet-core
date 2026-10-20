//! End-to-end DNSSEC tests of [`secure_txt`]: a private DNS hierarchy, with its
//! own root key as the only trust anchor, answered from a loopback TCP server,
//! and a resolver set up as `build_resolver` sets up the real one
//! (`validate = true`). Only the transport and the trust anchor differ. Nothing
//! leaves 127.0.0.1.
//!
//! The forgeries all come from someone who controls the answers and owns one
//! honestly delegated, signed zone (`attacker.com.`), for a record and for a
//! denial that there is one. The zone signs them directly, or through a key it
//! vouches for with a DS record, so that the signer on the record itself looks
//! like the right zone. Every one must be refused: the wallet relies on
//! hickory's validation for this (RFC 4035 §5.3.1, from 0.26.2), and hickory
//! before 0.26.2 accepted the DS forms.

use super::secure_txt;

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hickory_proto::dnssec::crypto::Ed25519SigningKey;
use hickory_proto::dnssec::rdata::{DNSSECRData, SigInput, DNSKEY, DS, NSEC, RRSIG};
use hickory_proto::dnssec::{Algorithm, DigestType, PublicKeyBuf, SigningKey, TrustAnchors, TBS};
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
const HONEST: &str = "oa_version=2; network=xmr; address=888honest;";
const FORGED: &str = "oa_version=2; network=xmr; address=888forged;";

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
    store.insert(key, Response { answers: signed(rrset, signer), authorities: Vec::new() });
}

/// Answers the `rtype` question at `owner` with no records and `authorities`.
fn deny(store: &mut Store, owner: &str, rtype: RecordType, authorities: Vec<Record>) {
    store.insert((name(owner).to_lowercase(), rtype), Response { answers: Vec::new(), authorities });
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

fn txt(owner: &str, text: &str) -> Record {
    Record::from_rdata(name(owner), 300, RData::TXT(TXT::new(vec![text.to_string()])))
}

struct World {
    root: Zone,
    store: Store,
}

/// The honest part of the DNS: root → org → example.org, and root → com →
/// attacker.com, a domain its owner registered and signed legitimately.
fn honest_world() -> (World, Zone, Zone) {
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
    (World { root, store }, example, attacker)
}

/// A loopback DNS-over-TCP server answering from `store`; anything not in it
/// gets SERVFAIL.
async fn serve(store: Store) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let store = Arc::new(store);
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            let store = store.clone();
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
                    let request = Message::from_vec(&buf).unwrap();
                    let query = request.queries[0].clone();
                    let mut response = Message::response(request.metadata.id, OpCode::Query);
                    response.metadata.recursion_desired = true;
                    response.metadata.recursion_available = true;
                    response.add_query(query.clone());
                    match store.get(&(query.name().to_lowercase(), query.query_type())) {
                        Some(found) => {
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
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    rt.block_on(async move {
        let port = serve(world.store).await;
        secure_txt(N, &resolver(port, &world.root)).await
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
    world.store.insert((owner.to_lowercase(), RecordType::TXT), Response { answers, authorities: Vec::new() });
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
