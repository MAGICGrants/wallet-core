/// Checks for `wallet_monero` against the real native library.
///
/// A separate entry point, like `package:wallet_infra/testing.dart`: these
/// stand up servers with published private keys and rewire global state, so
/// application code must never import them.
///
/// ```dart
/// import 'package:wallet_monero/testing.dart';
/// ```
library;

export 'src/testing/native_tls_checks.dart';
