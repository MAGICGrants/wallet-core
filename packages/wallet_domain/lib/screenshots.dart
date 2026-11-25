/// Store screenshots: a fixed sample balance and history, the [SampleWallet]
/// mixin that shows them in place of a server's, and the handshake through
/// which an app's screenshot test asks the host for each picture. Makes it
/// easier to take promotional screenshots and recordings.
///
/// A separate entry point, like `package:wallet_monero/testing.dart`: the
/// figures are invented, so application code must never import it.
///
/// ```dart
/// import 'package:wallet_domain/screenshots.dart';
/// ```
library;

export 'src/screenshots/sample_activity.dart';
export 'src/screenshots/sample_wallet.dart';
export 'src/screenshots/store_shots.dart';
