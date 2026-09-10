import 'dart:async';

import 'package:wallet_domain/wallet_domain.dart';

/// A wallet with no chain behind it, so the manager's orchestration can be
/// tested without FFI. Records what it was asked to do.
class FakeWallet extends CryptoWallet {
  FakeWallet(
    this.symbol, {
    Set<SeedFormat>? seedFormats,
    this.testnet = false,
    this.existing = false,
  }) : _seedFormats = seedFormats ?? const {SeedFormat.bip39};

  final String symbol;
  final Set<SeedFormat> _seedFormats;
  final bool testnet;
  bool existing;

  final restores = <SeedSource>[];
  int openCount = 0;
  int deleteFileCount = 0;
  bool pauseStored = false;
  int pauseCount = 0;
  int storeCount = 0;

  /// Every call to [connectToDaemonImpl], with the arguments it received. The
  /// proxy port matters: a Tor connection must arrive here with Tor's port, and
  /// a connection that should have failed closed must not arrive here at all.
  final connectCalls = <({String address, String? proxyPort})>[];

  /// What [getIsConnected] reports, i.e. whether the server answered, which is
  /// a separate question from whether [connectToDaemonImpl] threw.
  bool connected = false;

  /// When set, [connectToDaemonImpl] waits on it, so two concurrent connects
  /// genuinely overlap and the in-flight dedup is observable.
  Completer<void>? connectGate;

  /// When set, [connectToDaemonImpl] throws it.
  Object? connectError;

  /// What [readTxHistory] returns. Scriptable so the notification path can be
  /// driven without a chain.
  List<TxDetails> history = const [];

  /// When set, [openExisting] throws it once.
  Object? openError;

  /// Lifecycle calls in the order they happened. Ordering is the point for
  /// `load()`: connect must precede refresh, and stats must come after both.
  final lifecycle = <String>[];

  int get refreshCount => lifecycle.where((c) => c == 'refresh').length;
  int get statsCount => lifecycle.where((c) => c == 'loadAllStats').length;

  /// When set, [refresh] throws it; a node that drops mid-cycle.
  Object? refreshError;

  /// When true, `deferStatsUntilSynced` reports true, as Monero's node mode does.
  bool deferStats = false;

  @override
  bool get deferStatsUntilSynced => deferStats;

  /// `setIsSynced` and friends are `@protected`.
  void setSyncedForTesting(bool value) => setIsSynced(value);
  void setSyncedHeightForTesting(int? value) => setSyncedHeight(value);
  void setConnectedForTesting(bool value) => setIsConnected(value);
  void setBalancesForTesting({BigInt? total, BigInt? unlocked}) {
    setTotalBalanceBaseUnits(total);
    setUnlockedBalanceBaseUnits(unlocked);
  }

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
  Set<SeedFormat> get supportedSeedFormats => _seedFormats;
  @override
  String get connectionTypeName => 'fake';
  @override
  String get connectionAddressExample => 'example';

  /// `setIsLoaded` is `@protected`; a subclass may call it and a test may not.
  void setIsLoadedForTesting(bool value) => setIsLoaded(value);

  /// Whether a `persistCache()` would write. The interesting assertion for the
  /// cache gate: a clean cache means neither the encrypt nor the encode ran, and
  /// comparing two decrypted blobs cannot tell those apart.
  bool get cacheDirtyForTesting => cacheDirty;

  /// Whether a `store()` would write. Same reasoning.
  bool get storeDirtyForTesting => storeDirty;

  /// `runWithSyncSuspended` is `@protected`. Exposed because its re-entrancy is
  /// the property worth pinning: a nested call that un-suspends the outer one
  /// resumes the timers against a half-rebuilt wallet, which is a SIGSEGV in
  /// native code rather than a Dart exception.
  Future<T> runWithSyncSuspendedForTesting<T>(Future<T> Function() action) =>
      runWithSyncSuspended(action);

  /// Same for `ensureConnectionLoaded`.
  Future<void> ensureConnectionLoadedForTesting() => ensureConnectionLoaded();

  int pollSyncCount = 0;
  int getIsConnectedCount = 0;

  @override
  Future<void> pollSyncStatus() async {
    pollSyncCount++;
    // Monero's override reads sync state on the fast cadence, and the deferred
    // refresh path depends on it: that path returns before `loadAllStats`, so
    // the poll is the only thing that ever moves the height during a scan.
    await loadSyncedHeight();
  }

  @override
  Future<bool> hasExistingWallet() async => existing;

  @override
  Future<void> openExisting({required String password}) async {
    final err = openError;
    if (err != null) {
      openError = null;
      throw err;
    }
    openCount++;
    setIsLoaded(true);
  }

  @override
  Future<void> restoreFromSeed({
    required SeedSource seed,
    required RestorePoint from,
    required String password,
  }) async {
    restores.add(seed);
    existing = true;
    setIsLoaded(true);
  }

  @override
  Future<bool> store() async {
    lifecycle.add('store');
    storeCount++;
    return true;
  }

  @override
  Future<void> deleteFiles() async {
    deleteFileCount++;
    existing = false;
  }

  @override
  Future<void> pauseSync() async {
    pauseStored = true;
    pauseCount++;
  }

  @override
  Future<void> connectToDaemonImpl({required String address, String? proxyPort}) async {
    lifecycle.add('connect');
    connectCalls.add((address: address, proxyPort: proxyPort));
    final gate = connectGate;
    if (gate != null) await gate.future;
    final err = connectError;
    if (err != null) throw err;
  }

  @override
  Future<void> testConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
    String connectionType = '',
  }) async {}
  @override
  Future<bool> getIsConnected() async {
    getIsConnectedCount++;
    return connected;
  }

  @override
  Future<void> refresh() async {
    lifecycle.add('refresh');
    final err = refreshError;
    if (err != null) throw err;
  }

  @override
  Future<void> loadAllStats() async {
    lifecycle.add('loadAllStats');
    await super.loadAllStats();
  }

  /// Height [loadSyncedHeight] reports.
  ///
  /// It advances by default, because that is what a working wallet does and
  /// because the movement is the signal the store gate reads: a fake whose stat
  /// loaders are pure no-ops models a wallet where nothing ever changes, and
  /// asserting "a full cycle stores" against one of those proves the store is
  /// unconditional rather than that the cycle did any work. Set
  /// [chainAdvances] false for the frozen case, which is its own test.
  int chainHeight = 1000;
  bool chainAdvances = true;

  @override
  Future<void> loadIsSynced() async {}
  @override
  Future<void> loadSyncedHeight() async {
    if (chainAdvances) chainHeight++;
    setSyncedHeight(chainHeight);
  }

  @override
  Future<void> loadUnlockedBalance() async {}
  @override
  Future<void> loadTotalBalance() async {}
  @override
  Future<int> getCurrentHeight() async => 0;
  @override
  Future<int> getRestoreHeight() async => 0;
  @override
  List<TxDetails> readTxHistory() {
    readHistoryCount++;
    return history;
  }

  int readHistoryCount = 0;

  int txHistoryGrewCount = 0;

  @override
  Future<void> onTxHistoryGrew() async => txHistoryGrewCount++;
  @override
  String getPrimaryAddress() => 'addr_\$symbol';
  @override
  bool isAddressValid(String address) => true;
  @override
  Future<PendingTransaction> createTx(
    String destinationAddress,
    BigInt amountBaseUnits,
    bool isSweepAll, {
    int priority = 0,
  }) async => throw UnimplementedError();
  @override
  Future<void> commitTx(PendingTransaction tx, String destinationAddress) async {}
}

/// A coin that rides on another coin's connection; the shape an ERC-20 token
/// has, where the token has no RPC of its own and reads the parent chain's.
///
/// It shares the parent's *connection*, and nothing else: its transactions, its
/// notification marker and its restore height are its own. That split is the
/// whole reason [CryptoWallet.connectionPrefSymbol] is separate from
/// `coinSymbol`; `app_config_test.dart` pins it.
class FakeTokenWallet extends FakeWallet {
  FakeTokenWallet(super.symbol, this.parentSymbol);

  final String parentSymbol;

  @override
  String get connectionPrefSymbol => parentSymbol;
}

/// A coin that publishes an OpenAlias network, so alias resolution is reachable.
///
/// [network], [asset] and [nativeAsset] are separate because OA2 separates them
///; a token on a chain resolves as network `eth`, asset `dai`. Collapsing them
/// is the v1 assumption `alias.dart` exists to avoid.
class FakeAliasWallet extends FakeWallet {
  FakeAliasWallet(super.symbol, {required this.network, String? asset, String? native})
    : _asset = asset ?? network,
      _native = native ?? network;

  final String network;
  final String _asset;
  final String _native;

  /// Addresses [isAddressValid] accepts. Empty ⇒ accept everything.
  Set<String>? validAddresses;

  @override
  String get aliasNetwork => network;
  @override
  String get aliasAsset => _asset;
  @override
  String? get aliasNativeAsset => _native;

  @override
  bool isAddressValid(String address) =>
      validAddresses == null || validAddresses!.contains(address);
}

/// A coin whose node cannot serve transaction history, so it needs a second
/// endpoint; the shape Ethereum has.
class FakeExplorerWallet extends FakeWallet {
  FakeExplorerWallet(super.symbol);

  @override
  bool get supportsExplorerUrl => true;

  @override
  String get explorerAddressExample => 'https://explorer.example.com';

  final probed = <String>[];

  @override
  Future<void> testExplorerConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
  }) async => probed.add(address);
}
