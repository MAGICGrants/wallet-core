import 'dart:ffi';

import 'package:fhse_native/fhse_native.dart';

typedef _AeadN = Int32 Function(
  Pointer<Uint8> out,
  Size outLen,
  Pointer<Uint8> input,
  Size inputLen,
  Pointer<Uint8> ad,
  Size adLen,
  Pointer<Uint8> nonce,
  Size nonceLen,
  Pointer<Uint8> key,
  Size keyLen,
);
typedef AeadD = int Function(
  Pointer<Uint8> out,
  int outLen,
  Pointer<Uint8> input,
  int inputLen,
  Pointer<Uint8> ad,
  int adLen,
  Pointer<Uint8> nonce,
  int nonceLen,
  Pointer<Uint8> key,
  int keyLen,
);
typedef _ZeroN = Void Function(Pointer<Void>, Size);
typedef ZeroD = void Function(Pointer<Void>, int);

/// fhse_native's libsodium, which seals every backup file: the two
/// XChaCha20-Poly1305 functions of its `wfhse.h`, and its memory wipe.
class BackupNative {
  BackupNative._(DynamicLibrary lib)
    : encrypt = lib.lookupFunction<_AeadN, AeadD>('wfhse_xchacha20poly1305_encrypt'),
      decrypt = lib.lookupFunction<_AeadN, AeadD>('wfhse_xchacha20poly1305_decrypt'),
      memzero = lib.lookupFunction<_ZeroN, ZeroD>('wfhse_memzero');

  /// Set by host tests to a CMake build of fhse_native's `src/`
  /// (`package:wallet_backup/testing.dart`). Unused in the apps.
  static String? libraryPathOverride;

  static BackupNative? _instance;
  static BackupNative get instance => _instance ??= BackupNative._(switch (libraryPathOverride) {
    final path? => DynamicLibrary.open(path),
    null => openFhseNative(),
  });

  /// `fhse_decryption_failure`: the tag does not match.
  static const decryptionFailure = 5;

  final AeadD encrypt;
  final AeadD decrypt;
  final ZeroD memzero;
}
