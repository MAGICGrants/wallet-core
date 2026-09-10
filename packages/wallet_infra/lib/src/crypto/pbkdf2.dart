import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:webcrypto/webcrypto.dart' show Hash, Pbkdf2SecretKey;

/// PBKDF2-HMAC-SHA256, behind an interface.
///
/// This exists because of a testability problem, not because we want two
/// implementations. `package:webcrypto` binds BoringSSL through FFI, and under
/// `flutter test` it needs a host build produced by `dart run webcrypto:setup`
///, which requires cmake and Go on the machine. Without them, every test that
/// touches [WalletFileCrypto] fails with "could not find required symbols",
/// which would leave the single most security-critical primitive in this repo
/// covered only by an integration tier that needs a device.
///
/// So: production uses [WebCryptoPbkdf2] (native, fast enough for 600k rounds),
/// unit tests substitute [PointyCastlePbkdf2] (pure Dart, no native deps, far
/// too slow for production rounds but fine at test rounds). The substitution is
/// only safe because the two are proven byte-identical; see
/// `test/pbkdf2_test.dart`, which checks both against published
/// PBKDF2-HMAC-SHA256 vectors.
abstract class Pbkdf2Kdf {
  const Pbkdf2Kdf();

  Future<Uint8List> derive({
    required String password,
    required Uint8List salt,
    required int iterations,
    required int keyLengthBytes,
  });
}

/// Native BoringSSL via FFI. ~10-50x faster than pure Dart, and safe to call
/// inside `Isolate.run` (no platform channel). The production default.
class WebCryptoPbkdf2 extends Pbkdf2Kdf {
  const WebCryptoPbkdf2();

  @override
  Future<Uint8List> derive({
    required String password,
    required Uint8List salt,
    required int iterations,
    required int keyLengthBytes,
  }) async {
    final key = await Pbkdf2SecretKey.importRawKey(utf8.encode(password));
    return key.deriveBits(keyLengthBytes * 8, Hash.sha256, salt, iterations);
  }
}

/// Pure Dart. No native dependency, so it runs anywhere `dart test` runs.
///
/// Do not use in production: at the desktop count of 600k rounds this takes
/// seconds, not milliseconds.
class PointyCastlePbkdf2 extends Pbkdf2Kdf {
  const PointyCastlePbkdf2();

  @override
  Future<Uint8List> derive({
    required String password,
    required Uint8List salt,
    required int iterations,
    required int keyLengthBytes,
  }) async {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iterations, keyLengthBytes));
    return derivator.process(Uint8List.fromList(utf8.encode(password)));
  }
}

// `FastTestPbkdf2` lives in `package:wallet_infra/testing.dart`. It clamps the
// round count, so it is kept out of the import an application reaches for.
