import 'dart:async';

import 'package:wallet_backup/testing.dart';

/// The screens here run the backup service, which seals files with
/// fhse_native's libsodium.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  useHostFhseNative();
  await testMain();
}
