import 'dart:typed_data';

import '../crypto/pbkdf2.dart';

/// True in a release build.
///
/// `dart.vm.product` is exactly what `kReleaseMode` reads. Using it directly
/// keeps this file free of a Flutter import, so it stays usable from the plain
/// `dart run` tooling.
const bool _isReleaseBuild = bool.fromEnvironment('dart.vm.product');

/// **Tests only.** Pure Dart with the round count clamped to [maxIterations],
/// whatever the caller asked for.
///
/// The stores take no iteration count, so every test that round-trips a wallet
/// file would otherwise pay 600k rounds of pure-Dart PBKDF2 twice.
///
/// The clamp lives here rather than as a flag on `WalletFileCrypto`: a
/// production KDF that can be told to do fewer rounds is one misplaced line from
/// shipping. Const and field-free, so it still crosses an `Isolate.run` boundary.
///
/// Kept out of shipped apps two ways: it is not exported from
/// `package:wallet_infra/wallet_infra.dart`, and it throws in a release build.
class FastTestPbkdf2 extends Pbkdf2Kdf {
  const FastTestPbkdf2();

  static const int maxIterations = 1000;

  @override
  Future<Uint8List> derive({
    required String password,
    required Uint8List salt,
    required int iterations,
    required int keyLengthBytes,
  }) {
    if (_isReleaseBuild) {
      throw StateError(
        'FastTestPbkdf2 was used in a release build. It clamps PBKDF2 to '
        '$maxIterations rounds while the blob header still records the real '
        'count, so anything written with it is far weaker than it claims and '
        'cannot be read back once this is corrected.',
      );
    }
    return const PointyCastlePbkdf2().derive(
      password: password,
      salt: salt,
      iterations: iterations < maxIterations ? iterations : maxIterations,
      keyLengthBytes: keyLengthBytes,
    );
  }
}
