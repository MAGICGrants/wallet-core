import 'dart:async';

import 'monero_backend.dart';

/// A scriptable [MoneroBackend] with no monero_c behind it.
///
/// Exported from the package rather than hidden in `test/` on purpose: the
/// paths worth testing here have caused real bugs in both
/// apps, and the consuming apps should be able to write those tests too.
///
/// Models the two things the real backend actually keys on, which wallet files
/// exist, and what `errorString` a call leaves behind; because that is what
/// the interesting branches read.
class FakeMoneroBackend extends MoneroBackend {
  FakeMoneroBackend();

  // ----- Script -----

  /// Wallet file paths that "exist". `_node`-suffixed entries are the full-node
  /// mode's files; the bare path is LWS.
  final Set<String> existingWalletPaths = {};

  /// Error string a wallet handle reports. Cleared once read by the code under
  /// test, matching monero_c's behaviour closely enough for the retry paths.
  final Map<int, String> errorStrings = {};

  /// Queued failures for the next `recoveryWallet` / `createWalletFromPolyseed`
  /// call, e.g. `'file already exists'`.
  final List<String> queuedRestoreErrors = [];

  /// Bare non-zero status to leave on the next restore *without* an errorString;
  /// monero_c's cold-start artifact: the first restore on a fresh install
  /// reports a non-zero status but no message, yet still writes the file.
  final List<int> queuedRestoreStatuses = [];

  /// Explicit per-wallet statuses set via [queuedRestoreStatuses]; otherwise the
  /// status is derived from the error string.
  final Map<int, int> _walletStatuses = {};

  /// Address returned for a wallet, keyed by the seed it was built from, so a
  /// restore of the same seed reproduces the same address.
  final Map<String, String> addressesBySeed = {};

  String defaultAddress = '4-e';

  /// Stand-in private view key. A real one is 64 hex chars; this is deliberately
  /// not hex so that a test asserting it never reaches a log is unambiguous.
  String secretViewKeyValue = 'fake-view-key';
  String secretSpendKeyValue = 'fake-spend-key';
  String publicViewKeyValue = 'fake-pub-view-key';
  String publicSpendKeyValue = 'fake-pub-spend-key';

  /// Every `addressIndex` [address] was called with, in order. The subaddress
  /// tests assert on this because which index the wallet asks for is the whole
  /// question; an unprovisioned one means a payment nothing reports.
  final List<int> addressIndexRequests = [];

  /// `networkType` values passed to each wallet factory, in order. Both apps ship
  /// mainnet only, so anything other than 0 from the wallet layer is a bug.
  final List<int> networkTypesRequested = [];

  BigInt balanceValue = BigInt.zero;
  BigInt unlockedBalanceValue = BigInt.zero;
  bool synchronizedValue = false;
  int connectedValue = 1;
  int chainHeight = 3000000;
  int walletHeight = 3000000;
  int refreshFromBlockHeight = 0;
  BigInt? feeEstimate = BigInt.from(30000000);
  List<NativeTxInfo> transactions = [];

  // ----- Recording -----

  final List<String> calls = [];

  /// The password matters as much as the mnemonic here. The two mode files are
  /// each encrypted with their own, so recovering one with a freshly minted
  /// password desyncs them permanently; see `_rebuildForConnectionType`.
  final List<({String mnemonic, int restoreHeight, String path, bool newWallet, String password})>
  polyseedRestores = [];
  final List<({String mnemonic, int restoreHeight, String path, String password})> legacyRestores =
      [];
  final List<({String path, String password})> opens = [];
  final List<int> setRefreshHeights = [];
  final List<MoneroManagerKind> managersRequested = [];

  /// The daemon address and derived SSL flag of each [init], so a test can assert
  /// the scheme the wallet derived for a host rather than infer it.
  final List<({String daemonAddress, bool useSsl})> initCalls = [];

  int _nextId = 1;
  int _newId() => _nextId++;

  /// Seed a handle was created from, so [address] can be stable per seed.
  final Map<int, String> _seedForWallet = {};

  /// Test hooks for the connection-change rebuild: when [pauseNextClose] is set,
  /// [closeWallet] blocks on it, and completes [closeStarted] as it enters; so
  /// a test can pin the rebuild at the exact moment the native handle is freed.
  Completer<void>? pauseNextClose;
  Completer<void>? closeStarted;

  /// The same pair for [walletStats], the native call the connection tick sits
  /// in while a wallet syncs: lets a test pin a tick *inside* its native
  /// section and check that a close waits for it to come out.
  Completer<void>? pauseNextWalletStats;
  Completer<void>? walletStatsStarted;

  void _record(String name) => calls.add(name);

  bool called(String name) => calls.contains(name);
  int countOf(String name) => calls.where((c) => c == name).length;

  void reset() {
    existingWalletPaths.clear();
    errorStrings.clear();
    queuedRestoreErrors.clear();
    queuedRestoreStatuses.clear();
    _walletStatuses.clear();
    calls.clear();
    polyseedRestores.clear();
    legacyRestores.clear();
    opens.clear();
    setRefreshHeights.clear();
    managersRequested.clear();
    initCalls.clear();
    createTransactionRequests.clear();
    txKeyRequests.clear();
    transactions = [];
    pauseNextClose = null;
    closeStarted = null;
    pauseNextWalletStats = null;
    walletStatsStarted = null;
    backgroundSyncTypes.clear();
    backgroundSyncSetups.clear();
    backgroundWalletPaths.clear();
    _backgroundWallets.clear();
    _pathForWallet.clear();
  }

  // ----- Manager -----

  @override
  Future<NativeHandle> getWalletManager(MoneroManagerKind kind) async {
    _record('getWalletManager');
    managersRequested.add(kind);
    return NativeHandle(_newId());
  }

  @override
  Future<bool> walletExists(NativeHandle manager, String path) async {
    _record('walletExists');
    return existingWalletPaths.contains(path);
  }

  @override
  Future<String> managerErrorString(NativeHandle manager) async => '';

  @override
  Future<int> blockchainHeight(NativeHandle manager) async => chainHeight;

  @override
  Future<NativeHandle> openWallet(
    NativeHandle manager, {
    required String path,
    required String password,
  }) async {
    _record('openWallet');
    opens.add((path: path, password: password));
    final handle = NativeHandle(_newId());
    _pathForWallet[handle.id] = path;
    if (!existingWalletPaths.contains(path)) {
      errorStrings[handle.id] = 'failed to open wallet: no such file';
    }
    if (backgroundWalletPaths.contains(path)) {
      // wallet2 recognises a background keys file by which key decrypts it, and
      // the wallet it produces has no spend key at all. The fake models both
      // halves: the flag, and a spend key that reads as the null key.
      _backgroundWallets.add(handle.id);
    }
    return handle;
  }

  /// Path each wallet handle was opened or restored at, so
  /// [setupBackgroundSync] knows where to put the background files.
  final Map<int, String> _pathForWallet = {};

  @override
  Future<NativeHandle> recoveryWallet(
    NativeHandle manager, {
    required String mnemonic,
    required String seedOffset,
    required int restoreHeight,
    required String password,
    required String path,
    int networkType = 0,
  }) async {
    _record('recoveryWallet');
    networkTypesRequested.add(networkType);
    legacyRestores.add((
      mnemonic: mnemonic,
      restoreHeight: restoreHeight,
      path: path,
      password: password,
    ));
    return _finishRestore(mnemonic, path);
  }

  @override
  Future<NativeHandle> createWalletFromPolyseed(
    NativeHandle manager, {
    required String mnemonic,
    required String seedOffset,
    required int restoreHeight,
    required String path,
    required String password,
    required bool newWallet,
    required int kdfRounds,
    int networkType = 0,
  }) async {
    _record('createWalletFromPolyseed');
    networkTypesRequested.add(networkType);
    polyseedRestores.add((
      mnemonic: mnemonic,
      restoreHeight: restoreHeight,
      path: path,
      newWallet: newWallet,
      password: password,
    ));
    return _finishRestore(mnemonic, path);
  }

  NativeHandle _finishRestore(String mnemonic, String path) {
    final handle = NativeHandle(_newId());
    _seedForWallet[handle.id] = mnemonic;
    _pathForWallet[handle.id] = path;

    if (queuedRestoreErrors.isNotEmpty) {
      errorStrings[handle.id] = queuedRestoreErrors.removeAt(0);
      return handle;
    }

    if (queuedRestoreStatuses.isNotEmpty) {
      // Cold-start transient: status set, message empty, file still written.
      _walletStatuses[handle.id] = queuedRestoreStatuses.removeAt(0);
    }

    existingWalletPaths.add(path);
    return handle;
  }

  @override
  Future<bool> closeWallet(NativeHandle manager, NativeHandle wallet, {required bool store}) async {
    _record('closeWallet');
    if (closeStarted != null && !closeStarted!.isCompleted) closeStarted!.complete();
    final gate = pauseNextClose;
    if (gate != null) {
      pauseNextClose = null;
      await gate.future;
    }
    return true;
  }

  // ----- Wallet -----

  @override
  Future<String> walletErrorString(NativeHandle wallet) async => errorStrings[wallet.id] ?? '';

  @override
  Future<int> walletStatus(NativeHandle wallet) async =>
      _walletStatuses[wallet.id] ?? ((errorStrings[wallet.id] ?? '').isEmpty ? 0 : 1);

  @override
  Future<void> init(
    NativeHandle wallet, {
    required String daemonAddress,
    required String proxyAddress,
    required bool useSsl,
    required bool lightWallet,
  }) async {
    initCalls.add((daemonAddress: daemonAddress, useSsl: useSsl));
    _record('init');
  }

  @override
  Future<void> connectToDaemon(NativeHandle wallet) async => _record('connectToDaemon');

  @override
  Future<int> connected(NativeHandle wallet) async => connectedValue;

  @override
  Future<bool> synchronized(NativeHandle wallet) async => synchronizedValue;

  @override
  Future<int> blockChainHeight(NativeHandle wallet) async => walletHeight;

  @override
  Future<int> daemonBlockChainHeight(NativeHandle wallet) async {
    _record('daemonBlockChainHeight');
    return chainHeight;
  }

  @override
  Future<NativeWalletStats> walletStats(NativeHandle wallet, {int accountIndex = 0}) async {
    _record('walletStats');
    if (walletStatsStarted != null && !walletStatsStarted!.isCompleted) {
      walletStatsStarted!.complete();
    }
    final gate = pauseNextWalletStats;
    if (gate != null) {
      pauseNextWalletStats = null;
      await gate.future;
    }
    return NativeWalletStats(
      synchronized: synchronizedValue,
      blockChainHeight: walletHeight,
      balance: balanceValue,
      unlockedBalance: unlockedBalanceValue,
    );
  }

  // ----- Background sync -----

  /// What [getBackgroundSyncType] reports, **per wallet path**. Absent ⇒ `off`,
  /// which is what a wallet that has never been set up returns.
  ///
  /// Keyed on the path rather than the handle because that is where wallet2
  /// keeps it: the type lives in the keys file, so it survives a close and a
  /// re-open, which is the whole reason the setup call can be made once instead
  /// of on every open.
  final Map<String, MoneroBackgroundSyncType> backgroundSyncTypes = {};

  /// Every [setupBackgroundSync] call, in order.
  ///
  /// The passwords are recorded because they are the property that matters: the
  /// call throws if the two are equal, and the background cache password is the
  /// one secret an unattended run is allowed to hold.
  final List<({MoneroBackgroundSyncType type, String walletPassword, String cachePassword})>
  backgroundSyncSetups = [];

  /// Wallet handles that came out of a `.background` file, i.e. what
  /// [isBackgroundWallet] answers true for. Populated by [openWallet] from
  /// [backgroundWalletPaths].
  final Set<int> _backgroundWallets = {};

  /// Paths that [openWallet] should treat as background (view-only) wallets.
  /// Written by [setupBackgroundSync] and readable by a test directly.
  final Set<String> backgroundWalletPaths = {};

  @override
  Future<bool> setupBackgroundSync(
    NativeHandle wallet, {
    required MoneroBackgroundSyncType type,
    required String walletPassword,
    required String backgroundCachePassword,
  }) async {
    _record('setupBackgroundSync');
    backgroundSyncSetups.add((
      type: type,
      walletPassword: walletPassword,
      cachePassword: backgroundCachePassword,
    ));

    // wallet2 throws on this rather than returning false, so the fake refuses
    // it too; a caller that reuses the wallet password has built nothing.
    if (type == MoneroBackgroundSyncType.customPassword &&
        walletPassword == backgroundCachePassword) {
      errorStrings[wallet.id] = 'background sync password is the wallet password';
      return false;
    }

    // The paths the real call writes and deletes, so a later open of the
    // background wallet finds a file where wallet2 would have put one.
    final path = _pathForWallet[wallet.id];
    if (path != null) {
      backgroundSyncTypes[path] = type;
      final backgroundPath = '$path.background';
      if (type == MoneroBackgroundSyncType.customPassword) {
        existingWalletPaths.add(backgroundPath);
        backgroundWalletPaths.add(backgroundPath);
      } else {
        existingWalletPaths.remove(backgroundPath);
        backgroundWalletPaths.remove(backgroundPath);
      }
    }
    return true;
  }

  @override
  Future<MoneroBackgroundSyncType> getBackgroundSyncType(NativeHandle wallet) async {
    _record('getBackgroundSyncType');
    final path = _pathForWallet[wallet.id];
    if (path == null) return MoneroBackgroundSyncType.off;
    return backgroundSyncTypes[path] ?? MoneroBackgroundSyncType.off;
  }

  @override
  Future<bool> isBackgroundWallet(NativeHandle wallet) async =>
      _backgroundWallets.contains(wallet.id);

  @override
  Future<void> refresh(NativeHandle wallet) async => _record('refresh');

  @override
  Future<void> startRefresh(NativeHandle wallet) async => _record('startRefresh');

  @override
  Future<void> pauseRefresh(NativeHandle wallet) async => _record('pauseRefresh');

  @override
  Future<void> setAutoRefreshInterval(NativeHandle wallet, int millis) async =>
      _record('setAutoRefreshInterval');

  @override
  Future<bool> store(NativeHandle wallet) async {
    _record('store');
    return true;
  }

  @override
  Future<BigInt> balance(NativeHandle wallet, {int accountIndex = 0}) async => balanceValue;

  @override
  Future<BigInt> unlockedBalance(NativeHandle wallet, {int accountIndex = 0}) async =>
      unlockedBalanceValue;

  @override
  Future<String> address(NativeHandle wallet, {int accountIndex = 0, int addressIndex = 0}) async {
    addressIndexRequests.add(addressIndex);
    final seed = _seedForWallet[wallet.id];
    if (seed != null && addressesBySeed.containsKey(seed)) return addressesBySeed[seed]!;
    if (seed != null) {
      // Stable per seed, so "restoring the same seed gives the same address"
      // is a property the fake actually exhibits.
      return addressesBySeed.putIfAbsent(seed, () => '4${seed.hashCode.abs()}'.padRight(95, 'B'));
    }
    return defaultAddress;
  }

  @override
  Future<String> seed(NativeHandle wallet, {String seedOffset = ''}) async =>
      _seedForWallet[wallet.id] ?? '';

  /// Recorded, unlike its siblings: a caller that refuses to transmit the view
  /// key must not read it out of the wallet either, and `countOf` is how a test
  /// pins that ordering.
  @override
  Future<String> secretViewKey(NativeHandle wallet) async {
    _record('secretViewKey');
    return secretViewKeyValue;
  }

  /// The all-zero spend key a background wallet reports.
  ///
  /// Not a fake convenience: a background keys file is written with
  /// `forget_spend_key()` applied, so there is no encrypted spend key in it to
  /// decrypt and `Wallet_secretSpendKey` returns the null key. That is the usual
  /// way to detect a view-only wallet (`int.tryParse(secretSpendKey()) == 0`),
  /// and it proves a background run holds no spendable key rather than merely
  /// having been handed a different password.
  static const nullSpendKey = '0000000000000000000000000000000000000000000000000000000000000000';

  @override
  Future<String> secretSpendKey(NativeHandle wallet) async {
    _record('secretSpendKey');
    return _backgroundWallets.contains(wallet.id) ? nullSpendKey : secretSpendKeyValue;
  }

  @override
  Future<String> publicViewKey(NativeHandle wallet) async => publicViewKeyValue;

  @override
  Future<String> publicSpendKey(NativeHandle wallet) async => publicSpendKeyValue;

  @override
  Future<String> getPolyseed(NativeHandle wallet, {String passphrase = ''}) async {
    final seed = _seedForWallet[wallet.id] ?? '';
    // A wallet built from a 16-word seed reports a polyseed; anything else
    // reports none, which is what the rebuild path keys on.
    return seed.split(' ').length == 16 ? seed : '';
  }

  @override
  Future<int> getRefreshFromBlockHeight(NativeHandle wallet) async => refreshFromBlockHeight;

  @override
  Future<void> setRefreshFromBlockHeight(NativeHandle wallet, int height) async {
    _record('setRefreshFromBlockHeight');
    setRefreshHeights.add(height);
    refreshFromBlockHeight = height;
  }

  @override
  Future<void> setCaFilePath(NativeHandle wallet, String path) async => _record('setCaFilePath');

  @override
  Future<BigInt?> estimateTransactionFee(
    NativeHandle wallet, {
    required List<String> destinations,
    required List<BigInt> amounts,
    int priority = 0,
  }) async {
    _record('estimateTransactionFee');
    return feeEstimate;
  }

  // ----- Transactions -----

  @override
  Future<NativeHandle> history(NativeHandle wallet) async => NativeHandle(_newId());

  @override
  Future<void> historyRefresh(NativeHandle history) async => _record('historyRefresh');

  @override
  Future<List<NativeTxInfo>> historyTransactions(
    NativeHandle wallet,
    NativeHandle history, {
    Map<String, String> knownTxKeys = const {},
    bool withTxKeys = true,
  }) async {
    _record('historyTransactions');
    if (!withTxKeys) {
      // What a background wallet forces: asking for a key there sets an error on
      // the wallet for every transaction. Recording nothing is the assertion.
      return [for (final tx in transactions) _withKey(tx, '')];
    }
    return [
      for (final tx in transactions)
        if (knownTxKeys.containsKey(tx.hash))
          _withKey(tx, knownTxKeys[tx.hash]!)
        else
          () {
            txKeyRequests.add(tx.hash);
            return tx;
          }(),
    ];
  }

  static NativeTxInfo _withKey(NativeTxInfo tx, String key) => NativeTxInfo(
    direction: tx.direction,
    hash: tx.hash,
    amount: tx.amount,
    fee: tx.fee,
    timestamp: tx.timestamp,
    blockHeight: tx.blockHeight,
    confirmations: tx.confirmations,
    subaddrAccount: tx.subaddrAccount,
    subaddrIndex: tx.subaddrIndex,
    isPending: tx.isPending,
    isFailed: tx.isFailed,
    paymentId: tx.paymentId,
    txKey: key,
  );

  /// Hashes the transaction key was read for. The key comes off the wallet
  /// rather than the history entry, so a caller that forgets to pass the wallet
  /// handle silently loses it.
  final List<String> txKeyRequests = [];

  /// Every `createTransaction` request, in order.
  ///
  /// Recorded rather than merely counted because of [MoneroTxRequest.isSweepAll]:
  /// monero_c decides between "send this amount" and "send everything, minus the
  /// fee it works out" from that flag alone, and the amount it is passed
  /// alongside is meaningless for a sweep. A caller that drops the flag builds a
  /// transaction for whatever the send screen passed instead, zero, and
  /// nothing else in the call looks wrong.
  final List<MoneroTxRequest> createTransactionRequests = [];

  @override
  Future<NativeHandle> createTransaction(
    NativeHandle wallet, {
    required List<String> destinations,
    required List<BigInt> amounts,
    required bool isSweepAll,
    required int mixinCount,
    int priority = 0,
    int subaddrAccount = 0,
  }) async {
    _record('createTransaction');
    createTransactionRequests.add(
      MoneroTxRequest(
        destinations: List.unmodifiable(destinations),
        amounts: List.unmodifiable(amounts),
        isSweepAll: isSweepAll,
        mixinCount: mixinCount,
        priority: priority,
        subaddrAccount: subaddrAccount,
      ),
    );
    return NativeHandle(_newId());
  }

  BigInt pendingAmount = BigInt.zero;
  BigInt pendingFee = BigInt.zero;
  int pendingStatus = 0;
  String pendingError = '';
  bool commitResult = true;

  @override
  Future<BigInt> pendingTxAmount(NativeHandle tx) async => pendingAmount;

  @override
  Future<BigInt> pendingTxFee(NativeHandle tx) async => pendingFee;

  @override
  Future<int> pendingTxStatus(NativeHandle tx) async => pendingStatus;

  @override
  Future<String> pendingTxErrorString(NativeHandle tx) async => pendingError;

  @override
  Future<bool> commitPendingTx(NativeHandle tx) async {
    _record('commitPendingTx');
    return commitResult;
  }
}

/// One recorded `createTransaction` call, as monero_c would have received it.
class MoneroTxRequest {
  const MoneroTxRequest({
    required this.destinations,
    required this.amounts,
    required this.isSweepAll,
    required this.mixinCount,
    required this.priority,
    required this.subaddrAccount,
  });

  final List<String> destinations;

  /// Piconero, per destination. Ignored by monero_c when [isSweepAll] is set.
  final List<BigInt> amounts;

  /// Send everything, less the fee monero_c computes for the transaction it
  /// builds. A sweep therefore has exactly one destination and no change.
  final bool isSweepAll;

  final int mixinCount;
  final int priority;
  final int subaddrAccount;

  /// Redacted; this type names a destination and an amount.
  @override
  String toString() =>
      'MoneroTxRequest(${destinations.length} dest, sweep=$isSweepAll, '
      'mixin=$mixinCount, prio=$priority, account=$subaddrAccount)';
}
