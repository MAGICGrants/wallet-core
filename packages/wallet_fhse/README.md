# wallet_fhse

vtnerd's [FHSE](https://github.com/vtnerd/fhse) (FIDO2 hmac-secret
encryption) guards the wallet password, so a YubiKey and its PIN
(or a YubiKey Bio's fingerprint) are needed to open the wallet file.

**What it protects.** With security keys on, opening the wallet takes App Lock
and then one of your keys with its PIN or fingerprint. This is much more secure
than App Lock or a password alone. The stored files use quantum-resistant
encryption; the one exception is the exchange with the key itself (see Known
limits). Your recovery phrase is still the main key to the wallet, so keep it
as safe as before.

**What it cannot protect.** The file that links the wallet to your keys is
sensitive. An app holding it could ask your key for the same secret if it
tricks you into entering your PIN and touching the key. Where possible, that
file is encrypted with a password kept in your device's secure storage (on
Linux and Windows it is the password you type, which protects it less), left
out of device backups, and on Windows tied to that PC. None of this helps once
the device itself is compromised: malware that controls it, or can read the
app's memory, can capture the secret while you unlock or use the wallet.

## What it does

The wallet password becomes FHSE's root `k_p`, derived from the seed. The FHSE
seed `s_f` sits beside the metadata root `M`, not under it (wallet_domain's
`SeedSecret`):

```
seed                    polyseed / BIP39
 ├ M                    the metadata root, for wallet_backup ("Monero metadata secret")
 └ s_f                  the FHSE seed:
                          polyseed  H_32[keygen(64)[32:64]]("Monero FHSE seed")
                          BIP39     H_32[SLIP21(S)/"Monero"]("Monero FHSE seed" ‖ IntToBytes32(0))
    └ k_p               FHSE root: crypto_kdf_blake2b(s_f, "FHSEROOT"), z85 (the wallet password)
```

**No intermediate root.** Each purpose hashes straight from the seed's secret
above its spend key (bytes 32–63 of polyseed's keygen, or BIP39's SLIP-21
`Key(m/"Monero")`) under its own domain string, so neither key is derived from
the other ([polyseed#25](https://github.com/tevador/polyseed/issues/25)
weighed this against a root above both). A BIP39 account goes into each
purpose (both apps use account 0). Every step is a hash, and the domain
strings are fixed: changing one would change every seed-derived wallet
password.

A 25-word legacy seed *is* the spend key, whose public key is in the address,
so anything derived from it falls to a discrete-log solver. Such a wallet gets
a random `s_f` (`WalletKeyTree.isSeedDerived`).

**Offset passphrases are not supported yet:** neither app accepts one. When
they are, the polyseed offset `o` (`cn_slow_hash` of the passphrase) goes into
every purpose, as the BIP39 account does: Monero applies the offset after
keygen, so without `o` an offset wallet would get the plain wallet's `s_f`.
Until then `SeedSecret.isAvailableFor` refuses an offset polyseed rather than
derive without `o`.

There are two states:

| | Keystore holds | FHSE file | Opening the wallet needs |
|---|---|---|---|
| **Off** (after onboarding) | `k_p`, as the random password used to be | none | App Lock |
| **On** (Settings > Advanced Security) | the FHSE outer password, a random 32 bytes | `wallet.fhse`: `k_p` wrapped once per key | App Lock, then a key and its PIN or fingerprint |

On Linux and Windows the user types the wallet password, and no keystore
holds one. There the typed password takes the keystore's place: while keys are
off, `wallet.key` holds `k_p` encrypted with it (PBKDF2, as the wallet files
were before); once they are on, it is `wallet.fhse`'s outer password and
`wallet.key` is gone, so opening the wallet takes the typed password and then a
key. Every setup deletes `wallet.key` together with the older copies an
interrupted write of it left beside it (`wallet.key.<pid>-<n>.tmp`), and a key
unlock finishes the job if a setup was cut short; any setup, on every platform,
also deletes older FHSE files left the same way (`wallet.fhse.<pid>-<n>.tmp`),
which a removed key could still open. Copies outside the app's folder (a backup
of it) are out of reach. Only wallets created on this build work this way. An older desktop wallet
keeps its typed password as its wallet password, and keys are not offered for
it, as for an older phone wallet.

**On Windows both files are bound to the PC** (wallet_infra's `PcBinding`). A
secret only this PC's TPM can produce goes into the password `wallet.key` and
`wallet.fhse` are encrypted with, beside the typed password: an RSA-2048 key
made inside the TPM through CNG's Platform Crypto Provider, used with no
prompt, signs a stored challenge, and the signature keys an HMAC. A copy of
either file (a backup, a disk image, a copy taken off the disk) then cannot be
opened, nor its password guessed, on another computer. It does not stop a
program running on this PC as the same user, which can use the TPM key just as
it can ask a security key. A bound wallet opens only on this PC: on another
one, or once the TPM is cleared, the unlock says so instead of "wrong
password", and the wallet is restored from its recovery phrase as a new
wallet. `pc_binding.json` beside the files names the TPM key and challenge and
keeps a check that tells another TPM from a wrong password. A PC without a TPM
writes the files unbound, as before; a `wallet.key` written unbound (by an
earlier build) is bound at its next unlock. An older desktop wallet, whose
typed password is its wallet password, is not bound: that would mean
re-encrypting every wallet file. Linux is not bound: its TPM usually needs a
group membership most users lack.

Where the password's copy lives is wallet_domain's `WalletPasswordStore`: the
keystore on Android, iOS and macOS, `wallet.key` (or nothing, for an older
wallet) on Linux and Windows. FHSE only removes the copy when keys go on and
puts it back when they go off. Files are encrypted with 600,000 PBKDF2
iterations under a typed password (`wallet.key`, an older desktop wallet's
files) and 100,000 under a generated or seed-derived one, which nobody can
guess anyway.

How each part fits:

- **The FHSE seed is stored, not discarded.** `s_f` sits in `fhse_seed`,
  encrypted under `k_p`. Keys can therefore be set up at any later time
  without the recovery phrase.
- **No re-encryption when keys are switched on.** `k_p` is the same before and
  after, so neither the wallet files nor `master_seed` nor `xmr_cache` change.
- **User verification is required, and the key enforces it.** Every
  credential is created with credProtect level 3. Every makeCredential and
  getAssertion carries a PIN/UV token, so the key returns its with-UV
  hmac-secret. The token comes from the key's PIN, or from a YubiKey Bio's
  fingerprint reader (`KeyVerification`); both set CTAP's UV flag, so a key
  enrolled with one opens with the other. The fingerprint is used only on a
  key whose PIN is set: on a key without one, whoever holds it could set a
  PIN and use that instead, so such a key gets a PIN first. See the platform
  halves: this plugin's `android/src/main/kotlin/.../SecurityKeyOperations.kt` and
  `apple/SecurityKeyOperations.swift`.
- **Every key's answer is checked once, in Dart.** Each platform reaches the
  key its own way, but returns what the key sent, authenticator data included,
  and `SecurityKeyService` checks it the same way for all of them
  (`lib/src/key_reply.dart`): user verified, credProtect level 3 and
  hmac-secret on for a new credential, an answer from a credential that was
  asked for, a 32-byte secret. The Kotlin and Swift halves keep their own
  checks as a first line.
- **Names come after the touches.** The app asks for a key's name once it has
  been enrolled (`FhseSetup.rename`, `FhseVault.renameKey`). Names live in the
  keystore; FHSE's file holds only credential ids.
- **Serial numbers identify keys before the PIN.** credProtect level 3 hides a
  credential until the PIN is verified, so FIDO cannot say which key is
  connected beforehand. The authenticator may return the key's serial
  (`KeyAssertion.serial`, a YubiKey's), which is kept with its name
  (`SecurityKeyRecord.serial`) and filled in on unlock if it was missing.
- **Adding a key** uses the FHSE file this session already unlocked, so no
  existing key needs another tap.
- **Removing a key means setting up again** with only the keys to keep. That
  builds a new FHSE file from the same `s_f`, so `k_p` stays the same, but
  with a new FIDO2 salt and user id. The dropped key's credential cannot open
  it.
- **Lost every key?** For polyseed and BIP39 wallets, the recovery phrase
  rebuilds `k_p` and opens the existing files, keeping local history.
  25-word wallets are restored from the phrase as before.
- **One FHSE file covers every coin.** `k_p` is the app's one wallet
  password: every coin's wallet file and cache, and `master_seed`, are
  encrypted with it. So a multi-coin app (Spice) has one `wallet.fhse` and one
  key touch per unlock, and a coin added later bootstraps from `master_seed`
  under the same `k_p`.
- **Every run without the user** (a Periodic run, Continuous Sync) is
  view-only whether or not keys are on: it never loads
  `k_p` or the seed store (`WalletManager.isUnattendedRun`), and each coin opens
  view-only (`CryptoWallet.prepareViewOnly` / `openViewOnly`) from what it keeps
  in the keystore while such a run is on, or keys are
  (`WalletManager.applyViewOnlySetting`). A coin without it is skipped, never
  opened with its keys:
  - Monero, in LWS mode: the address and view key, to query the light-wallet
    server. In node mode it opens wallet2's view-only background cache.
  - Bitcoin: the account xpub, from which the addresses are derived again. It
    spends nothing but reveals the account's whole history.
  - Ethereum and its ERC-20 tokens: the address, which is public anyway.
- **The same phrase in two apps** gives the same `k_p` in both (the derivation
  has no per-app part), and either app's `k_p`
  opens its `master_seed` and so the phrase. A phrase used in two apps is only
  as protected as the less protected one; Advanced Security says so.
- **Secrets and settings need a passing App Lock**, asked again however
  recently it last passed: the recovery phrase, secret and view keys, Advanced
  Security, and a longer lock. Screens are routed through `AppLockGate`; a
  desktop sheet or an action calls `passAppLock` first. The platform decides
  what App Lock is, never the caller: the device's own prompt where the
  keystore holds the wallet password (Android, iOS, macOS), the typed wallet
  password on Linux and Windows. The security key is not asked for again:
  with keys on, opening the wallet already needed one. If a way to open it
  without a key is ever added, these screens need revisiting.
- **App Lock's unlock screen decides here, once for both apps.**
  `unlockAppLockWithDevice` (Android, iOS, macOS) and
  `unlockAppLockWithPassword` (Linux, Windows) wait for a lock still closing,
  put the password back or check it, hand over to a security key when one is
  needed, and mark the session unlocked; each returns an `AppLockUnlock` the
  app's screen only shows. When the device cannot confirm its owner, or no
  password comes back, the outcome is `failed` and the screen offers the
  recovery phrase (`showAppLockRecoveryPhrase`).

## Layout

- The C library (FHSE, libcbor and libsodium behind `wfhse.h`, and its builds
  for every platform) is [fhse_native](https://github.com/MAGICGrants/fhse_native),
  pinned by commit in `pubspec.yaml`. `lib/src/fhse_native.dart` binds to it.
- `ios/` and `macos/`: podspecs with no sources. They exist so Flutter links
  this package into the apps, which compile `apple/` through that link.
- `lib/src/backends/`: how Dart reaches a key where no platform channel does:
  `LinuxLibFido2Backend` (the system's libfido2, through `dart:ffi`, on a
  background isolate) and `WindowsWebAuthnBackend` (`webauthn.dll` from
  System32, whose Windows Security dialog asks for the PIN and the touch).
  `SecurityKeyService` picks the backend for the platform.
- `lib/wallet_fhse.dart`: `FhseSecret`, `WalletKeyTree`, `FhseVault`,
  `FhseWalletGuard` (wallet_domain's `WalletPasswordGuard`), and
  `SecurityKeyService`, the Dart end of the security key channel.
- `lib/security_keys_ui.dart`: the shared screens (Advanced Security, setting
  keys up, unlocking with a key or the recovery phrase), their strings
  (`lib/src/l10n`, `FhseLocalizations`; regenerate with `flutter gen-l10n`
  here), "Lock Wallet File After" (`SecurityKeyFullLock` on mobile, counting
  time in the background; `DesktopAutoLock`, `DesktopAutoLockTile` on a
  desktop OS, counting time without use), and App Lock's time and its
  "Lock App After" Settings row (`AppLockPreferences`, `AppLockTimer`,
  `DesktopAutoLock.appLock`, `AppLockTile`, `showAppLockRecoveryPhrase`). An app
  installs `SecurityKeysUi` with its name, logo, home route and
  `WalletManager`, adds `FhseLocalizations.delegate`, and routes to
  `GuardedAdvancedSecurityScreen` (which asks for the device's own check, or
  the typed password, every time it opens) and `SecurityKeyUnlockScreen`.
- `android/src/main/kotlin/`: the security key channel on Android
  (`WalletFhsePlugin`, YubiKit from Maven Central), registered like any
  plugin. Its manifest adds the NFC permission and the optional NFC and USB
  host features.
- iOS and macOS: the channel's Swift half (`SecurityKeyChannel.swift`,
  `SecurityKeyOperations.swift`) is in `apple/`, one copy for both apps and
  both platforms (`#if os(...)` around the connection: NFC, USB-C smart card
  and Lightning on iOS; USB HID on macOS), with `PrivacyCover.swift` (iOS). A
  CocoaPods plugin cannot depend on a Swift package, so each app adds YubiKit
  Swift to its Runner target and compiles these files there, through
  Flutter's plugin link (`apple/README.md`). YubiKit Swift 1.4.0 needs iOS 16 and macOS 13, so both
  apps require them (macOS on Apple silicon only).

## Why not a Rust crate like wallet_openalias

Each app's iOS build already force-loads one Rust static library. Force-loading
a second one fails to link: both carry the Rust standard library, so the
symbols are duplicated. A plain C plugin avoids that.

## Tests

See `test/README.md`. The tests run the real native library on the host. They
pin FHSE's own test vector and run the vault lifecycle against a simulated
key: set up, unlock, add, set up again, recovery phrase, turn off, delete.

## Known limits

- **FIDO2 over USB-C on iPhone and iPad** needs YubiKey firmware 5.8 or later.
  NFC works with any YubiKey 5 series key on firmware 5.2 or later.
- **No Lightning (YubiKey 5Ci) on older iPhones.** App Review accepts the 5Ci's
  External Accessory protocol only from apps registered with Yubico's MFi
  program.
- **One link to the key is not post-quantum.** CTAP2's PIN/UV protocol
  encrypts the hmac-secret salt and output under an ECDH P-256 shared secret
  between the app and the key. Someone who recorded that exchange (over NFC or
  USB) and later has a large quantum computer could recover the hmac-secret,
  and with it `k_p`. CTAP offers no alternative today.
- **The Windows PC binding is not post-quantum.** Its TPM key is RSA-2048,
  and the binding secret is an HMAC keyed by that key's deterministic
  signature. Whoever can factor the modulus stored on disk (with a large
  quantum computer, or on a TPM with the ROCA weakness) can compute that
  secret. What that gives them depends on security keys:
  - **Off:** only the typed password is left, which they can then guess
    offline.
  - **On:** nothing that opens the wallet. The files stay quantum-resistant,
    because opening them still needs the key's hmac-secret, which is
    symmetric, unless an exchange with the key was recorded (the bullet
    above).
- **The Bitcoin xpub kept for unattended runs** gives the public key of every
  address in the account, used or not. Today that reveals only the history;
  against a future quantum computer, a public key is what an attacker needs to
  spend, so an address that has never spent stays protected only while its
  key is unknown. Keeping the watched addresses instead of the xpub would
  avoid that.
- **FHSE's outer layer uses libsodium's minimum Argon2id cost.**
  That is harmless here, because the outer password is 256 random bits, never
  typed.
- **A key reset** (too many wrong PINs) removes the key from every wallet it
  protects. Use another enrolled key or the recovery phrase.
- **Not erased from memory:** whatever is held as a Dart string, which
  cannot be wiped: PINs, the recovery phrase, the FHSE seed as encoded for
  storage, FHSE's outer password, the typed password and its `pc1:` form,
  the z85 wallet password, the Ethereum key in hex and the view keys. On
  Android and Apple the PIN is the platform's own string too. The
  hmac-secret output is wiped where this code holds it, but the platform's
  channel encoding makes copies of its own that are freed without being
  wiped. FHSE's locked memory (`sodium_mlock` on `malloc`'d buffers) is
  page-granular and not reference-counted, so unlocking one buffer can
  unlock a page another still shares, and its `MADV_DONTDUMP` fails on an
  address that is not page-aligned. Future hardening here is desirable.
- **Several keys plugged in** (a computer, or a phone through a USB hub):
  each one blinks and the one touched is used, and the requests after it go
  to that key alone, so a PIN cannot reach another. A key swapped in after
  the touch is refused before any PIN: by its serial number, and on a Mac,
  Linux and Android also by the system's id for that plugging-in (iOS knows
  a USB-C key only by its slot). Where no key can be asked for a touch, or
  Android is not allowed to open one of them, the request is refused
  ("unplug the others"). Windows' own dialog does the same choosing.
- **YubiKey Bio** speaks FIDO over USB HID only (no NFC, no CCID), so it works
  on Android over USB-C and on a Mac, but cannot reach an iPhone.
- **The iPhone app on a Mac** (Apple silicon) has no security keys: it has
  neither NFC nor the Mac app's USB path, so Settings shows no Advanced
  Security there (`SecurityKeyService.isSupportedPlatform`).
- **macOS** follows mobile: a generated wallet password in the Keychain,
  App Lock through Touch ID or the Mac's password, and security keys over USB
  HID (any FIDO2 YubiKey firmware; no NFC). It needs macOS 13 (YubiKit Swift)
  and the sandbox's `com.apple.security.device.usb` entitlement.
- **Linux** reaches keys through the system's libfido2 (`libfido2.so.1`,
  version 1.6 or later, which openssh-client already pulls in on Debian,
  Ubuntu and Fedora; the `.deb` recommends `libfido2-1`). Before 1.12 the
  key's minimum PIN length and forced PIN change cannot be read, so 4 and
  "no" are assumed. Without it the app runs as before and keys
  are unavailable. The key's `/dev/hidraw` node must be readable: systemd 244
  and later grant that to the logged-in user for FIDO keys. Flatpak and Snap
  builds would need device access. libfido2 cannot read a YubiKey's serial, so
  the "which key is this" check before the PIN does not happen on Linux.
  Instead the key touched at the start is held to by the kernel's name for
  that plugging-in of it, and a key swapped in meanwhile is refused before
  the PIN. With several keys plugged in, the user touches the one to use; a
  libfido2 too old to ask for a touch (before 1.7) refuses them.
- **Windows** needs Windows 11, version 22H2 or later (WebAuthn API version 4,
  raw hmac-secret salts). Windows draws the PIN and touch prompts, so the app
  never sees the PIN and cannot check which key is connected first. Only a
  security key reached over USB or NFC is used, never a phone, Bluetooth or
  Windows Hello, and the credential is never discoverable, so nothing is
  stored on the key; a credential Windows made otherwise is refused before
  its secret is read. Untested: whether Windows accepts the relying party id
  `fhse:encryption`, and whether it honours hmac-secret on a non-discoverable
  credential (if not, adding a key fails with "Windows returned no
  hmac-secret").
- **The typed password as FHSE's outer password** (Linux, Windows) inherits
  the minimum Argon2id cost above. Someone who already holds a key, its PIN
  and the file can then guess a weak typed password quickly; the key and its
  PIN are the real barrier. On a Windows PC
  with a TPM that guessing works only on that PC (the binding above).
- **"Lock Wallet File After" is measured on two clocks.** The wall clock and a boot
  clock (`wfhse_boot_ns`: `CLOCK_BOOTTIME` on Android, `CLOCK_MONOTONIC` on
  Apple) that keeps counting while the phone sleeps and cannot be set. Either
  one passing the limit, a wall clock that went backwards, or a boot clock that
  cannot be read locks the wallet on resume, so setting the date back does not
  skip it. The decision is taken before anything else on resume; the app puts
  its lock screens up first and only then closes the wallets, once, with the
  password and FHSE's session dropped before the slow part. The timer itself
  still only runs while the process gets CPU.
- **Nothing here reaches a device backup.** On iOS the app directory (wallet
  files, `master_seed`, `fhse_seed`, `wallet.fhse`) lives in
  `Library/Application Support/wallet`, excluded from iCloud and computer
  backups (`wallet_infra`'s `getAppDir`, `excludeFromDeviceBackup`); builds
  that kept it in Documents move it there once. Android's backup rules include
  only the metadata backup's folder. Keystore items are this-device-only, but an
  encrypted iOS backup restored to the same phone does bring them back; without
  the files they open nothing. Backups made before this change are not touched:
  iCloud replaces its one backup per device on the next run, and older computer
  backups stay until deleted.

  The files are sensitive on every platform for the same reason: a copy that
  outlives the moment keys are set up still opens with what opened it then. So
  on a computer they stay out of backups as far as the OS lets an app ask:
  - **macOS**: the same excluded `Library/Application Support/wallet` (Time
    Machine honours the flag; checked with `tmutil isexcluded` in
    `wallet_infra`'s tests).
  - **Windows**: `%LOCALAPPDATA%\<company>\<product>\wallet`, which never roams.
    Builds before this kept them in `%APPDATA%` (Roaming), which a roaming
    profile copies to a server and folder redirection can put on a share; the
    first start moves them by rename and leaves the settings and secure-storage
    plugins' files there. A Roaming folder on another volume is left in place
    and logged. Neither folder is in File History, Windows Backup or OneDrive by
    default.
  - **Linux**: `~/.<app>_wallet` carries a `CACHEDIR.TAG` and a
    `.deja-dup-ignore`, which Déjà Dup (42.1 and later) always skips and borg,
    restic and tar skip when told to leave out caches. A tool that copies the
    whole home folder regardless still takes them.

  A full-disk image or clone (Carbon Copy Cloner, a VM snapshot) takes
  everything; no flag reaches those.

  Other users on the same computer cannot read them either. On Linux the
  folder is made `0700` and what is in it `0600` at every start, and the
  process's umask is set to `077`, so whatever is written later (by Dart,
  wallet2 or Tor) is the owner's only (`wallet_infra`'s `restrictToOwner`).
  The Mac app's container is `0700` already, and on Windows
  `%LOCALAPPDATA%` inherits the profile's owner-only permissions.
