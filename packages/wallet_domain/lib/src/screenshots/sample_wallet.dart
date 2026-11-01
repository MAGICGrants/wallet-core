import '../crypto_wallet.dart';
import '../tx/tx_details.dart';
import 'sample_activity.dart';

/// Turns a coin's real wallet class into one for store screenshots: mixed in,
/// it keeps that class's seed, keys and addresses and shows [activity] where
/// the class would have asked a server.
///
/// Nothing reaches a server. Connecting and the setup form's connection test
/// succeed without a request, and a send stops at the confirmation: [commitTx]
/// refuses.
mixin SampleWallet on CryptoWallet {
  SampleActivity get activity;

  @override
  Future<void> connectToDaemonImpl({required String address, String? proxyPort}) async {}

  @override
  Future<void> testConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
    String connectionType = '',
  }) => Future<void>.delayed(const Duration(milliseconds: 400));

  @override
  Future<bool> getIsConnected() async => true;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> loadIsSynced() async => setIsSynced(true);

  @override
  Future<void> loadSyncedHeight() async => setSyncedHeight(activity.height);

  @override
  Future<void> loadUnlockedBalance() async => setUnlockedBalanceBaseUnits(activity.unlocked);

  @override
  Future<void> loadTotalBalance() async => setTotalBalanceBaseUnits(activity.total);

  @override
  Future<int> getCurrentHeight() async => activity.height;

  @override
  List<TxDetails> readTxHistory() => activity.transactions;

  @override
  Future<BigInt?> estimateFee(
    String destinationAddress,
    BigInt amountBaseUnits, {
    int priority = 0,
  }) async => activity.feeBaseUnits;

  @override
  Future<PendingTransaction> createTx(
    String destinationAddress,
    BigInt amountBaseUnits,
    bool isSweepAll, {
    int priority = 0,
  }) async => SamplePendingTransaction(
    isSweepAll ? activity.unlocked - activity.feeBaseUnits : amountBaseUnits,
    activity.feeBaseUnits,
  );

  @override
  Future<void> commitTx(PendingTransaction tx, String destinationAddress) =>
      throw UnsupportedError('A sample wallet sends nothing.');
}

/// What a [SampleWallet]'s [CryptoWallet.createTx] returns: enough for the
/// confirmation screen, and nothing that could be broadcast.
class SamplePendingTransaction implements PendingTransaction {
  SamplePendingTransaction(this.amountBaseUnits, this.feeBaseUnits);

  @override
  final BigInt amountBaseUnits;

  @override
  final BigInt feeBaseUnits;
}
