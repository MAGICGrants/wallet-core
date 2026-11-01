/// Store screenshots: a Monero wallet that shows a fixed sample balance and
/// history.
///
/// A separate entry point, like `package:wallet_monero/testing.dart`: the
/// figures are invented, so application code must never import it. An app's
/// screenshot test installs [SampleMoneroWallet] in place of [MoneroWallet].
///
/// ```dart
/// import 'package:wallet_monero/screenshots.dart';
/// ```
library;

import 'src/monero_wallet.dart';

export 'src/screenshots/sample_monero_wallet.dart';
