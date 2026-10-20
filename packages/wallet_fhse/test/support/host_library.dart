import 'dart:io';

import 'package:wallet_fhse/wallet_fhse.dart';

/// The host build of `src/`, or null when there is none; see test/README.md.
String? findHostLibrary() {
  final fromEnv = Platform.environment['WALLET_FHSE_LIBRARY'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  final name = Platform.isMacOS ? 'libwallet_fhse.dylib' : 'libwallet_fhse.so';
  final built = File('build/host/$name');
  return built.existsSync() ? built.absolute.path : null;
}

/// Points [FhseNative] at the host build. Returns a skip reason when there is
/// none, for `test(..., skip: ...)`.
String? useHostLibrary() {
  final path = findHostLibrary();
  if (path == null) return 'no host build of wallet_fhse; see test/README.md';
  FhseNative.libraryPathOverride = path;
  return null;
}
