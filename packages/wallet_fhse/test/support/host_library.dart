import 'dart:io';

import 'package:wallet_fhse/wallet_fhse.dart';

/// The host build of fhse_native, or null when there is none; see test/README.md.
String? findHostLibrary() {
  final fromEnv = Platform.environment['WALLET_FHSE_LIBRARY'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;
  final name = Platform.isMacOS ? 'libfhse_native.dylib' : 'libfhse_native.so';
  final built = File('build/host/$name');
  return built.existsSync() ? built.absolute.path : null;
}

/// Points [FhseNative] at the host build. Returns a skip reason when there is
/// none, for `test(..., skip: ...)`; with `REQUIRE_FHSE_LIBRARY=1` (CI) a
/// missing build fails instead, so a broken build step cannot pass by skipping.
String? useHostLibrary() {
  final path = findHostLibrary();
  if (path == null) {
    if (Platform.environment['REQUIRE_FHSE_LIBRARY'] == '1') {
      throw StateError('REQUIRE_FHSE_LIBRARY is set but there is no host build of fhse_native');
    }
    return 'no host build of fhse_native; see test/README.md';
  }
  FhseNative.libraryPathOverride = path;
  return null;
}
