import 'package:wallet_domain/wallet_domain.dart';

/// A wallet with no chain, no file and no FFI behind it, scriptable for the
/// scheduling questions `runTxNotifier` has to answer.
///
/// A local fake rather than `wallet_domain`'s: that one lives in
/// `wallet_domain/test/`, which another package's tests cannot import, and this
/// one models things that one does not, whether a scan is *advancing*, and how
/// many times a wallet file was opened. Promoting a shared fake into a
/// `package:wallet_domain/testing.dart` (the shape `wallet_infra` already uses)
/// would remove the duplication; it is a bigger move than this file.
class FakeBackgroundWallet extends CryptoWallet {
  FakeBackgroundWallet(
    this.symbol, {
    this.address = 'server.example.com:1234',
    this.type = '',
    this.tor = false,
    this.testnet = false,
    this.existing = true,
    this.connectThrows,
    this.historyThrows,
  });

  final String symbol;

  /// Persisted connection, as [loadPersistedConnection] would restore it.
  /// Empty [address] is the "never configured" case the scheduler must skip.
  final String address;
  final String type;
  final bool tor;
  final bool testnet;
  final bool existing;

  /// When set, [connectToDaemonImpl] throws it, modelling one unreachable server.
  final Object? connectThrows;

  /// When set, [loadTxHistory] throws it.
  final Object? historyThrows;

  // ----- Recording. Ordering matters more than counts here: a checkpoint that
  // happens after the announcement has already lost the race it exists to win.
  final List<String> calls = [];

  int openCount = 0;
  int connectCount = 0;
  int historyCount = 0;

  /// Height reported by [syncedHeight]. Bump it to model a scan advancing.
  int? height = 100;

  /// Heights [syncedHeight] hands out, one per read, before falling back to
  /// [height], which then stays put. Models "advanced this many times, then
  /// stalled" without any dependence on wall-clock timing.
  List<int>? heightScript;

  /// How many times the wait loop looked at this wallet.
  int heightReads = 0;

  bool connected = true;
  bool synced = true;

  @override
  bool get isConnected => connected;
  @override
  bool get isSynced => synced;

  @override
  int? get syncedHeight {
    heightReads++;
    final script = heightScript;
    if (script != null && script.isNotEmpty) return height = script.removeAt(0);
    return height;
  }

  /// Models Monero's answer, the only shape worth faking here: a `'node'`
  /// connection means a local scan, any other configured connection means a
  /// check against a server that already scanned, and nothing configured means
  /// nothing to do. `'node'` is Monero's own string, so the base class can't
  /// know what it means, which is why the scheduler asks the coin.
  @override
  BackgroundSyncMode get backgroundSyncMode {
    if (connectionAddress.isEmpty) return BackgroundSyncMode.none;
    return connectionType == 'node' ? BackgroundSyncMode.scan : BackgroundSyncMode.check;
  }

  /// Every wallet the run marked unattended, in order. Recorded because it is
  /// what selects the view-only open path, and because it has to happen *before*
  /// the file is opened for that to mean anything.
  bool markedUnattendedBeforeOpen = false;

  @override
  void markUnattended() {
    super.markUnattended();
    if (unattended && openCount == 0) markedUnattendedBeforeOpen = true;
    calls.add('markUnattended');
  }

  @override
  Future<void> loadPersistedConnection() async {
    calls.add('loadPersistedConnection');
    setConnection(address: address, proxyPort: '', useTor: tor, connectionType: type);
  }

  @override
  Future<bool> hasExistingWallet() async => existing;

  @override
  Future<void> openExisting({required String password}) async {
    openCount++;
    calls.add('openExisting');
    setIsLoaded(true);
  }

  @override
  Future<void> connectToDaemonImpl({
    required String address,
    String? proxyPort,
    String? password,
  }) async {
    connectCount++;
    calls.add('connectToDaemon');
    final error = connectThrows;
    if (error != null) throw error;
  }

  @override
  Future<void> loadTxHistory({bool persistCount = true}) async {
    historyCount++;
    calls.add('loadTxHistory');
    final error = historyThrows;
    if (error != null) throw error;
  }

  @override
  Future<bool> store() async {
    calls.add('store');
    return true;
  }

  @override
  Future<void> pauseSync() async => calls.add('pauseSync');

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
  bool get isTestnet => testnet;
  @override
  String get connectionTypeName => 'fake';
  @override
  String get connectionAddressExample => 'example';
  @override
  List<String> get connectionTypeOptions => const ['', 'node'];

  /// Counted so the delete-teardown test can assert the wallets were actually
  /// wiped, not just that the preferences were cleared.
  int deleteFilesCount = 0;

  @override
  Future<void> deleteFiles() async => deleteFilesCount++;
  @override
  Future<bool> getIsConnected() async => connected;
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
  Future<int> getCurrentHeight() async => height ?? 0;
  @override
  Future<int> getRestoreHeight() async => 0;
  @override
  List<TxDetails> readTxHistory() => const [];
  @override
  String getPrimaryAddress() => 'fake-address';
  @override
  bool isAddressValid(String address) => true;

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
