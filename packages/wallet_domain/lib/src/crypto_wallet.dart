import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'alias.dart';
import 'amounts.dart';
import 'app_config.dart';
import 'background_sync_mode.dart';
import 'seed/seed.dart';
import 'stores/tx_notification_store.dart';
import 'stores/wallet_cache_store.dart';
import 'tx/tx_details.dart';
import 'tx/tx_notifications.dart';

/// Transaction direction, matching monero_c's convention.
const int txDirectionIncoming = 0;
const int txDirectionOutgoing = 1;

/// Called when a wallet first sees an incoming transaction it has not
/// announced. The app supplies this; the core does not depend on a
/// notification plugin.
typedef IncomingTxNotifier = void Function(TxDetails tx, String coinSymbol);

/// Coin-agnostic base for a single-currency wallet.
///
/// Subclasses implement the abstract hooks to talk to a specific chain;
/// everything concrete here is the shared lifecycle: connection state,
/// persistence, the refresh cadence and change notification.
///
/// Subclass this to add a coin. Override the metadata getters, the open/restore
/// path and the send path; the lifecycle below is shared. Non-obvious rules are
/// commented at the member they apply to.
abstract class CryptoWallet with ChangeNotifier {
  CryptoWallet() {
    _startTimers();
  }

  // ----- Injected app services -----

  /// Set by the app. Left null, incoming transactions are simply not announced.
  static IncomingTxNotifier? incomingTxNotifier;

  /// Set by the app when alias resolution is wired up. See `alias.dart`; it
  /// must resolve outside monero_c, over Tor, with OA2 support.
  static AliasResolver? aliasResolver;

  @visibleForTesting
  static void resetInjectablesForTesting() {
    incomingTxNotifier = null;
    aliasResolver = null;
  }

  // ----- Coin metadata (subclass) -----

  String get coinSymbol;

  /// The blockchain this wallet settles on. Identical for a chain's native coin
  /// and its tokens, both Ether and Dai report "Ethereum", so this is the
  /// name to use wherever the network is what matters: addresses, connections,
  /// explorers, address validity.
  String get blockchainName;

  /// The asset the holder owns, for anything that names a holding: asset lists,
  /// activity rows, the send asset picker. Defaults to [blockchainName], which
  /// is right wherever a chain and its native asset share a name (Bitcoin,
  /// Monero); Ether and every token override it.
  String get assetName => blockchainName;

  String get iconAsset;
  int get decimals;
  int get smallerDigits;

  /// Decimals in this coin's smallest indivisible unit (piconero 12, sat 8,
  /// wei 18). Defaults to [decimals]; coins whose display precision differs
  /// from their base unit override it.
  int get baseUnitDecimals => decimals;

  /// Symbol and decimals the network fee is denominated in. ERC-20 tokens
  /// override to the chain's native coin, since gas is paid in ETH.
  String get feeCoinSymbol => coinSymbol;
  int get feeDecimals => decimals;
  String get feeIconAsset => iconAsset;

  /// Base-unit scale of `TxDetails.feeBaseUnits` and
  /// `PendingTransaction.feeBaseUnits`.
  ///
  /// Distinct from [feeDecimals], which is a *display* precision. It exists
  /// because an ERC-20 token's amount and its fee are denominated in different
  /// units, a 6-decimal token paying gas in 18-decimal wei, so one scale
  /// cannot render both. Without this an app has to hardcode 18 for every token,
  /// which is the kind of assumption exact base units exist to remove.
  int get feeBaseUnitDecimals => baseUnitDecimals;

  bool get feeIsForeign => feeCoinSymbol != coinSymbol;

  /// Seed encodings this coin can be derived from.
  ///
  /// Half of a two-sided check: the app's [SeedPolicy] says what it will accept,
  /// this says what the coin can do, and a restore needs both. Monero returns all
  /// three; everything else is BIP39-only.
  Set<SeedFormat> get supportedSeedFormats => const {SeedFormat.bip39};

  /// OA2 network this coin pays on, e.g. `xmr`. Empty ⇒ no alias support.
  String get aliasNetwork => '';

  /// Asset this coin pays in. Usually the same as [aliasNetwork]; a token on a
  /// chain differs (network `eth`, asset `dai`). Also selects the v1 prefix to
  /// look for (`oa1:<asset>`).
  String get aliasAsset => aliasNetwork;

  /// The network's native asset per the OA2 network list; what a v2 record
  /// that omits `asset` denotes.
  String? get aliasNativeAsset => aliasNetwork.isEmpty ? null : aliasNetwork;

  String get connectionTypeName;
  String get connectionAddressExample;

  /// Selectable server kinds (Monero: `['lws', 'node']`). Empty ⇒ no toggle.
  List<String> get connectionTypeOptions => const [];

  String connectionAddressExampleForType(String connectionType) => connectionAddressExample;

  String get connectionType => _connectionType;

  int get requiredConfirmations;

  bool get isTestnet => false;

  /// Blocks left to scan, or null when unknown or not applicable.
  int? get syncBlocksRemaining => null;

  /// Symbol whose fiat rate represents this coin. Testnet coins override to
  /// their mainnet equivalent.
  String get fiatBaseSymbol => coinSymbol;

  bool get canSpendPendingBalance => false;

  bool isTxConfirmed(TxDetails tx) => tx.height != -1 && tx.confirmations >= requiredConfirmations;

  // ----- Unattended runs -----

  /// What an unattended run of *this* wallet, as currently configured, would
  /// be; a local scan or a check against a server that already scanned.
  ///
  /// This is the property a scheduler routes on, and it replaced a
  /// `connectionType != 'node'` string comparison living in a coin-agnostic
  /// file. Every coin answers for itself; the default is [BackgroundSyncMode
  /// .check], because a coin whose wallet is an xpub or an address watch has
  /// nothing else it could be. Monero overrides it, since it is the one coin
  /// that can be either.
  ///
  /// Depends on the *live* connection, so `loadPersistedConnection()` must have
  /// run first; before that a configured wallet reads as [BackgroundSyncMode
  /// .none].
  BackgroundSyncMode get backgroundSyncMode =>
      _connectionAddress.isEmpty ? BackgroundSyncMode.none : BackgroundSyncMode.check;

  bool _unattended = false;

  /// True when this object exists only to advance the chain with nobody
  /// watching: a WorkManager task, an iOS background window, the Android
  /// foreground service.
  ///
  /// Two things read it. A coin with a view-only unattended path opens *that*
  /// instead of its full wallet ([BackgroundSyncMode.scan]; Monero on a node,
  /// which opens its view-key background cache). And nothing in such a run may
  /// overwrite the display snapshot, because a view-only scan's balance is
  /// approximate by construction: an output received during the scan has no
  /// computable key image, so a spend of it is not seen until the main wallet
  /// merges the cache. Writing those numbers to the cache is what the *next*
  /// cold start would show.
  bool get unattended => _unattended;

  /// Marks this wallet as belonging to an unattended run. **Call before
  /// opening**: it selects which file and which password [openExisting] uses,
  /// so setting it afterwards would leave a fully-keyed wallet open and claim
  /// otherwise.
  void markUnattended() {
    if (_isLoaded) {
      walletLog(LogLevel.warn, 'markUnattended() after the wallet was opened; ignoring.');
      return;
    }
    _unattended = true;
  }

  @protected
  void walletLog(LogLevel level, String message, {Map<String, dynamic>? meta}) {
    log(level, message, meta: meta, coin: coinSymbol);
  }

  /// Resolves [alias] to a payable record for this coin, DNSSEC-validated and
  /// routed over Tor.
  ///
  /// Returns null when this coin has no alias support, no resolver is
  /// installed, or the alias publishes nothing this wallet can pay. Throws
  /// [NotAnAliasException] when the input is a raw address, and throws when Tor
  /// is unavailable; a lookup that names who the user is about to pay must
  /// never fall back to an unproxied query.
  Future<ResolvedAlias?> resolveAlias(String alias) async {
    final resolver = aliasResolver;
    if (aliasNetwork.isEmpty || resolver == null) return null;

    // The alias identifies a counterparty: fingerprint, never plaintext.
    walletLog(LogLevel.info, 'alias: resolving ${Redact.id(alias)}');

    final proxy = await TorSettingsService.sharedInstance.getProxy();
    if (proxy == null) {
      walletLog(LogLevel.warn, 'alias: Tor proxy unavailable');
      throw Exception('Tor is required to resolve an alias.');
    }

    final resolved = await resolver(
      alias: alias,
      network: aliasNetwork,
      asset: aliasAsset,
      nativeAsset: aliasNativeAsset,
      socksPort: proxy.port,
    );
    if (resolved == null) {
      walletLog(LogLevel.info, 'alias: no payable record');
      return null;
    }

    // From here down, every value came out of the counterparty's DNS. The
    // resolver proved the answer was DNSSEC-secure; it does not judge the
    // contents, apply a size limit, or know what a valid address looks like.
    // That judgement happens here.
    final payable = _payableOrNull(resolved);
    if (payable == null) {
      walletLog(LogLevel.warn, 'alias: resolved address rejected');
      return null;
    }

    // Every address the user can act on, not only the first. `alternatives`
    // exists so the app can offer the other records the alias published, which
    // puts each of them one tap from the send screen. A bad one is dropped
    // rather than failing the whole resolution; the record the alias actually
    // prioritised is still payable, and the list is capped, because it feeds a
    // picker rather than a batch job.
    final alternatives = <ResolvedAlias>[];
    for (final alt in resolved.alternatives) {
      if (alternatives.length == AliasLimits.maxAlternatives) break;
      final safe = _payableOrNull(alt);
      if (safe != null) alternatives.add(safe);
    }
    final dropped = resolved.alternatives.length - alternatives.length;
    if (dropped > 0) {
      // A count. The things being counted are addresses.
      walletLog(LogLevel.warn, 'alias: dropped $dropped unusable alternative(s)');
    }

    walletLog(LogLevel.info, 'alias: resolved ok');
    return payable.withAlternatives(alternatives);
  }

  /// [record] with its untrusted display fields dropped if they are unfit, or
  /// null when its address is not payable by this coin.
  ///
  /// The bounds check runs *before* [isAddressValid]: that validator is a
  /// subclass's regex over a string of unbounded length from a hostile source,
  /// and it should not be the first thing a 60 KB "address" meets.
  ResolvedAlias? _payableOrNull(ResolvedAlias record) {
    if (!aliasAddressWithinBounds(record.address)) return null;
    if (!isAddressValid(record.address)) return null;
    return ResolvedAlias(
      address: record.address,
      recipientName: safeAliasText(record.recipientName),
      description: safeAliasText(record.description),
      memo: safeAliasText(record.memo),
      requestedAmount: safeAliasText(
        record.requestedAmount,
        maxLength: AliasLimits.maxAmountLength,
      ),
      alternatives: const [],
    );
  }

  // ----- Internal state -----

  // No session-start timestamp: "newer than this session" announced nothing
  // after a restart with a payment still in the mempool. The cutoff in
  // `tx_notifications.dart` replaces it.

  String _connectionAddress = '';
  String _connectionProxyPort = '';
  bool _connectionUseTor = false;
  String _connectionType = '';
  bool _connectionLoaded = false;

  // An optional second server, parallel to the node and configured separately.
  // Ethereum uses it to fetch transaction history, which its RPC cannot serve.
  String _explorerAddress = '';
  String _explorerProxyPort = '';
  bool _explorerUseTor = false;

  bool _hasAttemptedConnection = false;
  bool _isConnected = false;
  bool _torRequirementBroken = false;
  bool _isSynced = false;
  int? _syncedHeight;

  /// Balances are integer base units. The double getters are display-only.
  BigInt? _unlockedBalanceBaseUnits;
  BigInt? _totalBalanceBaseUnits;

  List<TxDetails> _txHistory = [];
  bool _isLoaded = false;

  Timer? _connectionTimer;
  Timer? _refreshTimer;
  bool _disposed = false;
  bool _connectionCheckInFlight = false;
  bool _refreshInFlight = false;
  // Held during a connection-change rebuild that closes and reopens the native
  // wallet: the refresh/connection timers must not touch a handle being freed.
  bool _syncSuspended = false;
  DateTime? _lastSyncCheckpoint;
  DateTime? _lastConnectivityCheck;

  Future<void>? _connectInFlight;
  int _connectFailures = 0;
  DateTime? _lastConnectAttempt;

  Map<String, dynamic> _cache = {};
  String? _cachePassword;
  bool _cacheLoaded = false;
  bool _cacheDirty = false;

  bool _enabledInApp = true;

  bool get enabledInApp => _enabledInApp;

  void setEnabledInApp(bool value) {
    if (_enabledInApp == value) return;
    _enabledInApp = value;
    notifyListeners();
  }

  // ----- Public getters -----

  String get connectionAddress => _connectionAddress;
  String get connectionProxyPort => _connectionProxyPort;
  bool get connectionUseTor => _connectionUseTor;
  bool get usingTor => _connectionUseTor;

  String get explorerAddress => _explorerAddress;
  String get explorerProxyPort => _explorerProxyPort;
  bool get explorerUseTor => _explorerUseTor;

  /// True when this coin has an optional explorer with its own setup screen.
  ///
  /// False for Monero and Bitcoin; an LWS server and an Electrum server both
  /// serve transaction history themselves. Ethereum's RPC cannot, so it needs a
  /// second endpoint and overrides this.
  bool get supportsExplorerUrl => false;

  /// Placeholder shown in the explorer address field.
  String get explorerAddressExample => '';
  bool get torRequirementBroken => _torRequirementBroken;
  bool get hasAttemptedConnection => _hasAttemptedConnection;
  bool get isConnected => _isConnected;
  bool get isSynced => _isSynced;
  int? get syncedHeight => _syncedHeight;

  BigInt? get unlockedBalanceBaseUnits => _unlockedBalanceBaseUnits;
  BigInt? get totalBalanceBaseUnits => _totalBalanceBaseUnits;

  /// Display-only. Lossy above 2^53 base units; use the base-unit getters for
  /// anything that is arithmetic on money.
  double? get unlockedBalance => _baseUnitsToDisplay(_unlockedBalanceBaseUnits);
  double? get totalBalance => _baseUnitsToDisplay(_totalBalanceBaseUnits);

  /// Exact decimal rendering. Prefer this to [unlockedBalance] for anything the
  /// user reads.
  String? get unlockedBalanceString => _unlockedBalanceBaseUnits == null
      ? null
      : baseUnitsToDecimalString(_unlockedBalanceBaseUnits!, baseUnitDecimals);

  String? get totalBalanceString => _totalBalanceBaseUnits == null
      ? null
      : baseUnitsToDecimalString(_totalBalanceBaseUnits!, baseUnitDecimals);

  double? _baseUnitsToDisplay(BigInt? units) =>
      units == null ? null : units.toDouble() / BigInt.from(10).pow(baseUnitDecimals).toDouble();

  List<TxDetails> get txHistory => List.unmodifiable(_txHistory);
  bool get isLoaded => _isLoaded;

  /// Opened or restored, enabled, and with a server configured.
  bool get isActive => _enabledInApp && _isLoaded && _connectionAddress.isNotEmpty;

  // ----- Namespaced preferences -----

  /// Namespaced through the app's [PrefKeyNamer], so Skylight keeps its bare
  /// keys and Spice its `xmr_` prefixes and neither app's users lose settings.
  ///
  /// This is **this coin's** namespace. Connection settings are the exception
  /// and go through [connPrefKey]; see there for why the two are separate.
  @protected
  String prefKey(String name) => WalletAppConfig.instance.prefKeyNamer(coinSymbol, name);

  /// Coin whose namespace holds the node/explorer connection prefs. Coins that
  /// ride on a parent's connection override it to the parent.
  @protected
  String get connectionPrefSymbol => coinSymbol;

  /// Namespaced under [connectionPrefSymbol] rather than [coinSymbol].
  ///
  /// Only the node and explorer settings belong here. An ERC-20 token has no
  /// RPC of its own, so sharing the parent chain's means the user configures a
  /// server once instead of once per token, but everything else about the
  /// token is the token's: its transactions, its restore height, and which
  /// receipts the user has already been told about.
  ///
  /// Routing *all* keys through this namespace is the bug this split exists to
  /// prevent, and it fails silently rather than loudly: the token reads the
  /// parent's notification cutoff, decides every transfer older than it has
  /// already been announced, and simply stops telling the user that money
  /// arrived. `app_config_test.dart` pins each half.
  @protected
  String connPrefKey(String name) =>
      WalletAppConfig.instance.prefKeyNamer(connectionPrefSymbol, name);

  // ----- Lifecycle hooks (subclass) -----

  Future<bool> hasExistingWallet();

  Future<void> openExisting({required String password});

  /// Restores from [seed], starting the scan at [from].
  ///
  /// Takes a [SeedSource] rather than a bare mnemonic, so the encoding travels
  /// with the value; Monero restores from polyseed, BIP39 and 25-word legacy.
  /// The base validates against [supportedSeedFormats]; subclasses do the work.
  Future<void> restoreFromSeed({
    required SeedSource seed,
    required RestorePoint from,
    required String password,
  });

  Future<bool> store();

  /// True when the open wallet was built for a different connection than the
  /// one now configured. Monero overrides for LWS↔node switches.
  Future<bool> needsRebuildForCurrentConnection() async => false;

  Future<void> deleteFiles();

  // ----- Daemon hooks (subclass) -----

  Future<void> connectToDaemonImpl({required String address, String? proxyPort});

  /// Standalone connectivity probe for the setup form. MUST NOT mutate live
  /// connection state.
  Future<void> testConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
    String connectionType = '',
  });

  Future<bool> getIsConnected();
  Future<void> refresh();
  Future<void> loadIsSynced();
  Future<void> loadSyncedHeight();
  Future<void> loadUnlockedBalance();
  Future<void> loadTotalBalance();
  Future<int> getCurrentHeight();
  Future<int> getRestoreHeight();
  List<TxDetails> readTxHistory();

  // ----- Send/receive hooks (subclass) -----

  String getPrimaryAddress();

  String? getReceiveAddress() => getPrimaryAddress();

  bool isAddressValid(String address);

  /// Builds and signs a transaction, without broadcasting it.
  ///
  /// [amountBaseUnits] is exact; there is no `double` on the send path.
  ///
  /// **The fee is not capped.** Checking it is reasonable is the app's job. Any
  /// ceiling here would be a guess about a fast-moving market, and a wrong guess
  /// silently blocks a correctly-priced urgent send.
  ///
  /// Server-supplied fee inputs reach the signed transaction as given. Show
  /// [PendingTransaction.feeBaseUnits] and warn on its ratio to the amount
  /// before calling [commitTx].
  Future<PendingTransaction> createTx(
    String destinationAddress,
    BigInt amountBaseUnits,
    bool isSweepAll, {
    int priority = 0,
  });

  /// The fee [createTx] would charge, without building the transaction, or null
  /// when this coin cannot say without building one.
  ///
  /// Building a transaction to learn its fee is expensive: Monero picks decoys
  /// and signs, which costs seconds per priority on a phone. A fee picker that
  /// shows three priorities would pay that three times over. A coin that can
  /// price a transaction locally overrides this; the caller falls back to
  /// [createTx] when it returns null.
  ///
  /// The result is an estimate. The fee that gets paid is the one on the
  /// [PendingTransaction] that [createTx] returns.
  Future<BigInt?> estimateFee(
    String destinationAddress,
    BigInt amountBaseUnits, {
    int priority = 0,
  }) async => null;

  /// Broadcasts a transaction [createTx] already signed. The point of no return.
  ///
  /// Call only after the user has seen [PendingTransaction.feeBaseUnits] and
  /// confirmed. Nothing below this line re-checks the fee.
  Future<void> commitTx(PendingTransaction tx, String destinationAddress);

  @protected
  Future<void> onTxHistoryGrew() async {}

  // ----- Seed policy enforcement -----

  /// Throws unless [seed] is permitted by both the app policy and this coin.
  @protected
  void checkSeedSupported(SeedSource seed) {
    WalletAppConfig.instance.seedPolicy.check(
      seed,
      coinSupported: supportedSeedFormats,
      coinSymbol: coinSymbol,
    );
  }

  // ----- Connection details -----

  void setConnection({
    required String address,
    required String proxyPort,
    required bool useTor,
    String connectionType = '',
  }) {
    _connectionAddress = address;
    _connectionProxyPort = proxyPort;
    _connectionUseTor = useTor;
    // Canonicalised on the way in, so the in-memory type and the type the pref
    // keys are named after cannot differ.
    _connectionType = canonicalConnectionType(connectionType);
    _torRequirementBroken = false;
    _isConnected = false;
    // The new server hasn't been synced to yet; clear stale sync state so the
    // status shows "syncing" and the connectivity poll runs on the fast cadence
    // (it backs off to 20s only while _isSynced) rather than lagging ~20s.
    _isSynced = false;
    _syncedHeight = null;
    _connectInFlight = null;
    _connectFailures = 0;
    _lastConnectAttempt = null;
    _connectionLoaded = true;
    notifyListeners();
  }

  /// Global Tor was turned off. A connection that requires it is marked broken
  /// and blocked from reconnecting until reconfigured; it must never silently
  /// continue in the clear.
  void onGlobalTorDisabled() {
    if (!_connectionUseTor || _torRequirementBroken) return;
    _torRequirementBroken = true;
    _isConnected = false;
    notifyListeners();
  }

  /// The type a bare or unrecognised persisted value means.
  ///
  /// `''` and anything not in [connectionTypeOptions] resolve to the first
  /// option, so Monero's `''` and `'lws'` are one server rather than two. This
  /// has to be total: the per-type key names are built from it, and two
  /// spellings of one mode would be two stored servers.
  ///
  /// A coin that declares no options has nothing to canonicalise against and
  /// gets its type back untouched. It has exactly one slot either way, so the
  /// value is informational there and [_connKey] keeps the flat keys.
  @protected
  String canonicalConnectionType(String type) {
    final options = connectionTypeOptions;
    if (options.isEmpty) return type;
    return options.contains(type) ? type : options.first;
  }

  /// The active connection type, never `''` for a coin that has a toggle.
  String get activeConnectionType => canonicalConnectionType(_connectionType);

  /// Pref key for [name] under [type]'s own slot.
  ///
  /// The server is stored **per type**, which is what makes an LWS connection to
  /// a node unrepresentable rather than merely guarded against. Two consequences
  /// worth knowing:
  ///
  ///  - selecting a mode selects that mode's server; neither can inherit the
  ///    other's, however the type came to change;
  ///  - a torn write is harmless. A stale type reads its own address, so the
  ///    pair is always self-consistent even if it is out of date, and
  ///    [persistCurrentConnection] needs no atomicity across keys.
  String _connKey(String name, String type) {
    // A coin with no toggle has one slot and uses the flat keys directly; only
    // a coin with a toggle gains suffixed keys.
    if (connectionTypeOptions.isEmpty) return connPrefKey(name);
    return connPrefKey('${name}_${canonicalConnectionType(type)}');
  }

  Future<void> persistCurrentConnection() async {
    final type = activeConnectionType;
    await SharedPreferencesService.set(_connKey('connectionAddress', type), _connectionAddress);
    await SharedPreferencesService.set(_connKey('connectionProxyPort', type), _connectionProxyPort);
    await SharedPreferencesService.set(_connKey('connectionUseTor', type), _connectionUseTor);
    // Last: everything it selects is already on disk, so a crash before this
    // leaves the previous type pointing at its own unchanged server.
    await SharedPreferencesService.set(connPrefKey('connectionType'), type);
  }

  /// The stored server for [type], regardless of which type is active.
  ///
  /// A mode with nothing stored reads back empty rather than borrowing another
  /// mode's server; `isActive` then treats the wallet as unconfigured, which is
  /// the honest answer and sends the user to the setup form.
  Future<WalletConnectionDetails> getPersistedConnectionForType(String type) async {
    final t = canonicalConnectionType(type);
    return WalletConnectionDetails(
      address: await SharedPreferencesService.get<String>(_connKey('connectionAddress', t)) ?? '',
      proxyPort:
          await SharedPreferencesService.get<String>(_connKey('connectionProxyPort', t)) ?? '',
      useTor: await SharedPreferencesService.get<bool>(_connKey('connectionUseTor', t)) ?? false,
      connectionType: t,
    );
  }

  Future<WalletConnectionDetails> getPersistedConnection() async => getPersistedConnectionForType(
    await SharedPreferencesService.get<String>(connPrefKey('connectionType')) ?? '',
  );

  Future<void> loadPersistedConnection() async {
    final c = await getPersistedConnection();
    setConnection(
      address: c.address,
      proxyPort: c.proxyPort,
      useTor: c.useTor,
      connectionType: c.connectionType,
    );

    final e = await getPersistedExplorerConnection();
    setExplorerConnection(address: e.address, proxyPort: e.proxyPort, useTor: e.useTor);
  }

  // ----- Explorer connection -----
  //
  // A separate server from the node, with its own settings and its own setup
  // form. Only coins whose node cannot serve transaction history need it.

  void setExplorerConnection({
    required String address,
    required String proxyPort,
    required bool useTor,
  }) {
    _explorerAddress = address;
    _explorerProxyPort = proxyPort;
    _explorerUseTor = useTor;
    notifyListeners();
  }

  Future<void> persistExplorerConnection() async {
    await SharedPreferencesService.set(connPrefKey('explorerAddress'), _explorerAddress);
    await SharedPreferencesService.set(connPrefKey('explorerProxyPort'), _explorerProxyPort);
    await SharedPreferencesService.set(connPrefKey('explorerUseTor'), _explorerUseTor);
  }

  Future<WalletConnectionDetails> getPersistedExplorerConnection() async => WalletConnectionDetails(
    address: await SharedPreferencesService.get<String>(connPrefKey('explorerAddress')) ?? '',
    proxyPort: await SharedPreferencesService.get<String>(connPrefKey('explorerProxyPort')) ?? '',
    useTor: await SharedPreferencesService.get<bool>(connPrefKey('explorerUseTor')) ?? false,
  );

  /// Probes an explorer endpoint. Coins with [supportsExplorerUrl] override this.
  ///
  /// Like [testConnection], it must not mutate live state.
  Future<void> testExplorerConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
  }) async {
    throw UnimplementedError('$coinSymbol has no explorer.');
  }

  /// Loads the persisted connection once, if it has not been loaded yet.
  ///
  /// Load-bearing for Monero: which wallet *file* exists
  /// depends on the connection type (LWS vs node), so `hasExistingWallet()`
  /// cannot answer correctly before the connection is known. Checking the
  /// default path first makes a node wallet look like a fresh install and drops
  /// the user into onboarding on top of an existing wallet.
  @protected
  Future<void> ensureConnectionLoaded() async {
    if (_connectionLoaded) return;
    await loadPersistedConnection();
  }

  // ----- Encrypted cache -----

  void setCachePassword(String? password) => _cachePassword = password;

  Future<void> loadCache() async {
    if (_cacheLoaded || _cachePassword == null) return;
    _cache = await WalletCacheStore.load(coinSymbol, _cachePassword!);
    _cacheLoaded = true;
  }

  Future<void> persistCache() async {
    if (_cachePassword == null || !_cacheDirty) return;
    await WalletCacheStore.save(coinSymbol, _cache, _cachePassword!);
    _cacheDirty = false;
  }

  /// True when [persistCache] has something to write. For subclasses that
  /// override the persist paths, and for tests; comparing two decrypted blobs
  /// cannot tell "wrote the same bytes again" from "did not write".
  @protected
  bool get cacheDirty => _cacheDirty;

  @protected
  String? cacheGetString(String key) => _cache[key] as String?;

  /// Stores [value] under [key], marking the cache dirty **only if it changed**.
  ///
  /// The comparison is the point. [persistCache] gates on [_cacheDirty], and
  /// without it every caller defeated that gate: [persistWalletSnapshot] writes
  /// the same three values on every 20-second refresh cycle, so a full AES-GCM
  /// encrypt of the whole cache and a file rewrite happened per cycle, per
  /// wallet, whether or not anything had moved. [cacheRemove] below always
  /// compared; the asymmetry was unintentional.
  ///
  /// This stops the encrypt and the write. It cannot stop the *encode*; a
  /// caller that passes `jsonEncode(...)` has already paid for it by the time
  /// this runs. Use [cachePutIfRevised] for those.
  @protected
  void cachePut(String key, Object? value) {
    if (value == null) return cacheRemove(key);
    if (_cache[key] == value) return;
    _cache[key] = value;
    _cacheDirty = true;
  }

  @protected
  void cacheRemove(String key) {
    if (_cache.remove(key) != null) _cacheDirty = true;
    _cacheRevisions.remove(key);
  }

  /// Cheap fingerprint of what was last handed to [cachePutIfRevised], per key.
  ///
  /// Runtime-only and deliberately not persisted: on a fresh open nothing is
  /// known about what is already in the cache, so the first call must encode.
  final Map<String, String> _cacheRevisions = {};

  /// Like [cachePut], but skips [encode] as well when nothing has changed.
  ///
  /// For values whose serialisation is itself expensive; the transaction
  /// history is a `jsonEncode` over every transaction the wallet has ever seen,
  /// and Bitcoin adds two more of its own. [revision] must be cheap to compute
  /// and must change whenever the encoded form would differ in a way worth
  /// persisting; [encode] then runs only when it has.
  ///
  /// Clearing the cache clears these too ([clearPersistedState]), so a wipe is
  /// never mistaken for "already up to date".
  @protected
  void cachePutIfRevised(String key, String revision, String Function() encode) {
    if (_cacheRevisions[key] == revision) return;
    // Recorded *after* the encode, not before: a throwing encode (Bitcoin's two
    // callers both catch one) would otherwise leave a revision claiming a value
    // that was never written, and nothing would ever try again.
    cachePut(key, encode());
    _cacheRevisions[key] = revision;
  }

  /// Restores the last known balance and tx list for immediate display while a
  /// fresh sync runs. Call [loadCache] first.
  Future<void> loadPersistedSnapshot() async {
    if (_connectionAddress.isEmpty) return;

    final unlocked = BigInt.tryParse(cacheGetString('cachedUnlockedBalanceUnits') ?? '');
    final total = BigInt.tryParse(cacheGetString('cachedTotalBalanceUnits') ?? '');
    if (unlocked != null) {
      setUnlockedBalanceBaseUnits(unlocked);
      setTotalBalanceBaseUnits(total ?? unlocked);
    }

    final txJson = cacheGetString('cachedTxHistory');
    if (txJson != null && txJson.isNotEmpty) {
      // parseCachedTxHistory never throws; the guard is for compute() itself.
      try {
        _txHistory = await compute(parseCachedTxHistory, txJson);
      } catch (e) {
        walletLog(LogLevel.warn, 'Failed to load cached tx history: $e');
      }
    }

    notifyListeners();
  }

  Future<void> persistWalletSnapshot() async {
    if (!isActive || _unlockedBalanceBaseUnits == null) return;

    // An unattended run may be holding a view-only wallet whose balance is
    // approximate; see [unattended]. The snapshot is what the next cold start
    // shows before any sync, so it must only ever come from the real wallet.
    if (_unattended && backgroundSyncMode == BackgroundSyncMode.scan) return;

    cachePut('cachedUnlockedBalanceUnits', _unlockedBalanceBaseUnits.toString());
    cachePut(
      'cachedTotalBalanceUnits',
      (_totalBalanceBaseUnits ?? _unlockedBalanceBaseUnits).toString(),
    );
    cachePutIfRevised(
      'cachedTxHistory',
      cachedTxHistoryRevision,
      () => jsonEncode(_txHistory.map((t) => t.toJson()).toList()),
    );
  }

  /// Fingerprint of [txHistory] for [cachePutIfRevised].
  ///
  /// Hash and height per transaction, plus the count. Those cover every
  /// structural change: a new transaction, a mempool transaction confirming
  /// (`height` -1 → real), a reorg moving one, and, via the count, a
  /// transaction dropping out.
  ///
  /// Confirmation counts are deliberately **excluded**, and they are the reason
  /// a plain value comparison is not enough on its own: they tick up with every
  /// block, so including them would re-encode the entire history every two
  /// minutes to persist a number that is derivable from the height and the tip.
  /// The cost is that a cold start can show a confirmation count up to one
  /// refresh cycle stale, which the first sync corrects.
  @protected
  String get cachedTxHistoryRevision {
    final parts = StringBuffer()..write(_txHistory.length);
    for (final tx in _txHistory) {
      parts
        ..write('|')
        ..write(tx.hash)
        ..write(':')
        ..write(tx.height);
    }
    return parts.toString();
  }

  // ----- Tx history -----

  /// Re-reads the transaction list.
  ///
  /// Note what this deliberately does *not* do: touch notification state. Every
  /// isolate (UI, foreground service, background task) refreshes history on
  /// its own timer, so anything recorded here would be consumed by whichever one
  /// refreshed first, whether or not it announced anything. That belongs to
  /// [notifyNewIncomingTxs], which the app calls from wherever it wants
  /// notifications to come from.
  /// [fresh], with the two fields a rescan cannot reproduce taken from what
  /// this wallet already held.
  ///
  /// Who an outgoing transaction paid, and its secret key, are recorded by the
  /// wallet that *built* it; Monero puts neither on chain in a form a wallet
  /// can read back. So the wallet rebuilt for an LWS<->node switch rescans, and
  /// reports the same transactions with no destinations and no keys. The plain
  /// assignment below would take that at face value -- and [loadAllStats]
  /// persists what it produces, so the copy this app had would go with it,
  /// on disk as well as on screen.
  ///
  /// Keyed on the transaction hash, and it only ever fills a gap. A hash names
  /// one transaction, so who it paid and what its key is are facts about it,
  /// not values that can legitimately become empty. A wallet that has the
  /// fields always wins; nothing here can overwrite a fresh reading.
  ///
  /// This recovers only what this install saw while in the other mode. A wallet
  /// restored straight onto a node has nothing to carry, and still shows no
  /// destinations for transactions it did not send.
  List<TxDetails> _withCarriedFields(List<TxDetails> fresh) {
    if (_txHistory.isEmpty || fresh.isEmpty) return fresh;

    Map<String, TxDetails>? previous;
    var out = fresh;

    for (var i = 0; i < fresh.length; i++) {
      final tx = fresh[i];
      final wantsRecipients = tx.recipients.isEmpty;
      final wantsKey = tx.key.isEmpty;
      if (!wantsRecipients && !wantsKey) continue;

      previous ??= {for (final old in _txHistory) old.hash: old};
      final old = previous[tx.hash];
      if (old == null) continue;

      final recipients = wantsRecipients && old.recipients.isNotEmpty ? old.recipients : null;
      final key = wantsKey && old.key.isNotEmpty ? old.key : null;
      if (recipients == null && key == null) continue;

      // Copied only once something is actually carried, so the common refresh
      // (every transaction complete) allocates nothing.
      if (identical(out, fresh)) out = List.of(fresh);
      out[i] = tx.copyWith(recipients: recipients, key: key);
    }

    return out;
  }

  Future<void> loadTxHistory({bool persistCount = true}) async {
    final previousLength = _txHistory.length;
    final newHistory = _withCarriedFields(readTxHistory());

    final hasPendingTx =
        newHistory.isNotEmpty && newHistory.first.confirmations < requiredConfirmations;

    final hadGrowth = newHistory.length > previousLength;

    // Keep the cached list when a sync returns nothing, e.g. not connected yet.
    if (newHistory.isNotEmpty || previousLength == 0) {
      _txHistory = newHistory;
    }

    if ((hadGrowth || hasPendingTx) && persistCount) {
      await persistTxHistoryCount();
    }

    if (hadGrowth) {
      // A transaction can appear without the synced height moving; a mempool
      // receipt does exactly that, and for a coin with a local cache it is
      // already in wallet2's, so a store() would write something the last one
      // did not.
      _markChainProgress();
      await onTxHistoryGrew();
    }
  }

  // ----- Incoming transaction notifications -----
  //
  // Hash-based, not count-based. Comparing transaction counts between refreshes
  // double-announces across isolates, loses a burst, and re-announces a mempool
  // payment when it confirms. See `tx_notifications.dart`.

  @protected
  String get txNotificationStateKey => prefKey('txNotificationState');

  /// Treats everything currently on chain as already seen.
  ///
  /// Called when a wallet is created or restored, [WalletManager] does it, and
  /// by the app when notifications are switched on, so the user is told about
  /// what arrives from here on rather than their whole history. Without it a
  /// restore announces every historical receipt as if it had just landed.
  Future<void> markExistingTxsAsNotified() async {
    await TxNotificationStore.write(
      txNotificationStateKey,
      TxNotificationState(
        cutoff: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        announcedHashes: const [],
      ),
    );
  }

  /// Announces incoming transactions the user hasn't been told about yet.
  ///
  /// Safe to call from any isolate and as often as you like: what has been
  /// announced is persisted, so a background task, a foreground service and the
  /// UI can't double-announce or cancel each other out.
  ///
  /// State is recorded whether or not anything was announced. With no
  /// [incomingTxNotifier] installed, the core's equivalent of "notifications
  /// off"; these transactions still count as seen, so switching notifications
  /// on later does not replay them.
  ///
  /// [announce] false records the current history as seen without firing the
  /// notifier: the foreground calls it so a transaction the user watched arrive
  /// on screen is not re-announced by a background isolate afterwards. It marks
  /// only the transactions actually in history (hash + confirmed-only cutoff),
  /// so a receipt that has not synced yet is still announced later.
  Future<void> notifyNewIncomingTxs({bool announce = true}) async {
    final state = await TxNotificationStore.read(txNotificationStateKey);

    // Never seeded (fresh install, or an upgrade from a counter-based scheme): take the
    // current chain as the starting point instead of announcing a backlog.
    if (state.cutoff == null) {
      await markExistingTxsAsNotified();
      return;
    }

    final decision = decideTxNotifications(
      txHistory: _txHistory,
      cutoff: state.cutoff!,
      announcedHashes: state.announcedHashes,
    );

    final notifier = incomingTxNotifier;
    if (announce && notifier != null) {
      for (final tx in decision.toAnnounce) {
        notifier(tx, coinSymbol);
      }
    }

    // Nothing moved, so nothing to write. Worth the check: this runs on a timer
    // and every write is a keystore round trip.
    //
    // `toAnnounce` empty is what makes this exact; the hash list is only ever
    // rewritten from `toAnnounce`, so an empty one leaves it byte-identical. A
    // length comparison would not do: at the cap the list changes contents
    // without changing length.
    if (decision.toAnnounce.isEmpty && decision.cutoff == state.cutoff) return;

    await TxNotificationStore.write(
      txNotificationStateKey,
      TxNotificationState(cutoff: decision.cutoff, announcedHashes: decision.announcedHashes),
    );
  }

  Future<void> persistTxHistoryCount() async {
    if (_txHistory.isEmpty) return;
    await SharedPreferencesService.set<int>(prefKey('txHistoryCount'), _txHistory.length);
  }

  Future<int> getPersistedTxHistoryCount() async =>
      await SharedPreferencesService.get<int>(prefKey('txHistoryCount')) ?? 0;

  // ----- Orchestration -----

  Future<void> load() async {
    if (!isActive) return;
    await connectToDaemon();
    await refresh();
    // The same gate [refreshTask] applies, and for a sharper reason here. This
    // is the path an LWS->node switch lands on, and the wallet it lands on was
    // rebuilt from the seed moments ago: it has scanned nothing. Reading stats
    // from it yields a zero balance and an empty history, and [loadAllStats]
    // does not merely display those -- it persists them over the cached
    // snapshot, so the balance and the transactions stay gone. While the scan
    // runs, the last known figures are the honest ones; [pollSyncStatus] pulls
    // real ones the moment the wallet has actually caught up.
    if (deferStatsUntilSynced && !_isSynced) return;
    await loadAllStats();
  }

  /// Applies a connection change after the app has set + persisted it. The base
  /// just reconnects; a coin whose server *kind* can change (Monero LWS↔node)
  /// overrides this to rebuild the wallet for the new kind first.
  Future<void> applyConnectionChange({required String password}) => load();

  /// Brings any unattended-sync configuration into line with the app's settings.
  ///
  /// A no-op for every coin whose unattended run is a
  /// [BackgroundSyncMode.check]; a server already did the scanning, so there is
  /// nothing to configure and no key exposure to reduce.
  ///
  /// It exists because Monero writes its configuration into the wallet file:
  /// `setupBackgroundSync` rewrites the keys file and the background cache, so it
  /// needs an open wallet and the wallet password. The open path calls this on
  /// launch; this hook covers the other moment it must happen; the user
  /// changing the setting on a running app, where otherwise nothing would reach
  /// the wallet until the next launch and the feature would sit inert.
  ///
  /// Call it from [WalletManager.applyBackgroundSyncSettingAll] after persisting
  /// the setting, alongside the background-task re-registration.
  Future<void> applyBackgroundSyncSetting({required String password}) async {}

  Future<void> loadAllStats() async {
    if (!isActive) return;

    // Balance and sync state first; the tx history read is the slow one and
    // must not hold up the number the user is looking at.
    await Future.wait([
      loadIsSynced(),
      loadSyncedHeight(),
      loadUnlockedBalance(),
      loadTotalBalance(),
    ]);
    notifyListeners();

    await loadTxHistory();
    notifyListeners();

    if (await getIsConnected()) {
      await persistWalletSnapshot();
      await persistCache();
    }
  }

  /// Connects, or does nothing when this wallet is not in a state to connect.
  ///
  /// A wallet that is disabled, unopened or has no server configured is a
  /// no-op; the refresh cycle calls this on every coin the app holds, and most
  /// of them are usually one of those three.
  ///
  /// There is deliberately no throw for the unopened case: [isActive] already
  /// requires `_isLoaded`, so the early return above always wins and a guard
  /// that cannot fire would only mislead.
  Future<void> connectToDaemon() async {
    if (!isActive) return;
    await _doConnect();
  }

  /// True when [connectToDaemonImpl] needs only the persisted settings, so the
  /// manager can run it in parallel with [openExisting]. Coins whose connect
  /// touches the open wallet object (Monero) must leave this false.
  bool get canConnectBeforeOpen => false;

  Future<void> connectBeforeOpen() async {
    if (!canConnectBeforeOpen) return;
    if (!_enabledInApp || _connectionAddress.isEmpty) return;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    final existing = _connectInFlight;
    if (existing != null) return existing;

    final future = _connectImpl();
    _connectInFlight = future;
    try {
      await future;
    } finally {
      _connectInFlight = null;
    }
  }

  Future<void> _connectImpl() async {
    _lastConnectAttempt = DateTime.now();

    String? torProxyPort;
    if (_connectionUseTor) {
      final proxyInfo = await TorSettingsService.sharedInstance.getProxy();
      if (proxyInfo == null) {
        // Fail closed. A connection configured for Tor must never fall back to
        // clearnet; that would deanonymise the user silently.
        walletLog(LogLevel.warn, 'useTor set but no Tor proxy; skipping connect');
        _torRequirementBroken = true;
        _isConnected = false;
        _connectFailures++;
        notifyListeners();
        return;
      }
      torProxyPort = proxyInfo.port.toString();
    }

    final proxyPort = torProxyPort ?? _connectionProxyPort;

    // Require onion addresses to go through Tor or a SOCKS proxy
    if (isUnroutedOnion(_connectionAddress, viaProxy: proxyPort.isNotEmpty)) {
      walletLog(LogLevel.warn, 'onion address with no Tor route; skipping connect');
      _torRequirementBroken = true;
      _isConnected = false;
      _connectFailures++;
      notifyListeners();
      return;
    }

    try {
      await connectToDaemonImpl(address: _connectionAddress, proxyPort: proxyPort);
    } catch (e) {
      _connectFailures++;
      rethrow;
    }

    _hasAttemptedConnection = true;
    _isConnected = await getIsConnected();
    _connectFailures = _isConnected ? 0 : _connectFailures + 1;
    notifyListeners();
  }

  /// Backoff schedule for reconnect attempts, in seconds.
  static const _reconnectBackoffSeconds = [1, 2, 5, 10, 20];

  /// Retries a connection that isn't up, on a short backoff.
  ///
  /// Without this the only reconnect is the 20s refresh cycle, so
  /// a connect that fails at launch (Tor not ready, node briefly unreachable)
  /// leaves the wallet doing nothing behind a spinner for up to 20 seconds.
  /// Whether [_retryConnectIfDue] would attempt a reconnect at [now].
  ///
  /// Extracted for the same reason `looksLikeMoneroNodeBody` is a function: the
  /// only caller runs on a timer, so the schedule is otherwise testable only by
  /// waiting out real seconds. The decision is the part worth pinning; a
  /// backoff that never expires and one that ignores its own delay both look
  /// like "reconnects eventually" from outside.
  @visibleForTesting
  bool isReconnectDue(DateTime now) {
    if (!isActive || _isConnected || _connectInFlight != null) return false;
    if (_torRequirementBroken) return false;

    final lastAttempt = _lastConnectAttempt;
    if (lastAttempt == null) return true;

    final index = min(_connectFailures, _reconnectBackoffSeconds.length - 1);
    return now.difference(lastAttempt) >= Duration(seconds: _reconnectBackoffSeconds[index]);
  }

  Future<void> _retryConnectIfDue() async {
    if (!isReconnectDue(DateTime.now())) return;

    try {
      await connectToDaemon();
      if (!_isConnected) return;
      await refresh();
      if (deferStatsUntilSynced && !_isSynced) return;
      await loadAllStats();
    } catch (e) {
      walletLog(LogLevel.warn, 'Reconnect attempt failed: $e');
    }
  }

  /// Wipes the wallet: its files, its native handle, and everything persisted
  /// under its namespace.
  ///
  /// Held under [runWithSyncSuspended] for the same reason the LWS<->node
  /// rebuild is: [deleteFiles] closes the native wallet, and a refresh or
  /// connection tick inside its native section when the handle is freed is a
  /// use-after-free -- a SIGSEGV, not a catchable Dart error. The window is
  /// wide open here, because nothing has told the timers to stand down yet:
  /// `_isLoaded` is still true throughout the close, so `isActive` is true, and
  /// a tick that finds `_isConnected` false will happily `init` the wallet and
  /// restart its scan thread while the object underneath is being destroyed.
  Future<void> delete() async {
    await runWithSyncSuspended(() async {
      await deleteFiles();
      await clearPersistedState();
    });
    setIsLoaded(false);
  }

  Future<void> clearPersistedState() async {
    for (final k in ['walletRestoreHeight', 'txHistoryCount']) {
      await SharedPreferencesService.remove(prefKey(k));
    }
    _cache = {};
    _cacheDirty = false;
    // Or the next persist skips the encode on a revision that describes a cache
    // that no longer exists, and the wiped values are never rewritten.
    _cacheRevisions.clear();
    await WalletCacheStore.delete(coinSymbol);
    // Two secrets, two lifetimes: a deleted wallet must not leave a marker
    // behind. Left in place, the next wallet on this device inherits a cutoff
    // from someone else's history and stays silent about its own first receipts.
    await TxNotificationStore.delete(txNotificationStateKey);
  }

  /// Stops any native scan thread and checkpoints what it managed to scan.
  ///
  /// Required for background sync: nothing else closes the wallet
  /// when a background task ends, so a refresh left running keeps pulling
  /// blocks past the end of the task and everything scanned since the last
  /// checkpoint is lost with the isolate.
  ///
  /// **Unconditional, and it must stay that way.** This is the teardown
  /// checkpoint, and it is the one write whose absence is not a wasted write
  /// but a lost window: the native scan thread advances state Dart cannot
  /// observe, so a dirty flag that happens to be clear here turns "bounded
  /// rescan after a kill" into "lost everything since the last store". The
  /// Only the timer-driven stores are gated; see [_storeIfDirty].
  Future<void> pauseSyncAndStore() async {
    if (!_isLoaded) return;
    await pauseSync();
    await _recordStore();
  }

  /// Stops a running native scan. No-op for coins that have none.
  @protected
  Future<void> pauseSync() async {}

  // ----- Protected state mutators -----

  @protected
  void setIsLoaded(bool value) {
    _isLoaded = value;
    if (!value) {
      _hasAttemptedConnection = false;
      _isConnected = false;
      _isSynced = false;
      _syncedHeight = null;
      _unlockedBalanceBaseUnits = null;
      _totalBalanceBaseUnits = null;
      _txHistory = [];
    }
    notifyListeners();
  }

  @protected
  void setIsConnected(bool value) => _isConnected = value;

  // The four below mark the wallet's persisted state dirty **only when the
  // value actually differs**, and only for a coin whose `store()` tracks the
  // chain at all; see [storeTracksChainProgress]. That pair of conditions is
  // what makes the gate on [_storeIfDirty] mean anything. `setIsConnected` is
  // not among them: connectivity is not wallet state and nothing writes it.

  @protected
  void setIsSynced(bool value) {
    if (_isSynced != value) _markChainProgress();
    _isSynced = value;
  }

  @protected
  void setSyncedHeight(int? value) {
    // The signal that a native scan advanced. Dart cannot see wallet2's cache
    // change, so a moving height is the only observable proof that a store()
    // would write something new, which makes this the load-bearing one for
    // Monero in node mode.
    if (_syncedHeight != value) _markChainProgress();
    _syncedHeight = value;
  }

  @protected
  void setUnlockedBalanceBaseUnits(BigInt? value) {
    if (_unlockedBalanceBaseUnits != value) _markChainProgress();
    _unlockedBalanceBaseUnits = value;
  }

  @protected
  void setTotalBalanceBaseUnits(BigInt? value) {
    if (_totalBalanceBaseUnits != value) _markChainProgress();
    _totalBalanceBaseUnits = value;
  }

  // ----- Store gating -----

  /// Whether [store] persists anything that moves with the chain.
  ///
  /// **Default true**, and deliberately the safe answer: a coin whose `store()`
  /// writes a scan cache, Monero's `wallet2::store()`, has to checkpoint as
  /// the chain advances, and a coin added later that never thinks about this
  /// should err towards writing rather than towards silently stopping.
  ///
  /// Bitcoin and Ethereum override it to false. Their wallet files hold a
  /// mnemonic, derived addresses, next-index counters and a restore date, and
  /// none of that changes because a block arrived; so inheriting the height
  /// signal would rewrite an Ethereum wallet file, PBKDF2 and all, once per
  /// Ethereum block forever. Those coins call [markStoreDirty] at the mutations
  /// that do change their file.
  @protected
  bool get storeTracksChainProgress => true;

  void _markChainProgress() {
    if (storeTracksChainProgress) markStoreDirty();
  }

  bool _storeDirty = false;

  /// Bumped by every [markStoreDirty]. Read around the `await` in
  /// [_recordStore] so a mutation that lands *during* a store is not thrown
  /// away by the flag being cleared afterwards.
  int _storeGeneration = 0;

  /// Records that a `store()` would now write something new.
  ///
  /// For subclasses whose persisted state changes somewhere the base cannot
  /// see. Call it at the mutation, not at each call site that leads to one:
  /// Bitcoin's derived address rows are appended by `_ensureAddressesUpTo`,
  /// reached from the send, receive, primary-address and scan paths, and one
  /// call inside it covers all four where four call sites would drift.
  ///
  /// Deliberately not a state *fingerprint*. Height, balance and transaction
  /// count miss exactly this kind of state, and a fingerprint that misses
  /// something fails silently; the wallet stops persisting and nothing says so.
  @protected
  void markStoreDirty() {
    _storeDirty = true;
    _storeGeneration++;
  }

  /// True when [store] has something new to write. For subclass overrides of
  /// the persist paths, and for tests.
  @protected
  bool get storeDirty => _storeDirty;

  /// [store], plus the bookkeeping every store shares.
  ///
  /// One helper for both call sites so a checkpoint at T is not followed by a
  /// redundant full store seconds later, and so the flag is cleared in exactly
  /// one place.
  Future<void> _recordStore() async {
    final generation = _storeGeneration;
    _lastSyncCheckpoint = DateTime.now();
    await store();
    // Cleared only if nothing was marked dirty inside the await above.
    // `pollSyncStatus` runs on its own timer and can move the synced height
    // mid-store; clearing unconditionally would drop a mutation nothing wrote.
    if (_storeGeneration == generation) _storeDirty = false;
  }

  Future<void> _storeIfDirty() async {
    if (!_storeDirty) return;
    await _recordStore();
  }

  // ----- Timers -----

  void _startTimers() {
    _scheduleConnectionCheck();
    _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) => refreshTask());
  }

  /// Poll interval while syncing. Fast by default so the UI flips to "synced"
  /// promptly; coins whose status poll contends with an on-device scan back off.
  @protected
  Duration get syncingPollInterval => const Duration(seconds: 1);

  /// Minimum spacing between (potentially networked) connectivity checks.
  @protected
  Duration get connectivityCheckInterval => const Duration(seconds: 15);

  /// Runs on the fast cadence. Coins whose sync state can flip between refresh
  /// cycles, a Monero full node sets "synchronized" from a background thread,
  /// override this to pick it up promptly.
  @protected
  Future<void> pollSyncStatus() async {}

  /// When true, [refreshTask] skips [loadAllStats] until synced, so heavy
  /// reads don't contend with an on-device scan. Only safe when sync status is
  /// updated independently; see [pollSyncStatus].
  @protected
  bool get deferStatsUntilSynced => false;

  void _scheduleConnectionCheck() {
    if (_disposed) return;
    final interval = _isSynced ? const Duration(seconds: 20) : syncingPollInterval;
    _connectionTimer = Timer(interval, () async {
      await checkConnectionTask();
      _scheduleConnectionCheck();
    });
  }

  /// One tick of the connection timer.
  ///
  /// Visible for testing along with [refreshTask]: between them these two are
  /// the whole periodic behaviour of this class; the reconnect, the throttled
  /// connectivity probe, the sync poll and the deferred-stats branch, and a
  /// `Timer` on a 1-to-20 second period is not something a unit test can wait
  /// out. Nothing outside the schedulers calls either.
  @visibleForTesting
  Future<void> checkConnectionTask() async {
    if (!isActive || _connectionCheckInFlight || _syncSuspended) return;

    if (_torRequirementBroken) {
      if (_isConnected) {
        _isConnected = false;
        notifyListeners();
      }
      return;
    }

    _connectionCheckInFlight = true;
    try {
      // The connectivity probe can be networked, so throttle it; local sync
      // polling still runs every tick so the UI stays responsive.
      final now = DateTime.now();
      if (_lastConnectivityCheck == null ||
          now.difference(_lastConnectivityCheck!) >= connectivityCheckInterval) {
        _lastConnectivityCheck = now;
        final connected = await getIsConnected();
        if (connected != _isConnected) {
          walletLog(LogLevel.info, 'Connection status changed to: $connected');
          _isConnected = connected;
          notifyListeners();
        }
      }

      // Not awaited: a connect can take seconds over Tor and must not hold up
      // the sync poll below. Re-entry is guarded by _connectInFlight.
      unawaited(_retryConnectIfDue());

      await pollSyncStatus();
    } finally {
      _connectionCheckInFlight = false;
    }
  }

  /// How long a stretch of scanning a kill is allowed to cost.
  @protected
  Duration get syncCheckpointInterval => const Duration(minutes: 3);

  /// Persists scan progress at most every few minutes during a long sync, so
  /// checkpointing doesn't stall the native scan the way a per-cycle store would.
  ///
  /// Gated on [_storeDirty] as well as the clock. Without that, a stalled scan
  /// (dead node, a `refresh()` that threw, a paused thread) rewrites a
  /// byte-identical cache every three minutes for as long as the app is open,
  /// and each of those writes is a truncate-then-rewrite with a corruption
  /// window.
  ///
  /// The clock stays the trigger rather than blocks scanned: it already bounds
  /// the loss window from both ends, since three minutes of scanning is three
  /// minutes of rescanning however fast the node is.
  Future<void> _checkpointStoreIfDue() async {
    if (!_storeDirty) return;
    final now = DateTime.now();
    if (_lastSyncCheckpoint != null &&
        now.difference(_lastSyncCheckpoint!) < syncCheckpointInterval) {
      return;
    }
    await _recordStore();
  }

  /// One tick of the refresh timer. See [checkConnectionTask] on visibility.
  @visibleForTesting
  Future<void> refreshTask() async {
    if (!isActive || _refreshInFlight || _torRequirementBroken || _syncSuspended) return;

    _refreshInFlight = true;
    try {
      try {
        if (!_isConnected) await connectToDaemon();
      } catch (e) {
        // Connect threw: the wallet may be unusable, so end the cycle rather
        // than refresh a dead wallet.
        walletLog(LogLevel.warn, 'connect failed: $e');
        return;
      }
      // Note: NOT gated on _isConnected. A connect that returns without throwing
      // is enough to proceed; a light wallet syncs server-side, and it is
      // refresh() (the login/scan round-trip) that advances the sync and makes
      // the daemon finally report connected. Gating on _isConnected here would
      // deadlock LWS: never refresh, so never connected, so never refresh.
      // refresh()/loadAllStats() self-guard on _daemonInitialised; a
      // disconnected node falls through to the deferred-stats branch below.

      // While an on-device scan runs, leave the wallet alone: refresh(), the
      // history read and store() each take the wallet lock and stall the native
      // scan thread. Just checkpoint occasionally so an interrupted sync can
      // resume; pollSyncStatus loads stats once it catches up.
      if (deferStatsUntilSynced && !_isSynced) {
        await _checkpointStoreIfDue();
        return;
      }

      try {
        await refresh();
      } catch (e) {
        walletLog(LogLevel.warn, 'refresh failed: $e');
      }
      try {
        await loadAllStats().timeout(const Duration(seconds: 20));
      } catch (e) {
        walletLog(LogLevel.error, 'Error loading all stats: $e');
      }
      // Gated here rather than inside store(): store() is also the teardown
      // checkpoint (pauseSyncAndStore), the post-send flush (commitTx) and the
      // end of a restore, and every one of those must write unconditionally.
      // This is the only call that fires three times a minute forever.
      await _storeIfDirty();
    } finally {
      _refreshInFlight = false;
    }
  }

  /// Runs [action] with the refresh/connection timers held off, after draining
  /// any tick already inside its native section.
  ///
  /// A connection-change rebuild (LWS↔node) closes and reopens the native
  /// wallet. A timer-driven `store()` / `refresh()` / `getIsConnected()` racing
  /// that close is a use-after-free on the freed handle; a SIGSEGV in the
  /// native lib, not a Dart exception. Draining the in-flight guards means the
  /// handle is only freed once no native call is outstanding.
  @protected
  /// Nesting depth, so an inner call cannot un-suspend an outer one.
  ///
  /// A plain flag made this primitive unsafe to nest, and nesting is reachable:
  /// the connection-change rebuild wraps `_rebuildForConnectionType`, which
  /// re-opens the wallet, and an open now configures background sync inside its
  /// own suspension. With a flag the inner `finally` cleared the outer's
  /// protection and the timers resumed against a half-rebuilt wallet.
  int _syncSuspendDepth = 0;

  Future<T> runWithSyncSuspended<T>(Future<T> Function() action) async {
    _syncSuspendDepth++;
    _syncSuspended = true;
    try {
      while (_refreshInFlight || _connectionCheckInFlight) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // A connect fired unawaited by the connection tick can still hold the
      // handle; let it finish too.
      try {
        await _connectInFlight;
      } catch (_) {}
      return await action();
    } finally {
      _syncSuspendDepth--;
      if (_syncSuspendDepth == 0) _syncSuspended = false;
    }
  }

  /// Dropped rather than thrown once [dispose] has run.
  ///
  /// Cancelling the timers does not cancel what they already started. A connect
  /// over Tor takes seconds and `loadAllStats` runs with a twenty-second
  /// timeout, so a wallet can be disposed inside either window; the app
  /// switches coins, a background isolate ends, and every one of those paths
  /// finishes with a `notifyListeners()`. `ChangeNotifier` reads that as
  /// use-after-dispose and throws, which in debug takes down whatever was
  /// awaiting the call.
  ///
  /// After dispose there are no listeners left, so the notification has nowhere
  /// to go and dropping it is the whole correct behaviour. Guarding here rather
  /// than at each call site because the call sites are a list, and the next one
  /// added gets left off it.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _connectionTimer?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }
}
