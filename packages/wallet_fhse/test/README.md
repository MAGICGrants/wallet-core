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

No test talks to a FIDO2 key. `FakeSecurityKey` stands in for one: each
credential has its own random secret, and the "hmac-secret" is a keyed hash of
the salt under it, which is all FHSE relies on (a stable, credential-specific
32-byte output per salt). The CTAP2 side is the platform channels' job and is
exercised on hardware.
