# wallet_backup

The seed-keyed metadata backup: who each Monero payment went to, its
transaction key, and the address book, saved as many small sealed files in
every location the user chooses. Pure Dart; the platform locations (iCloud)
and the screens are in `wallet_backup_platform`.

## Keys

```
seed ──► M          wallet_domain's SeedSecret, SeedPurpose.metadata (polyseed or BIP39)
M    ──► K          H_32[M]("Monero metadata backup v1")
K    ──► k_enc(e)   H_32[K]("encryption key" ‖ IntToBytes16(e))     seals every file
     ──► k_name     H_32[K]("naming key")                           names at a location
     ──► t_lws(e)   H_32[K]("LWS write token" ‖ IntToBytes16(e))    for the LWS location, later
```

`H_32` is Carrot's keyed BLAKE2b ("Monero" personalisation, length-prefixed
domain). Every step is a hash, so a quantum computer that can compute the view
and spend keys from an address learns nothing here. **25-word seeds have
no backup**: they are the spend key. The strings are fixed: changing one would
move every backup to a new key and folder. The security-key (FHSE) seed is a sibling of `M` under the
same seed root, with its own domain string, not derived from `M`.

The keys are derived at unlock (PBKDF2 for polyseed and BIP39, off the UI
isolate), held in memory while the wallet is open, and wiped on a full lock.
They are never written to disk.

## Files

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
`wallet_fhse`) and draft-irtf-cfrg-xchacha's vectors, and check `M` against
independently computed vectors.

## Service

`MetadataBackupService` is wallet_domain's `MetadataBackup` seam. The app
installs it (through `wallet_backup_platform`) on the UI isolate.

- **Opt-in.** Off until the user turns it on (`setEnabled`), and every location
  is off until the user turns that one on too. While off, nothing is written,
  not even the local copy or the device state, and no location is read; the
  service only holds the unlocked wallet's keys so it can be turned on without
  unlocking again. Turning it off turns every location off and deletes the
  local copy and the device state. Deleting the wallet also forgets the
  switches. It is off by default because anyone
  with the seed and a copy can read who the user paid, a cost the user should
  choose.
- **Only the user deletes a backup.** The one way a location's files are
  deleted is the user's delete for that location (`deleteFromLocation`:
  "Delete the iCloud copy", "Delete the Android backup copy"). Otherwise:
  - Turning a location on reads what is there and adds what it lacks. It
    never removes a file or replaces one (a different file under one of our
    names is left as it is).
  - Turning a location off only stops adding. Its files stay, and Android
    backup keeps carrying an on-device location's.
  - Turning the whole backup off, deleting the copy on this device and
    deleting the wallet remove only the app's own local copy and device
    state, never a location's files. That covers a step undone because it
    did not complete (a cancelled save, a failed import), and a copy Android
    restored to a location the user never turned on.
  - A saved backup file is the user's: it is written under a new name (the
    date and time) and never touched again, and importing one only reads it.
- **Writing.** Each write is one file: a payment, or everything one sync
  records (its address-book changes, or the payments a history scan
  backfills). The seq is saved first, the file goes to the local copy
  (temporary name, flushed, renamed), then to every enabled location. Payment
  files reach iCloud after a random delay of up to 10 minutes.
- **Payments.** `MoneroWallet.commitTx` hands the payment over straight after
  the broadcast, with the key read from the wallet. A history scan also records
  every outgoing payment this wallet built that has no record yet, including
  ones from before the backup existed. monero_c does not give a pending
  transaction's keys, so the record is written right after the broadcast, not
  before it.
- **Address book: only changes made while syncing travel.** A device that is
  syncing merges three ways: what its address book held at the last sync is the
  base (in the device state), so an edit or deletion made here becomes a new
  version, which wins, and a change made elsewhere is applied here (through
  `ContactsSync`, which an open `ContactModel` takes in memory). A change
  that could not be stored here (the address book could not be written) stays
  out of the base and is applied again by the next sync, so it never reads as
  a deletion or edit made here. A device that
  *joins* (its first sync, a restore, or a location turned on when none was)
  has no base and cannot tell its own changes from a stale copy. It takes the backup's
  version of every contact the backup knows, deletions included, and adds only
  contacts the backup has never seen:

  | While this device was not syncing | After it joins |
  |---|---|
  | A contact was deleted or edited elsewhere (while that device synced) | Deleted or edited here too |
  | A contact was added here | Added to the backup |
  | A contact was deleted or edited here | Back as the backup has it |

  So every copy converges on what was synced, and a copy that was off can add
  contacts but never undo a synced change. The join waits until every enabled
  location has been read, so an unreachable location cannot make an old copy
  look new. Nothing is kept while the backup is off.

  With every location off but the backup on (kept for saving files), the
  address book does not sync: nothing changed here is recorded, so nothing can
  travel later, and the next location turned on joins. A saved file carries the
  address book as it is then, under a device id of its own; importing a file
  applies it as a join applies the backup.
- **Reading.** On open, on resume, every 5 minutes, and after every change:
  list each location, open anything new, merge, apply, upload what is missing.
- **Restore.** A new device id, then every enabled location is read. With the
  backup off, nothing is read until the user chooses to import: after a
  restore, `findBackups` looks in each location without writing or turning
  anything on, and the backup is turned on only with the locations where one
  was found (`wallet_backup_platform`'s "Import wallet data" screen). A wallet's history
  takes destinations and keys from the backup for payments it lost
  (`CryptoWallet._withCarriedFields`). The report lists unreadable files,
  sequence gaps, and payments with two different records.
- **Export.** `exportBundle` gives every sealed file in one file
  (`u32 length ‖ file`, repeated; no names, no magic) for anywhere else;
  `importBundle` reads one back.

## What a storage location can see

The files are sealed and their names hashed, so a location cannot read who was
paid, a transaction key or a contact; without the seed nothing in them opens.
Anyone with the seed and the files can read all of it. What a location can
still see:

- **Whose files they are.** iCloud and Android backup keep them under the
  user's Apple or Google account (or the phone's own backup service), and the
  operating system uploads them outside Tor, from the device's own network
  address.
- **Which app.** Each app has its own iCloud container and Android package, so
  the location knows Skylight or Spice is in use.
- **That the files belong to one wallet.** The folder name comes from the seed,
  so it is the same on every device and never changes: the location can link a
  wallet's files across devices and over time, though not to its addresses.
- **How much happens.** Each sent payment is one file, and so is each sync
  that changed the address book (all its edits together) or backfilled
  payments. Files are deleted only when the user deletes them there, so their
  count roughly tracks payments and editing sessions.
- **Roughly when.** Upload times. A payment's file reaches iCloud after a
  random delay of up to 10 minutes; contact changes are not delayed. Android
  backup runs about once a day, which blurs timing there.
- **Roughly how much a file holds.** Files are padded to at least 1 KiB and
  rounded up with PADMÉ, so a size says only roughly how many records it
  carries.
- **A saved backup file** shows the same through its size, wherever it is
  kept.

A location can also **withhold files**: leave some out, or show an older set.
The seal stops it forging or changing a file, but a device that restores or
joins from it then misses what those files held: payments, and newer versions
of contacts, so its address book can show an older version of a contact, or
one deleted since. The restore report shows some of it: a file missing from
the middle of a device's run (a sequence gap), or past the last one here that
another device's files show it saw. Files a location withholds from the end,
before anyone saw them, cannot be told from files never written; a second
location holding the same files is the remedy.

## Not yet supported

- **Compaction.** The backups can be periodically compacted to reduce storage use.
- **Backup to LWS.** The intent is to support using a LWS as a backup location.
- **Live folder locations** (SAF, a desktop sync folder). The backup file
  covers "anywhere else".
- **Other coins' labels and notes, incoming annotations, settings.**
- **Testnet and stagenet.** Only mainnet Monero is backed up.
