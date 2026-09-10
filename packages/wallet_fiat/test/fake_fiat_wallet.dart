import 'package:wallet_domain/wallet_domain.dart';

/// A wallet that exists only to be asked its symbol, its fiat base and whether
/// it is configured; the three things [FiatRateModel] reads off one.
class FakeFiatWallet extends CryptoWallet {
  FakeFiatWallet(this.symbol, {this.address = 'server.example.com:1234', String? fiatBase})
    : _fiatBase = fiatBase;

  final String symbol;

  /// Empty means "the user never configured this coin", which is what stops it
  /// being priced.
  final String address;

  final String? _fiatBase;

  @override
  String get fiatBaseSymbol => _fiatBase ?? symbol;

  Future<void> applyConnection() => loadPersistedConnection().then(
    (_) => setConnection(address: address, proxyPort: '', useTor: false),
  );

  // ----- Inert remainder -----

  @override
  String get coinSymbol => symbol;
  @override
  String get blockchainName => symbol;
  @override
  String get iconAsset => '';
  @override
  int get decimals => 8;
  @override
  int get smallerDigits => 4;
  @override
  int get requiredConfirmations => 1;
  @override
  String get connectionTypeName => 'fake';
  @override
  String get connectionAddressExample => 'example';

  @override
  Future<bool> hasExistingWallet() async => true;
  @override
  Future<void> openExisting({required String password}) async {}
  @override
  Future<bool> store() async => true;
  @override
  Future<void> deleteFiles() async {}
  @override
  Future<bool> getIsConnected() async => false;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> loadIsSynced() async {}
  @override
  Future<void> loadSyncedHeight() async {}
  @override
  Future<void> loadTotalBalance() async {}
  @override
  Future<void> loadUnlockedBalance() async {}
  @override
  Future<int> getCurrentHeight() async => 0;
  @override
  Future<int> getRestoreHeight() async => 0;
  @override
  List<TxDetails> readTxHistory() => const [];
  @override
  String getPrimaryAddress() => 'fake-address';
  @override
  bool isAddressValid(String address) => true;

  @override
  Future<void> connectToDaemonImpl({
    required String address,
    String? proxyPort,
    String? password,
  }) async {}

  @override
  Future<void> testConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
    String connectionType = '',
  }) async {}

  @override
  Future<void> restoreFromSeed({
    required SeedSource seed,
    required RestorePoint from,
    required String password,
  }) async {}

  @override
  Future<PendingTransaction> createTx(
    String destinationAddress,
    BigInt amountBaseUnits,
    bool isSweepAll, {
    int priority = 0,
  }) async => throw UnimplementedError();

  @override
  Future<void> commitTx(PendingTransaction tx, String destinationAddress) async =>
      throw UnimplementedError();
}
