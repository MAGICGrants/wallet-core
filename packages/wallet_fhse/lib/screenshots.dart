/// Store screenshots: Advanced Security showing security keys that do not
/// exist.
///
/// A separate entry point, like `package:wallet_domain/screenshots.dart`: what
/// it shows is invented, so application code must never import it. An app's
/// screenshot test sets [sampleSecurityKeysState] before the screen opens.
///
/// ```dart
/// import 'package:wallet_fhse/screenshots.dart';
/// ```
library;

export 'src/fhse_vault.dart' show SecurityKeyRecord;
export 'src/ui/security_keys_app.dart' show SecurityKeysState, sampleSecurityKeysState;
