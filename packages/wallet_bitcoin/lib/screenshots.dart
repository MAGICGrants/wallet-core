/// Store screenshots: a Bitcoin wallet that shows a fixed sample balance and
/// history.
///
/// A separate entry point, like `package:wallet_domain/screenshots.dart`: the
/// figures are invented, so application code must never import it. An app's
/// screenshot test installs [SampleBitcoinWallet] in place of [BitcoinWallet].
///
/// ```dart
/// import 'package:wallet_bitcoin/screenshots.dart';
/// ```
library;

import 'src/bitcoin_wallet.dart';

export 'src/screenshots/sample_bitcoin_wallet.dart';
