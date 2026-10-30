/// Test support: points wallet_backup at a host build of fhse_native, which
/// carries the libsodium every backup file is sealed with.
library;

import 'dart:io';

import 'src/native.dart';

/// Uses the library named by `WALLET_FHSE_LIBRARY`, else the one
/// `packages/wallet_fhse/tool/build_host_library.dart` builds, found from the
/// test's package directory. Throws, saying how to build it, when neither
/// exists: nearly every backup test seals a file, so none can run without it.
void useHostFhseNative() {
  final fromEnv = Platform.environment['WALLET_FHSE_LIBRARY'];
  final name = Platform.isMacOS
      ? 'libfhse_native.dylib'
      : Platform.isWindows
      ? 'fhse_native.dll'
      : 'libfhse_native.so';
  final path = fromEnv ?? '../wallet_fhse/build/host/$name';
  if (!File(path).existsSync()) {
    throw StateError(
      'fhse_native is not built for the host ($path). Run '
      '`dart run tool/build_host_library.dart` in packages/wallet_fhse, or set '
      'WALLET_FHSE_LIBRARY to a build of it.',
    );
  }
  BackupNative.libraryPathOverride = File(path).absolute.path;
}
