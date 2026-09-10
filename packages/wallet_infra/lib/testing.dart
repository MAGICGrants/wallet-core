/// Test doubles for `wallet_infra`'s injected boundaries.
///
/// A separate entry point on purpose. These types disable the protections this
/// package provides; `MemorySecretStore` keeps secrets in a plain map,
/// `FastTestPbkdf2` derives keys from a thousand rounds; so an app that imports
/// only `wallet_infra.dart` cannot name them at all.
///
/// Import this from tests, never from application code:
///
/// ```dart
/// import 'package:wallet_infra/testing.dart';
/// ```
library;

export 'src/testing/fast_test_pbkdf2.dart';
export 'src/testing/memory_stores.dart';
