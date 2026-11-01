import 'package:wallet_domain/screenshots.dart';

import '../bitcoin_wallet.dart';
import '../fake_electrum_client.dart';

/// A real Bitcoin wallet showing a [SampleActivity], for store screenshots
/// ([SampleWallet]).
///
/// Its Electrum client is a [FakeElectrumClient] that says it is connected and
/// knows no transactions, so the history the wallet reads is the sample's.
class SampleBitcoinWallet extends BitcoinWallet with SampleWallet {
  SampleBitcoinWallet(this.activity) : super(client: FakeElectrumClient()..connectedValue = true);

  @override
  final SampleActivity activity;
}
