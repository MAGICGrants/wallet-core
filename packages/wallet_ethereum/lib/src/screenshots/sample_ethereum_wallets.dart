import 'package:wallet_domain/screenshots.dart';

import '../ethereum_wallet.dart';

/// A real Ethereum wallet showing a [SampleActivity], for store screenshots
/// ([SampleWallet]).
class SampleEthereumWallet extends EthereumWallet with SampleWallet, _SampleExplorer {
  SampleEthereumWallet(this.activity);

  @override
  final SampleActivity activity;
}

/// A real Dai wallet showing a [SampleActivity], for store screenshots
/// ([SampleWallet]). Its fee, like a real Dai send's, is in ether.
class SampleDaiWallet extends DaiWallet with SampleWallet, _SampleExplorer {
  SampleDaiWallet(this.activity);

  @override
  final SampleActivity activity;
}

/// The explorer's connection test, which Ethereum's setup form runs beside the
/// node's, succeeds without a request too.
mixin _SampleExplorer on SampleWallet {
  @override
  Future<void> testExplorerConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
  }) => Future<void>.delayed(const Duration(milliseconds: 400));
}
