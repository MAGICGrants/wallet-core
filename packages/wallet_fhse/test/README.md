# wallet_fhse tests

The tests run the real native library, built for the host from `src/`:

```sh
cmake -S src -B build/host -DCMAKE_BUILD_TYPE=Release
cmake --build build/host -j8
flutter test
```

`test/support/host_library.dart` finds `build/host/libwallet_fhse.{dylib,so}`,
or the path in `WALLET_FHSE_LIBRARY`. Without either, every test is skipped
with a message saying so rather than failing.

No unit test talks to a FIDO2 key (the parity check below is run by hand). `FakeSecurityKey` stands in for one: each
credential has its own random secret, and the "hmac-secret" is a keyed hash of
the salt under it, which is all FHSE relies on (a stable, credential-specific
32-byte output per salt). The CTAP2 side is the platform channels' job and is
exercised on hardware.

## On hardware: hmac-secret parity

A key's hmac-secret depends only on the credential, the salt, and whether the
user was verified. FHSE always verifies the user, so one credential and one
salt must give the same 32 bytes through every backend: yubikit-android,
YubiKit Swift (iOS and macOS), libfido2 (Linux, and FHSE's own `device.c`) and
`webauthn.dll`. This checks that no backend hashes or re-encodes the salt on
the way. `hmac_parity_test.dart` covers the tooling; the comparison itself
needs a real key.

Both sides use a fixed, published salt, SHA-256("FHSE hmac-secret parity test
v1"), never a wallet's, and a throwaway credential under `fhse:encryption`.
Use the same key throughout: a credential lives on one key.

1. **libfido2's reading** (Linux, or macOS with `brew install libfido2`), from
   this package's directory:

   ```sh
   sh tool/hmac_parity.sh enroll
   ```

   libfido2's tools ask for the PIN and a touch twice: to create the
   credential, then to read it. The key needs a PIN, as FHSE does
   (`fido2-token -S <device>` sets one). The script prints a `credential:`
   and an `hmac-secret:` line.

2. **Each app backend**: run a debug build of Skylight or Spice on the platform,
   open Settings > Advanced Security > Developer > hmac-secret parity test,
   paste the credential, enter the PIN (or use a YubiKey Bio's fingerprint),
   and tap Read credential. Its `hmac-secret:` line must equal the script's.
   The screen is compiled into debug builds only and does not touch the wallet.

3. **The other way round**: tap Create credential in the app, then run the
   command it prints (`sh tool/hmac_parity.sh assert '<credential>'`) and
   compare again.

A mismatch means that backend changes the salt or reads the key's non-verified
secret (both the script and the app refuse an answer without the UV flag).
Note which platform and key it was.

The credentials are non-discoverable and take no space on the key.
