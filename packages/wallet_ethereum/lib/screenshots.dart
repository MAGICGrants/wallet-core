/// Store screenshots: Ethereum and Dai wallets that show a fixed sample
/// balance and history.
///
/// A separate entry point, like `package:wallet_domain/screenshots.dart`: the
/// figures are invented, so application code must never import it. An app's
/// screenshot test installs [SampleEthereumWallet] and [SampleDaiWallet] in
/// place of [EthereumWallet] and [DaiWallet].
///
/// ```dart
/// import 'package:wallet_ethereum/screenshots.dart';
/// ```
library;

import 'src/ethereum_wallet.dart';

export 'src/screenshots/sample_ethereum_wallets.dart';
