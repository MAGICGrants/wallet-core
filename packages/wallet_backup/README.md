# wallet_backup

The seed-keyed metadata backup: who each Monero payment went to, its
transaction key, and the address book, saved as many small sealed files in
every location the user chooses. Pure Dart; the platform locations (iCloud)
and the screens are in `wallet_backup_platform`.

It implements the implementation plan in
`ai-audit-resources/research-projects/2026-10-09-trezor-suite-sync-vs-lws-metadata/implementation-plan.md`.
Section numbers below are that plan's.

## Keys (§1)

```
seed ──► M          wallet_domain's MetadataSecret: PM-a for polyseed, BM-a for BIP39
M    ──► K          H_32[M]("Monero metadata backup v1")
K    ──► k_enc(e)   H_32[K]("encryption key" ‖ IntToBytes16(e))     seals every file
     ──► k_name     H_32[K]("naming key")                           names at a location
     ──► t_lws(e)   H_32[K]("LWS write token" ‖ IntToBytes16(e))    for the LWS location, later
```

`H_32` is Carrot's keyed BLAKE2b ("Monero" personalisation, length-prefixed
domain). Every step is a hash, so a quantum computer that can compute the view
and spend keys from an address learns nothing here (§9). **25-word seeds have
no backup**: they are the spend key. The strings are placeholders until a Monero
addendum fixes them. `M` is also the root of the security-key (FHSE) key tree,
behind its own domain strings.

The keys are derived at unlock (PBKDF2 for polyseed and BIP39, off the UI
isolate), held in memory while the wallet is open, and wiped on a full lock.
They are never written to disk.

## Files (§2, §3, §8)

```
file      = version (1) ‖ key_epoch (u16 BE) ‖ nonce (24) ‖ XChaCha20-Poly1305(k_enc, AD = header)
plaintext = body_len (u32 BE) ‖ deterministic CBOR body ‖ zero padding
```

Every file is at least 1 KiB, rounded up with PADMÉ, at most 64 KiB. A reader
rejects an unknown version or epoch, a failed seal, non-zero padding and a body
that is not canonical CBOR, and uses a file whole or not at all. Unknown record
types are kept byte for byte.

Records written by this version (registry in `lib/src/records.dart`):

| Type | Content | Merge |
|---|---|---|
| 1 outgoing payment | txid, account, fee, and per destination: address kind, public keys, amount, tx key (`r` and any additional keys for a legacy transaction), payment ID | union on txid |
| 3 contact | id, name, coin → address, lamport, device id, deleted | last writer wins on (lamport, device id) |

Names: `c-<device>-<seq>` locally; elsewhere `b32(H_16[k_name]("file name" ‖ plain))`
inside a folder named `b32(H_16[k_name]("folder name"))`.

XChaCha20 is HChaCha20 (here) over pointycastle's RFC 8439 ChaCha20-Poly1305.
The tests check it against libsodium 1.0.22 (the copy vendored in
`wallet_fhse`) and draft-irtf-cfrg-xchacha's vectors, and check `M` against the
seed-derivations project's PM-a and BM-a vectors.

## Service (§2.3–§4)

`MetadataBackupService` is wallet_domain's `MetadataBackup` seam. The app
installs it (through `wallet_backup_platform`) on the UI isolate.

- **Writing.** Each change is one file: the seq is saved first, the file goes to
  the local copy (temporary name, flushed, renamed), then to every enabled
  location. Payment files reach iCloud after a random delay of up to 10 minutes
  (§2.3 step 5).
- **Payments.** `MoneroWallet.commitTx` hands the payment over straight after
  the broadcast, with the key read from the wallet. A history scan also records
  every outgoing payment this wallet built that has no record yet, including
  ones from before the backup existed. monero_c cannot yet give a pending
  transaction's keys, so the record is written right after the broadcast, not
  before it (§13.2).
- **Address book.** A three-way merge: what the address book held at the last
  sync is the base, so an edit made here becomes a new version and an edit made
  elsewhere is applied here (through `ContactsSync`, which an open
  `ContactModel` takes in memory).
- **Reading.** On open, on resume, every 5 minutes, and after every change:
  list each location, open anything new, merge, apply, upload what is missing.
- **Restore.** A new device id, then every location is read. A wallet's history
  takes destinations and keys from the backup for payments it lost
  (`CryptoWallet._withCarriedFields`). The report lists unreadable files,
  sequence gaps, and payments with two different records.
- **Export.** `exportBundle` gives every sealed file in one file
  (`u32 length ‖ file`, repeated; no names, no magic) for anywhere else;
  `importBundle` reads one back.

## Not in this version

- **Compaction (§4.5).** Nothing deletes files from a location. At about 1 KiB
  per change, a heavy user reaches a few MB; readers already parse snapshot
  chunks, so a later version can compact without breaking this one.
- **The LWS location (§7).** Listed as coming soon; `t_lws` is derivable.
- **Live folder locations** (SAF, a desktop sync folder). The backup file
  covers "anywhere else".
- **Other coins' labels and notes, incoming annotations, settings** (§14).
- **Testnet and stagenet.** Only mainnet Monero is backed up.
