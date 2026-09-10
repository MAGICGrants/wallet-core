import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Covers the *production* KDF backend, [WebCryptoPbkdf2].
///
/// `package:webcrypto` binds BoringSSL over FFI and cannot resolve its symbols
/// under `flutter test` without a host build (`dart run webcrypto:setup`, which
/// needs cmake and Go). So these tests probe at runtime:
///
///   - backend available          -> run the assertions
///   - unavailable, env unset     -> skip with an actionable message
///   - unavailable, env set to 1  -> **fail**
///
/// That last case is the point. This file is what makes substituting
/// [PointyCastlePbkdf2] in the unit tier legitimate; if it silently skipped in
/// CI, the fast tests would be proving something about a backend we do not
/// ship. Setting `REQUIRE_NATIVE_CRYPTO=1` in CI turns "quietly skipped" into a
/// red build.
///
/// Runtime gating rather than `@Tags` is deliberate: a `skip:` in
/// `dart_test.yaml` wins over `--tags`, and `exclude_tags` combines with it to
/// match nothing at all. Both were verified, neither can actually run a tagged
/// test on demand.
const _vectors = [
  (
    password: 'password',
    salt: 'salt',
    iterations: 1,
    length: 32,
    expected: '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
  ),
  (
    password: 'password',
    salt: 'salt',
    iterations: 4096,
    length: 32,
    expected: 'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a',
  ),
  (
    password: 'passwordPASSWORDpassword',
    salt: 'saltSALTsaltSALTsaltSALTsaltSALTsalt',
    iterations: 4096,
    length: 40,
    expected:
        '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1'
        'c635518c7dac47e9',
  ),
];

String _hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Future<Uint8List> _run(
  Pbkdf2Kdf kdf,
  ({String password, String salt, int iterations, int length, String expected}) v,
) => kdf.derive(
  password: v.password,
  salt: Uint8List.fromList(utf8.encode(v.salt)),
  iterations: v.iterations,
  keyLengthBytes: v.length,
);

bool get _required => Platform.environment['REQUIRE_NATIVE_CRYPTO'] == '1';

Future<bool> _webCryptoAvailable() async {
  try {
    await const WebCryptoPbkdf2().derive(
      password: 'probe',
      salt: Uint8List(16),
      iterations: 1,
      keyLengthBytes: 32,
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// Returns true when the caller should proceed; skips (or fails) otherwise.
Future<bool> _ensureAvailable() async {
  if (await _webCryptoAvailable()) return true;
  if (_required) {
    fail(
      'REQUIRE_NATIVE_CRYPTO=1 but package:webcrypto could not load its '
      'symbols. Run `dart run webcrypto:setup` (needs cmake and Go) before '
      '`flutter test`. Skipping here would leave the KDF substitution used by '
      'the unit tests unverified.',
    );
  }
  markTestSkipped('needs `dart run webcrypto:setup` (cmake + Go)');
  return false;
}

void main() {
  group('WebCryptoPbkdf2', () {
    for (final v in _vectors) {
      test('matches the vector for c=${v.iterations}, dkLen=${v.length}', () async {
        if (!await _ensureAvailable()) return;
        expect(_hex(await _run(const WebCryptoPbkdf2(), v)), v.expected);
      });
    }

    test('agrees byte-for-byte with PointyCastlePbkdf2', () async {
      if (!await _ensureAvailable()) return;
      for (final v in _vectors) {
        expect(
          _hex(await _run(const WebCryptoPbkdf2(), v)),
          _hex(await _run(const PointyCastlePbkdf2(), v)),
          reason: 'KDF backends diverged at c=${v.iterations}',
        );
      }
    });
  });

  group('WalletFileCrypto on the production KDF', () {
    test('round-trips at the real platform iteration count', () async {
      if (!await _ensureAvailable()) return;
      // The unit tier always runs at 1000 rounds against pointycastle. This is
      // the only place the shipped configuration is exercised end to end.
      const secret = '{"v":2,"format":"polyseed","mnemonic":"not a real seed"}';
      final blob = await WalletFileCrypto.encryptToBase64(secret, 'pw');
      expect(await WalletFileCrypto.decryptFromBase64(blob, 'pw'), secret);
    });
  });
}
