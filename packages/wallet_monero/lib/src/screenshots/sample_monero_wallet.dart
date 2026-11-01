import 'package:wallet_domain/screenshots.dart';

import '../monero_wallet.dart';

/// A real Monero wallet showing a [SampleActivity], for store screenshots
/// ([SampleWallet]). Its receive screen hands out subaddress [subaddressIndex].
class SampleMoneroWallet extends MoneroWallet with SampleWallet {
  SampleMoneroWallet(this.activity, {this.subaddressIndex = 15});

  @override
  final SampleActivity activity;

  final int subaddressIndex;

  @override
  Future<void> loadSubaddressSupport() => setServerSupportsSubaddresses(true);

  @override
  Future<void> loadUnusedSubaddressIndex() =>
      setUnusedSubaddressIndex(subaddressIndex, isSupported: true);
}
