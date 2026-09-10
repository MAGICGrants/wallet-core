import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Canonical PBKDF2-HMAC-SHA256 vectors (the SHA-256 analogue of the RFC 6070
/// SHA-1 set). These are what make it safe for the unit tier to substitute
/// [PointyCastlePbkdf2] for the production [WebCryptoPbkdf2].
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
    iterations: 2,
    length: 32,
    expected: 'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
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

void main() {
  group('PointyCastlePbkdf2 (the unit-test backend)', () {
    const kdf = PointyCastlePbkdf2();

    for (final v in _vectors) {
      test('matches the vector for c=${v.iterations}, dkLen=${v.length}', () async {
        expect(_hex(await _run(kdf, v)), v.expected);
      });
    }
  });

  // The production backend is covered in pbkdf2_native_test.dart, which needs
  // a host BoringSSL build and is therefore tagged `native-crypto`.
}
