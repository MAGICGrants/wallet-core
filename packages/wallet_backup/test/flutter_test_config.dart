import 'dart:async';

import 'package:wallet_backup/testing.dart';

/// Every test here seals or opens files with fhse_native's libsodium.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  useHostFhseNative();
  await testMain();
}
