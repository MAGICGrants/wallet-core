# wallet_fhse

**Proof of concept.** vtnerd's [FHSE](https://github.com/vtnerd/fhse) (FIDO2
hmac-secret encryption) guarding the wallet password, so a YubiKey and its PIN
(or a YubiKey Bio's fingerprint) are needed to open the wallet file.

## What it does

The wallet password becomes FHSE's root `k_p`, derived from the seed. The
derivation mirrors the key tree vtnerd proposes in
[jeffro256/carrot#9](https://github.com/jeffro256/carrot/issues/9):

```
seed                    polyseed / BIP39
 └ M                    the metadata root (wallet_domain's MetadataSecret):
                          polyseed  H_32[keygen(64)[32:64]]("Carrot polyseed legacy metadata secret")   (PM-a)
                          BIP39     H_32[SLIP21(S)/"Monero"]("Carrot BIP39 legacy metadata secret" ‖ 0) (BM-a)
    └ s_u               crypto_kdf_blake2b, context "SKY_SU01"
       └ s_f            crypto_kdf_blake2b, context "SKY_SF01"   (the FHSE seed)
          └ k_p         FHSE root: crypto_kdf_blake2b(s_f, "FHSEROOT"), z85 (the wallet password)
```

**`M` stands in for Carrot's `s_me`.** Carrot's master secret `s_m` exists only
in the new key hierarchy, which lwsf and wallet2 do not have yet. `M` is the
same root the metadata backup (`wallet_backup`) derives its keys from, behind
its own domain string, and is reached from the seed by hashes only. The domain
strings are placeholders until a Monero addendum fixes them; `s_u` and `s_f`
use this proof of concept's own contexts.

A 25-word legacy seed *is* the spend key, whose public key is in the address,
which is why carrot#9 excludes legacy keys. Such a wallet gets a random `s_f`.

There are two states:

| | Keystore holds | FHSE file | Opening the wallet needs |
|---|---|---|---|
| **Off** (after onboarding) | `k_p`, as the random password used to be | none | App Lock, if on |
| **On** (Settings > Advanced security) | the FHSE outer password, a random 32 bytes | `wallet.fhse`: `k_p` wrapped once per key | App Lock, if on, then a key and its PIN or fingerprint |

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
  enrolled with one opens with the other. See the platform halves:
  this plugin's `android/src/main/kotlin/.../SecurityKeyOperations.kt`, and
  each app's `ios/Runner/SecurityKeyOperations.swift`.
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
- **Background sync** cannot reach `k_p`, so each coin opens view-only
  (`CryptoWallet.prepareViewOnly` / `openViewOnly`), from what it kept in the
  keystore when keys were switched on:
  - Monero, in LWS mode: the address and view key, to query the light-wallet
    server. In node mode it opens wallet2's view-only background cache.
  - Bitcoin: the account xpub, from which the addresses are derived again. It
    spends nothing but reveals the account's whole history.
  - Ethereum and its ERC-20 tokens: the address, which is public anyway.
- **The same phrase in two apps** gives the same `k_p` in both (the derivation
  has no per-app part, as carrot#9 proposes none), and either app's `k_p`
  opens its `master_seed` and so the phrase. A phrase used in two apps is only
  as protected as the less protected one; Advanced security says so.

## Layout

- `src/vendor/`: sources, vendored unmodified except as noted.
  - FHSE, from the `implement-fhse-concept` branch of
    [MAGICGrants/fhse](https://github.com/MAGICGrants/fhse) (a fork of
    vtnerd/fhse): `35b32c6` plus the audit fixes (32-byte KDF input, atomic
    open, PIN and credProtect in `device.c`).
  - libcbor 0.13.0, with its two CMake-generated headers written by hand.
  - libsodium 1.0.22 stable.
- `src/wfhse.{h,c}`: the C interface Dart binds to. Only these 18 functions
  are exported.
- `src/CMakeLists.txt`: the Android build and host builds. The defines follow
  libsodium's own `build.zig`.
- `ios/`: the CocoaPods build of the same sources, through forwarding files
  that `tool/generate_ios_classes.sh` generates. Re-run that script after
  changing anything under `src/`.
- `lib/wallet_fhse.dart`: `FhseSecret`, `WalletKeyTree`, `FhseVault`,
  `FhseWalletGuard` (wallet_domain's `WalletPasswordGuard`), and
  `SecurityKeyService`, the Dart end of the security key channel.
- `lib/security_keys_ui.dart`: the shared screens (Advanced security, setting
  keys up, unlocking with a key or the recovery phrase), their strings
  (`lib/src/l10n`, `FhseLocalizations`; regenerate with `flutter gen-l10n`
  here) and the "Fully lock after" timer (`SecurityKeyFullLock`). An app
  installs `SecurityKeysUi` with its name, logo, home route and
  `WalletManager`, adds `FhseLocalizations.delegate`, and routes to
  `AdvancedSecurityScreen` and `SecurityKeyUnlockScreen`.
- `android/src/main/kotlin/`: the security key channel on Android
  (`WalletFhsePlugin`, YubiKit from Maven Central), registered like any
  plugin. Its manifest adds the NFC permission and the optional NFC and USB
  host features.
- iOS: the channel's Swift half (`SecurityKeyChannel.swift`,
  `SecurityKeyOperations.swift`) is still each app's, in `ios/Runner`, with
  YubiKit Swift added to the Runner project as a Swift package. A CocoaPods
  plugin cannot depend on a Swift package; the files can move here once the
  apps build their plugins with Swift Package Manager. Keep the two apps'
  copies identical.

## Why not a Rust crate like wallet_openalias

Each app's iOS build already force-loads one Rust static library. Force-loading
a second one fails to link: both carry the Rust standard library, so the
symbols are duplicated. A plain C plugin avoids that.

## Tests

See `test/README.md`. The tests run the real native library on the host. They
pin FHSE's own test vector and run the vault lifecycle against a simulated
key: set up, unlock, add, set up again, recovery phrase, turn off, delete.

## Known limits

- **Not tested on hardware.** The CTAP2 code compiles against YubiKit Swift
  1.4.0 and yubikit-android 3.1.0.
- **FIDO2 over USB-C on iPhone and iPad** needs YubiKey firmware 5.8 or later.
  NFC and Lightning work with any YubiKey 5 series key on firmware 5.2 or
  later.
- **FHSE's outer layer uses libsodium's minimum Argon2id cost** (audit FH-02).
  That is harmless here, because the outer password is 256 random bits, never
  typed.
- **A key reset** (too many wrong PINs) removes the key from every wallet it
  protects. Use another enrolled key or the recovery phrase.
- **Not erased from memory:** PINs and the z85 password, as Dart strings.
  Native buffers are wiped.
- **YubiKey Bio** speaks FIDO over USB HID only (no NFC, no CCID), so it works
  on Android over USB-C but cannot reach an iPhone.
