import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'consts.dart';
import 'ffi_monero_backend.dart';
import 'height_by_date.dart';
import 'monero_backend.dart';
import 'seed/bip39_legacy.dart';

/// Ceiling on a connection-probe reply.
///
/// `get_info` from a monerod is a small JSON object, and the `upsert_subaddrs`
/// acknowledgement is smaller. Sized for those rather than for a wallet's
/// working data, because this runs against an address the user has only just
/// entered.
const int maxProbeResponseBytes = 256 * 1024;

/// A pending Monero transaction.
class MoneroPendingTransaction implements PendingTransaction {
  MoneroPendingTransaction({
    required this.handle,
    required this.amountBaseUnits,
    required this.feeBaseUnits,
  });

  final NativeHandle handle;

  @override
  final BigInt amountBaseUnits;

  @override
  final BigInt feeBaseUnits;
}

/// Monero, over either a light-wallet server (LWSF) or a full node (wallet2).
///
/// Several routines here look defensive or redundant. Each one exists because
/// something went wrong in production, and the comment at the site says what.
/// Removing one reintroduces the bug it was written for.
class MoneroWallet extends CryptoWallet {
  MoneroWallet({MoneroBackend? backend}) : _backend = backend ?? const FfiMoneroBackend();

  final MoneroBackend _backend;

  NativeHandle? _manager;
  NativeHandle? _wallet;
  NativeHandle? _history;

  /// Which factory built the currently-open wallet, or null when none is open.
  MoneroManagerKind? _loadedKind;

  /// Which factory built the cached [_manager].
  MoneroManagerKind? _managerKind;

  bool _daemonInitialised = false;

  int? _daemonTargetHeight;

  /// Last `Wallet_synchronized` reading, before [_syncedGivenHeights] narrows
  /// it. Kept so a daemon height that arrives later can re-decide without
  /// waiting for the next poll -- which, if the flag wrongly said synced, is
  /// the 20s backed-off tick rather than the 3s syncing one.
  bool _reportedSynchronized = false;
  DateTime? _lastDaemonHeightFetch;

  bool? _serverSupportsSubaddresses;
  int? _unusedSubaddressIndex;
  bool? _unusedSubaddressIndexIsSupported;

  bool? get serverSupportsSubaddresses => _serverSupportsSubaddresses;
  int? get unusedSubaddressIndex => _unusedSubaddressIndex;
  bool? get unusedSubaddressIndexIsSupported => _unusedSubaddressIndexIsSupported;

  // ----- Coin metadata -----

  @override
  String get coinSymbol => 'XMR';
  @override
  String get blockchainName => 'Monero';
  @override
  String get iconAsset => 'assets/icons/monero.svg';
  @override
  int get decimals => MoneroConsts.decimals;
  @override
  int get smallerDigits => MoneroConsts.smallerDigits;
  @override
  int get requiredConfirmations => MoneroConsts.requiredConfirmations;

  /// Monero restores from all three encodings. The app's `SeedPolicy` is the
  /// other half of the check.
  @override
  Set<SeedFormat> get supportedSeedFormats => const {
    SeedFormat.polyseed,
    SeedFormat.bip39,
    SeedFormat.moneroLegacy,
  };

  @override
  String get aliasNetwork => 'xmr';

  @override
  List<String> get connectionTypeOptions => const ['lws', 'node'];

  bool get _isNodeMode => connectionType == 'node';

  MoneroManagerKind get _desiredKind =>
      _isNodeMode ? MoneroManagerKind.node : MoneroManagerKind.lws;

  @override
  String get connectionTypeName => _isNodeMode ? 'Monero node' : 'Monero LWS server';

  @override
  String get connectionAddressExample => 'lws.example.com:18090';

  @override
  String connectionAddressExampleForType(String connectionType) =>
      connectionType == 'node' ? 'node.example.com:18081' : 'lws.example.com:18090';

  /// A full node scans on-device, so the heavy stat reads must wait for it.
  /// LWS has the server do the scanning and needs no such deferral.
  @override
  bool get deferStatsUntilSynced => _isNodeMode;

  /// The one coin whose background work can be either a scan or a check.
  ///
  /// In node mode wallet2 trial-decrypts every output on this device: a
  /// [BackgroundSyncMode.scan], the only one in the repository, and the only
  /// place where which key the process holds is a question. In LWS mode the
  /// light-wallet server already holds the view key and did the scanning, so a
  /// background run is a [BackgroundSyncMode.check]; structurally view-only
  /// already, with no local scan to protect.
  @override
  BackgroundSyncMode get backgroundSyncMode {
    if (connectionAddress.isEmpty) return BackgroundSyncMode.none;
    return _isNodeMode ? BackgroundSyncMode.scan : BackgroundSyncMode.check;
  }

  /// `wallet2::store()` writes the scan cache, so it has to keep up with the
  /// chain; the base's default, spelled out here because it is the one coin
  /// where it is true.
  @override
  bool get storeTracksChainProgress => true;

  /// The gap between the wallet's scanned height and the daemon's. Null unless
  /// in node mode and still syncing.
  @override
  int? get syncBlocksRemaining {
    if (!_isNodeMode || isSynced) return null;
    final target = _daemonTargetHeight;
    final scanned = syncedHeight;
    if (target == null || scanned == null || target <= scanned) return null;
    return target - scanned;
  }

  /// Polling a full node's status is cheap locally but contends with the native
  /// scan thread, so back off from the base's 1s.
  @override
  Duration get syncingPollInterval =>
      _isNodeMode ? const Duration(seconds: 3) : const Duration(seconds: 1);

  /// 15 s in node mode, 1 s in LWS mode.
  ///
  /// `Wallet_connected` looks like a local read, but it takes the same mutex
  /// wallet2 holds across an entire `/getblocks.bin` download. In node mode that
  /// lock wait blocks the sync poll, so progress appears in bursts at batch
  /// boundaries. LWS has no scan competing for the mutex, and there the base
  /// throttle would make a login look like a 15 s stall.
  @override
  Duration get connectivityCheckInterval =>
      _isNodeMode ? const Duration(seconds: 15) : const Duration(seconds: 1);

  // ----- Paths -----

  /// LWS and node keep separate cache files sharing the same keys, so toggling
  /// between them doesn't force a rescan. The base name comes from the app's
  /// [WalletFileNamer] so Skylight keeps `mywallet` and Spice `mywallet_xmr`
  /// and neither has to migrate.
  Future<String> resolveWalletPath() => walletPathForType(connectionType);

  /// Names the file a given mode would use. [_adoptModeWithExistingWallet] needs
  /// to ask about the mode that is not current.
  Future<String> walletPathForType(String type) async {
    final dir = await getAppDir();
    final base = WalletAppConfig.instance.walletFileNamer(coinSymbol);
    return type == 'node' ? '${dir.path}/${base}_node' : '${dir.path}/$base';
  }

  /// The view-only companion wallet `setupBackgroundSync` writes.
  ///
  /// `wallet2::make_background_wallet_file_name` is `<wallet_file>.background`,
  /// with `.keys` and (non-mainnet only) `.address.txt` beside it. The name is
  /// wallet2's, not ours; an unattended run opens this path by it.
  static String backgroundPathFor(String walletPath) => '$walletPath.background';

  Future<NativeHandle> _walletManager() async {
    if (_manager != null && _managerKind == _desiredKind) return _manager!;
    _manager = await _backend.getWalletManager(_desiredKind);
    _managerKind = _desiredKind;
    return _manager!;
  }

  // ----- Lifecycle -----

  @override
  Future<bool> hasExistingWallet() async {
    // Which file exists depends on the connection type, so the connection must
    // be known first. Checking the default LWS path
    // makes a node wallet look like a fresh install and drops the user into
    // onboarding on top of an existing wallet.
    await ensureConnectionLoaded();

    final manager = await _walletManager();
    final path = await resolveWalletPath();

    if (await _backend.walletExists(manager, path)) return true;

    final error = await _backend.managerErrorString(manager);
    if (error.isNotEmpty) walletLog(LogLevel.warn, 'walletExists error: $error');

    return _adoptModeWithExistingWallet();
  }

  /// Recovers from a connection/file mismatch.
  ///
  /// When the persisted mode has no wallet file but the other mode does; an
  /// LWS↔node switch interrupted before the new file was written; switch to the
  /// mode that has one. Reporting "no wallet" instead sends the user through
  /// onboarding on top of an existing wallet.
  Future<bool> _adoptModeWithExistingWallet() async {
    final otherType = _isNodeMode ? 'lws' : 'node';
    final otherPath = await walletPathForType(otherType);

    // wallet2 (node) writes `<path>` plus `<path>.keys`; LWSF writes one file.
    final otherExists = await File(otherPath).exists() || await File('$otherPath.keys').exists();
    if (!otherExists) return false;

    walletLog(
      LogLevel.warn,
      'No "$connectionType" wallet file but a "$otherType" one exists; '
      'switching the connection type to match.',
    );

    // The adopted mode's *own* server, never the current one. Carrying the
    // address across the mode change is what pointed a light-wallet session at
    // the user's node and POSTed the view key to it; the node address stays
    // parked under `node` until a node wallet file exists to go with it.
    final adopted = await getPersistedConnectionForType(otherType);
    setConnection(
      address: adopted.address,
      proxyPort: adopted.proxyPort,
      useTor: adopted.useTor,
      connectionType: otherType,
    );
    // Persisted, not just in memory: callers reload the connection right after.
    await SharedPreferencesService.set<String>(connPrefKey('connectionType'), otherType);
    return true;
  }

  @override
  Future<void> openExisting({required String password}) async {
    // Opening the same file twice leaves two wallets, and two sync loops,
    // running against it. The first is never closed and both write the cache.
    if (_wallet != null && _loadedKind == _desiredKind) {
      walletLog(LogLevel.warn, 'Wallet already open for "$_loadedKind"; skipping re-open.');
      return;
    }

    final manager = await _walletManager();

    // An unattended node-mode run opens the view-only companion instead, with
    // its own password. Resolved before anything is opened, because it decides
    // both the path and the password; see [_backgroundOpenTarget].
    final target = await _backgroundOpenTarget();
    final path = target?.path ?? await resolveWalletPath();
    final openPassword = target?.password ?? password;

    final wallet = await _backend.openWallet(manager, path: path, password: openPassword);
    final error = await _backend.walletErrorString(wallet);
    if (error.isNotEmpty) {
      walletLog(LogLevel.error, 'openWallet error: $error');
      throw Exception('openWallet error: $error');
    }

    if (target != null) {
      // Assert rather than assume. If this file turned out not to be a
      // background wallet, the run is holding a spendable key with no user
      // present, the exact posture the whole mechanism exists to prevent, so
      // it fails rather than carrying on.
      if (!await _backend.isBackgroundWallet(wallet)) {
        await _backend.closeWallet(manager, wallet, store: false);
        throw StateError(
          'Opened "${path.split('/').last}" for an unattended run and it is not a '
          'background wallet; refusing to sync with a spendable key.',
        );
      }
      _isBackgroundWallet = true;
      walletLog(LogLevel.info, 'Unattended run: opened the view-only background cache.');
    }

    _wallet = wallet;
    _history = await _backend.history(wallet);
    _loadedKind = _desiredKind;

    await loadPersistedSubaddressState();
    await loadPrimaryAddress();
    setIsLoaded(true);

    // With the main wallet open and its password in hand, bring the background
    // configuration into line with the user's setting. Never from an unattended
    // run: it holds no wallet password, and `setupBackgroundSync` refuses to run
    // from a background cache anyway.
    if (target == null) await applyBackgroundSyncSetting(password: password);
  }

  /// True when the open wallet is the view-only background cache rather than the
  /// real one. Governs the two things that must not happen against it: a tx-key
  /// lookup, and writing its approximate numbers to the display snapshot.
  bool _isBackgroundWallet = false;

  bool get isBackgroundWallet => _isBackgroundWallet;

  // ----- Native view-key background sync (node mode only) -----
  //
  // `setupBackgroundSync` writes a second wallet beside the main one:
  // `<path>_node.background`, whose keys file had `forget_spend_key()` applied
  // and is encrypted with the cache password alone. It holds no spend key.
  //
  // An unattended run opens that file instead of the main wallet, then does what
  // the ordinary path does: init, connectToDaemon, startRefresh, store. Do not
  // call `startBackgroundSync` or `stopBackgroundSync`; both throw on a wallet
  // that is already a background wallet.
  //
  // The merge back is automatic: `wallet2::load` replays the background cache
  // into the main wallet on the next open with the real password.
  //
  // Two costs:
  //
  //  - every `store()` on the main wallet also rewrites the background cache, so
  //    two serialisations per store. The store gate in `CryptoWallet` is a
  //    prerequisite for enabling this.
  //  - a background wallet does not scan the mempool, so a receipt is noticed
  //    when mined rather than when broadcast. Delayed, not lost.

  /// Secure-storage key for this coin's background-cache password.
  String get backgroundCachePasswordKey => prefKey('backgroundCachePassword');

  /// Where an unattended run should open, or null when it should use the normal
  /// path.
  ///
  /// Null unless *all* of: this is an unattended run, the mode is node (LWSF
  /// implements none of this), a cache password has been stored, and the file
  /// exists. Any of those missing means the run falls back to the main wallet;
  /// which still works, and is what happens on the very first run after the
  /// setting is switched on.
  Future<({String path, String password})?> _backgroundOpenTarget() async {
    if (!unattended || !_isNodeMode) return null;

    final password = await WalletSecrets.store.read(backgroundCachePasswordKey);
    if (password == null || password.isEmpty) {
      walletLog(
        LogLevel.info,
        'Unattended run: no background cache password yet; using the main wallet.',
      );
      return null;
    }

    final path = backgroundPathFor(await resolveWalletPath());
    // The `.keys` file, not the cache. That is the one `wallet2::load` cannot do
    // without; it carries the view key and is what the cache password decrypts.
    // A missing *cache* is recoverable and wallet2 recreates it; a missing keys
    // file means the open fails, and the honest fallback is the main wallet.
    if (!await File('$path.keys').exists()) {
      walletLog(LogLevel.warn, 'Unattended run: no background keys file; using the main wallet.');
      return null;
    }

    return (path: path, password: password);
  }

  /// Brings the background-sync configuration into line with the user's setting.
  ///
  /// Called from the open and restore paths, and by the app through
  /// [WalletManager.applyBackgroundSyncSettingAll] when the user changes the
  /// setting on an already-running app; without that second caller the
  /// configuration would not exist until the next launch, and a wake-up in
  /// between would quietly fall back to the main wallet while the UI said
  /// background sync was on.
  ///
  /// Both transitions are one-time: setting up writes the two background files
  /// and rewrites the main keys file; tearing down deletes them and stops every
  /// subsequent `store()` paying for a second cache write.
  ///
  /// Gated on the app's `backgroundSyncEnabled` preference, so an off-by-default
  /// feature costs nothing. Everything here is best-effort; a wallet that cannot
  /// configure background sync still syncs in the foreground rather than failing
  /// to open.
  @override
  Future<void> applyBackgroundSyncSetting({required String password}) async {
    // LWSF hardcodes a `ReusePassword` answer to `getBackgroundSyncType` and
    // implements none of the mechanism, so in LWS mode the call would report
    // success while doing nothing, and the answer it reports would make the
    // teardown branch below fire on every open.
    if (!_isNodeMode) return;

    final wallet = _wallet;
    if (wallet == null) return;

    // A background wallet cannot configure anything: `setup_background_sync`
    // refuses to run from an existing background cache, and an unattended run
    // holds no wallet password to do it with anyway.
    if (_isBackgroundWallet) return;

    try {
      final enabled =
          await SharedPreferencesService.get<bool>(SettingsKeys.backgroundSyncEnabled) ?? false;
      final configured = await _backend.getBackgroundSyncType(wallet);

      if (enabled == (configured == MoneroBackgroundSyncType.customPassword)) return;

      // Hold the timers off across the whole transition. `setup_background_sync`
      // deletes and rewrites the background trio *and* rewrites the main keys
      // file, and `WalletImpl::store` takes no lock at all; only
      // `setupBackgroundSync` takes `LOCK_REFRESH`; so a timer-driven `store()`
      // landing in the middle is two writers on the same files. Re-entrant, so
      // the connection-change rebuild can still call the open path inside its
      // own suspension.
      await runWithSyncSuspended(() async {
        if (enabled) {
          await _setUpBackgroundSync(wallet, password);
        } else {
          await _tearDownBackgroundSync(wallet, password);
        }
      });
    } catch (e) {
      walletLog(LogLevel.warn, 'background sync setup skipped: ${e.runtimeType}');
    }
  }

  Future<void> _setUpBackgroundSync(NativeHandle wallet, String walletPassword) async {
    // A fresh secret rather than Cake's empty string. The background cache
    // carries the private view key, so anyone who can read the file can see
    // every transaction this wallet has ever received; an empty password means a
    // key derived from nothing. The point of the separate password is that it
    // can be readable while the wallet password is not, not that it be absent.
    var cachePassword = await WalletSecrets.store.read(backgroundCachePasswordKey);
    if (cachePassword == null || cachePassword.isEmpty || cachePassword == walletPassword) {
      cachePassword = genWalletPassword();
      // Stored first. A cache written under a password we then failed to save is
      // a file nothing can ever open, and the recovery is a re-setup that
      // discards whatever it scanned.
      await WalletSecrets.store.write(backgroundCachePasswordKey, cachePassword);
    }

    // wallet2 throws outright when the two match, and `genWalletPassword` is 128
    // random bits, so this is a guard against a caller rather than against luck.
    if (cachePassword == walletPassword) {
      walletLog(LogLevel.error, 'background cache password matches the wallet password; skipping.');
      return;
    }

    final ok = await _backend.setupBackgroundSync(
      wallet,
      type: MoneroBackgroundSyncType.customPassword,
      walletPassword: walletPassword,
      backgroundCachePassword: cachePassword,
    );
    if (!ok) {
      final error = await _backend.walletErrorString(wallet);
      walletLog(LogLevel.warn, 'setupBackgroundSync failed: $error');
      return;
    }
    walletLog(LogLevel.info, 'View-only background cache configured.');
  }

  Future<void> _tearDownBackgroundSync(NativeHandle wallet, String walletPassword) async {
    // `Off` makes wallet2 delete the background wallet, keys and address files
    // and rewrite the main keys file without the derived background key, which
    // is also what stops every later `store()` writing a second cache.
    final ok = await _backend.setupBackgroundSync(
      wallet,
      type: MoneroBackgroundSyncType.off,
      walletPassword: walletPassword,
      // Ignored for `Off`, and it must not be the wallet password: the equality
      // check in `setup_background_sync` runs before the type is looked at.
      backgroundCachePassword: '',
    );
    if (!ok) {
      walletLog(LogLevel.warn, 'disabling background sync failed: ${await _walletError()}');
      return;
    }
    // Two secrets, two lifetimes. A password left behind for a cache that no
    // longer exists is a live key with nothing to protect.
    await WalletSecrets.store.delete(backgroundCachePasswordKey);
    walletLog(LogLevel.info, 'View-only background cache removed.');
  }

  Future<String> _walletError() async {
    final wallet = _wallet;
    if (wallet == null) return '';
    return _backend.walletErrorString(wallet);
  }

  @override
  Future<void> restoreFromSeed({
    required SeedSource seed,
    required RestorePoint from,
    required String password,
  }) async {
    checkSeedSupported(seed);
    await _restoreFromSeed(seed: seed, from: from, password: password);
  }

  /// Restore without the app-restore [SeedPolicy] gate. The LWS↔node rebuild
  /// recovers the other mode's file from the seed the wallet already holds,
  /// not a user importing an arbitrary seed, so `acceptedForRestore` must not
  /// apply. A BIP39-derived Monero wallet reads its own seed back as a 25-word
  /// legacy seed, which a BIP39-only policy would otherwise reject on a
  /// mode switch; the format is always one this coin supports.
  Future<void> _restoreFromSeed({
    required SeedSource seed,
    required RestorePoint from,
    required String password,
  }) async {
    if (password.isEmpty) throw Exception('Password should not be empty.');

    final restoreHeight = await _resolveRestoreHeight(seed, from);
    final isNewWallet = from is RestoreNewWallet;

    var wallet = await _buildFromSeed(
      seed: seed,
      restoreHeight: restoreHeight,
      password: password,
      isNewWallet: isNewWallet,
    );

    // wallet2 refuses to recover onto an existing wallet
    // file, which surfaces as an unexplained failure the user cannot get out
    // of. Reaching here means the seed itself was accepted (it is decoded before
    // the file is touched), so the mode's files can be cleared and the restore
    // retried. Not done when creating: there would be no seed in hand to
    // recover a clobbered file from.
    if (!isNewWallet &&
        (await _backend.walletErrorString(wallet)).contains('file already exists')) {
      walletLog(LogLevel.warn, 'Restore hit an existing wallet file; clearing and retrying.');
      await _deleteWalletFilesForCurrentMode();
      wallet = await _buildFromSeed(
        seed: seed,
        restoreHeight: restoreHeight,
        password: password,
        isNewWallet: isNewWallet,
      );
    }

    await _throwIfRestoreFailed(wallet);

    _wallet = wallet;
    _history = await _backend.history(wallet);
    _loadedKind = _desiredKind;

    if (!isNewWallet && restoreHeight > 0) {
      // wallet2's polyseed factory derives the scan start from
      // the seed's birthday and *drops the height it was handed*, so it has to
      // be applied afterwards. Without this a node-mode polyseed restore comes
      // up silently empty. LWSF's polyseed path honours the height once
      // newWallet is false, and both recoveryWallet implementations set it.
      if (seed.format == SeedFormat.polyseed && _isNodeMode) {
        walletLog(
          LogLevel.info,
          'Applying refresh-from height $restoreHeight after polyseed restore',
        );
        await _backend.setRefreshFromBlockHeight(wallet, restoreHeight);
      }

      // Fallback for getRestoreHeight(), which needs a height to rebuild the
      // other mode's file from the seed on an LWS↔node switch.
      await SharedPreferencesService.set<int>(prefKey('walletRestoreHeight'), restoreHeight);
    }

    // Same reason as in `openExisting`: a freshly created wallet lands on the
    // LWS-details screen before anything has connected.
    await loadPrimaryAddress();
    setIsLoaded(true);
    await store();

    // The new file has no background configuration; give it one if the user
    // wants it, rather than waiting for the next launch to notice.
    await applyBackgroundSyncSetting(password: password);
  }

  /// Where the scan should start.
  ///
  /// A 0 leaves wallet2's default, so the wallet scans from April 2014.
  ///
  /// - [RestoreNewWallet] has no history, so today's height is right.
  /// - [RestoreFromSeedBirthday] on a non-polyseed seed keeps its 0: BIP39 and
  ///   25-word phrases carry no birthday, and guessing too high skips the blocks
  ///   holding the user's funds and reports an empty wallet with no error. A
  ///   slow scan is the better failure; the caller must pass a date or height.
  Future<int> _resolveRestoreHeight(SeedSource seed, RestorePoint from) async => switch (from) {
    RestoreFromHeight(:final height) => height,
    RestoreFromDate(:final date) => getHeightByDate(date: date),
    RestoreNewWallet() => getHeightByDate(date: DateTime.now()),
    RestoreFromSeedBirthday() =>
      seed is PolyseedSeed ? getHeightByDate(date: seed.birthday) : _scanFromGenesisFor(seed),
  };

  int _scanFromGenesisFor(SeedSource seed) {
    walletLog(
      LogLevel.warn,
      'A ${seed.format.name} seed carries no birthday, so this restore scans from '
      'genesis. Pass a date or a height to avoid it.',
    );
    return 0;
  }

  /// Dispatches to the factory the seed's encoding needs.
  Future<NativeHandle> _buildFromSeed({
    required SeedSource seed,
    required int restoreHeight,
    required String password,
    required bool isNewWallet,
  }) async {
    final manager = await _walletManager();
    final path = await resolveWalletPath();

    switch (seed.format) {
      case SeedFormat.polyseed:
        // `newWallet` tells the backend the seed
        // has no history; with it set, both backends ignore the restore height.
        return _backend.createWalletFromPolyseed(
          manager,
          mnemonic: seed.mnemonic,
          seedOffset: seed.passphrase,
          restoreHeight: restoreHeight,
          path: path,
          password: password,
          newWallet: isNewWallet,
          kdfRounds: 1,
          networkType: networkType,
        );

      case SeedFormat.bip39:
        // Monero has no BIP39 entry point; convert to the equivalent legacy
        // word list first. Done off the UI isolate; mnemonicToSeed is PBKDF2.
        final mnemonic = seed.mnemonic;
        final passphrase = seed.passphrase;
        final legacy = await Isolate.run(
          () => getLegacySeedFromBip39(mnemonic, passphrase: passphrase),
        );
        return _backend.recoveryWallet(
          manager,
          mnemonic: legacy,
          seedOffset: '',
          restoreHeight: restoreHeight,
          password: password,
          path: path,
        );

      case SeedFormat.moneroLegacy:
        return _backend.recoveryWallet(
          manager,
          mnemonic: seed.mnemonic,
          seedOffset: seed.passphrase,
          restoreHeight: restoreHeight,
          password: password,
          path: path,
        );
    }
  }

  Future<void> _throwIfRestoreFailed(NativeHandle wallet) async {
    final error = await _backend.walletErrorString(wallet);

    // Restore fires an LWS rescan before connect, so a pre-connect networking
    // error is not a restore failure; the wallet file is written and the seed
    // was already accepted (decoded before the file is touched). "No response
    // from HTTP server" and "Invalid argument" are both this benign case, as is
    // a bare non-zero status with no message: that is the same cold-start artifact
    // (first restore on a fresh install), and load() recovers it. Genuine failures
    // always carry a message ("word list failed verification", "file already
    // exists"), handled below. Empty message ⇒ not fatal, regardless of status.
    const connectionErrors = ['No response from HTTP server', 'Invalid argument'];
    if (error.isEmpty || connectionErrors.any(error.contains)) return;

    if (error.contains('word list failed verification') ||
        error.contains('Failed polyseed decode')) {
      throw Exception('Invalid mnemonic.');
    }

    walletLog(LogLevel.error, 'Error restoring from seed: $error');
    throw Exception('Error restoring from seed: $error');
  }

  Future<void> _deleteWalletFilesForCurrentMode() async {
    final path = await resolveWalletPath();
    for (final p in _walletFilesFor(path)) {
      final file = File(p);
      if (await file.exists()) {
        // Deleting a wallet file is the most destructive thing here, so leave a
        // trace. Basename only: the full path carries the user's home directory.
        walletLog(LogLevel.warn, 'Removing wallet file before restore: ${p.split('/').last}');
        await file.delete();
      }
    }
  }

  /// Every file wallet2 writes for one wallet path, background cache included.
  ///
  /// The background trio is not optional to sweep. The main keys file carries
  /// the key the background cache is encrypted with, so a main file replaced
  /// without them leaves an orphaned cache holding this wallet's view key and
  /// the transactions it saw; with nothing that will ever open it again to
  /// notice.
  static List<String> _walletFilesFor(String path) {
    final background = backgroundPathFor(path);
    return [
      path,
      '$path.keys',
      '$path.address.txt',
      background,
      '$background.keys',
      '$background.address.txt',
    ];
  }

  @override
  Future<bool> needsRebuildForCurrentConnection() async =>
      _wallet != null && _loadedKind != _desiredKind;

  /// Applies a connection change from the settings form. The predicate above
  /// detects that a rebuild is needed; this performs it.
  @override
  Future<void> applyConnectionChange({required String password}) async {
    if (await needsRebuildForCurrentConnection()) {
      // Hold the refresh/connection timers off while the native wallet is closed
      // and reopened: a timer-driven store() racing the close is a use-after-free.
      await runWithSyncSuspended(() => _rebuildForConnectionType(password));
    }
    await load();
  }

  /// Re-opens the wallet for the newly-selected mode.
  ///
  /// The two modes keep separate cache files sharing the same keys. If the
  /// target file doesn't exist yet it is recovered from the open wallet's seed;
  /// which must be read out *before* the old wallet is closed.
  Future<void> _rebuildForConnectionType(String password) async {
    final open = _wallet;
    if (open == null) return;

    // Extract the seed while the old-mode wallet is still open.
    final polyseed = await _backend.getPolyseed(open);
    final legacy = await _backend.seed(open);
    final mnemonic = polyseed.isNotEmpty ? polyseed : legacy;
    final restoreHeight = await getRestoreHeight();

    final seed = polyseed.isNotEmpty ? PolyseedSeed(mnemonic) : MoneroLegacySeed(mnemonic);

    // Leaving node mode: dismantle the background configuration while the wallet
    // that owns it is still open and its password is in hand. The files belong
    // to the node-mode wallet file, and LWSF neither writes nor reads them, so
    // left in place they are an orphaned copy of this wallet's view key and the
    // transactions it saw. `_applyBackgroundSyncSetting` mints a fresh cache if
    // and when node mode comes back.
    if (_loadedKind == MoneroManagerKind.node && _desiredKind == MoneroManagerKind.lws) {
      if (await _backend.getBackgroundSyncType(open) == MoneroBackgroundSyncType.customPassword) {
        await _tearDownBackgroundSync(open, password);
      }
    }

    _daemonTargetHeight = null;
    _lastDaemonHeightFetch = null;

    final targetPath = await resolveWalletPath();
    if (await File(targetPath).exists()) {
      // Close the old wallet first; _walletManager() swaps factory on demand.
      await _closeOpenWallet();
      await openExisting(password: password);
      return;
    }

    // Recover the target-mode file from the shared seed. The *existing*
    // password must be reused; minting a new one would desync the two mode
    // files permanently, since each is encrypted with its own. Skips the
    // app-restore policy: the seed came from this wallet, not the user, so a
    // BIP39-derived wallet reading back as legacy must not be rejected here.
    await _closeOpenWallet();
    await _restoreFromSeed(
      seed: seed,
      from: RestorePoint.height(restoreHeight),
      password: password,
    );
  }

  Future<void> _closeOpenWallet() async {
    final wallet = _wallet;
    final manager = _manager;
    if (wallet == null || manager == null) return;
    await _backend.closeWallet(manager, wallet, store: false);
    _wallet = null;
    _history = null;
    _loadedKind = null;
    _daemonInitialised = false;
    _reportedSynchronized = false;
    _isBackgroundWallet = false;
    // Keyed on the handle, and a freed handle's address can be reused by the
    // next allocation. Cake keys its equivalent cache on the FFI address alone
    // and never clears it, which is one allocator reuse away from serving a
    // closed wallet's transaction keys.
    _txKeyCache.clear();
  }

  @override
  Future<bool> store() async {
    final wallet = _wallet;
    if (wallet == null) return false;
    return _backend.store(wallet);
  }

  /// Stops the native scan thread so [pauseSyncAndStore] can checkpoint.
  @override
  Future<void> pauseSync() async {
    final wallet = _wallet;
    if (wallet == null || !_daemonInitialised) return;
    await _backend.pauseRefresh(wallet);
  }

  @override
  Future<void> deleteFiles() async {
    await _closeOpenWallet();

    // Remove both modes' files plus the companion `.keys` / `.address.txt`.
    final current = await resolveWalletPath();
    final lwsBase = current.endsWith('_node')
        ? current.substring(0, current.length - '_node'.length)
        : current;

    for (final base in {lwsBase, '${lwsBase}_node'}) {
      for (final p in _walletFilesFor(base)) {
        final file = File(p);
        if (await file.exists()) await file.delete();
      }
    }
  }

  @override
  Future<void> clearPersistedState() async {
    await super.clearPersistedState();
    for (final key in [
      'serverSupportsSubaddresses',
      'unusedSubaddressIndex',
      'unusedSubaddressIndexIsSupported',
    ]) {
      await SharedPreferencesService.remove(prefKey(key));
    }
    // Two secrets, two lifetimes (`background-sync.md`). A deleted wallet that
    // leaves this behind leaves a live key in the keystore, and the next wallet
    // on this device inherits it; `_setUpBackgroundSync` reuses a stored
    // password, so a stranger's cache password would end up encrypting a cache
    // holding this wallet's view key.
    await WalletSecrets.store.delete(backgroundCachePasswordKey);
    // The connection settings (address + type + tor/ssl/port) are intentionally
    // kept: deleting the wallet should not wipe them, so the connection-setup
    // screen recalls the previous mode and server. Wiping only `connectionType`
    // here used to leave a node address stranded under the LWS default.
    _serverSupportsSubaddresses = null;
    _unusedSubaddressIndex = null;
    _unusedSubaddressIndexIsSupported = null;
    _primaryAddress = '';
    _subaddressCache = null;
  }

  @override
  void dispose() {
    // Close the native wallet so its decrypted keys and background threads
    // aren't left behind. Skylight never does this.
    final wallet = _wallet;
    final manager = _manager;
    if (wallet != null && manager != null) {
      unawaited(_backend.closeWallet(manager, wallet, store: false));
      _wallet = null;
      _history = null;
      // Cleared with the wallet, not left dangling. Skylight's
      // `needsRebuildForCurrentConnection` carries an extra `_loadedType != null`
      // guard; it is redundant *only* while every path that
      // nulls the wallet also nulls this, and this one did not.
      _loadedKind = null;
      _daemonInitialised = false;
      // Same reasoning as above, applied to the two fields added since: both are
      // properties of the handle that was just freed.
      _isBackgroundWallet = false;
      _txKeyCache.clear();
    }
    super.dispose();
  }

  // ----- Daemon -----

  /// Whether a bare `host:port` daemon address must use https.
  ///
  /// The address carries no scheme, so it is prefixed to parse the host out;
  /// `Uri.host` strips the port and any IPv6 brackets. A routable host is forced
  /// secure; an onion or local one is left plaintext, since it is already
  /// confidential without TLS.
  static bool _addressRequiresSsl(String address) =>
      requiresSecureTransport(Uri.parse('http://$address').host);

  @override
  Future<void> connectToDaemonImpl({required String address, String? proxyPort}) async {
    final wallet = _wallet;
    if (wallet == null) throw Exception('No open Monero wallet.');

    // The open wallet is bound to the factory of the mode it was opened in.
    // Connecting before the manager is rebuilt would call Wallet_init with a
    // mismatched lightWallet flag and abort.
    if (_loadedKind != _desiredKind) {
      walletLog(
        LogLevel.warn,
        'Skipping connect: loaded as "$_loadedKind" but connection needs "$_desiredKind"',
      );
      return;
    }

    if (Platform.isAndroid) {
      // Android's system CA store isn't visible to the bundled OpenSSL.
      final cacert = await getCacertFile();
      await _backend.setCaFilePath(wallet, cacert.path);
    }

    // There is no user SSL toggle: a routable clearnet host is forced to https; a
    // local or onion host, already confidential without TLS, stays http.
    final useSsl = _addressRequiresSsl(address);
    final daemonAddress = '${useSsl ? 'https://' : 'http://'}$address';
    final proxyAddress = (proxyPort != null && proxyPort.isNotEmpty) ? '127.0.0.1:$proxyPort' : '';

    // Extra check to require Tor or a SOCKS proxy for LWS connections since they
    // carry the view key
    if (!_isNodeMode) {
      requireConfidentialChannel(
        Uri.parse(daemonAddress),
        carrying: 'the private view key',
        viaTor: proxyPort != null && proxyPort.isNotEmpty,
      );
    }

    walletLog(LogLevel.info, 'Connecting: ssl=$useSsl lightWallet=${!_isNodeMode}');

    await _backend.init(
      wallet,
      daemonAddress: daemonAddress,
      proxyAddress: proxyAddress,
      useSsl: useSsl,
      lightWallet: !_isNodeMode,
    );
    await _backend.connectToDaemon(wallet);

    // A full node also needs its background refresh thread started; LWS lets
    // the server scan.
    if (_isNodeMode) {
      await _backend.setAutoRefreshInterval(wallet, 10000);
      await _backend.startRefresh(wallet);
    }

    _daemonInitialised = true;

    final error = await _backend.walletErrorString(wallet);
    if (error.isNotEmpty) walletLog(LogLevel.warn, 'connectToDaemon error: $error');
  }

  @override
  Future<void> testConnection({
    required String address,
    String? proxyPort,
    required bool useTor,
    String connectionType = '',
  }) async {
    final isNode = connectionType == 'node';
    final path = isNode ? '/get_height' : '/get_address_info';
    // Same derivation as the live connect: https for a routable host, plaintext
    // only for an onion or local one.
    final useSsl = _addressRequiresSsl(address);
    final url = '${useSsl ? 'https' : 'http'}://$address$path';

    // Require Tor or a SOCKS proxy for .onion connection setup
    final viaProxy = useTor || (proxyPort != null && proxyPort.isNotEmpty);
    if (isUnroutedOnion(address, viaProxy: viaProxy)) {
      throw Exception('An onion address needs Tor. Please go back and enable it.');
    }

    walletLog(LogLevel.info, 'Probing ${isNode ? 'node' : 'LWS'} (tor=$useTor)');

    late int statusCode;
    String body = '';

    if (useTor) {
      final torSettings = TorSettingsService.sharedInstance;
      if (torSettings.torMode == TorMode.disabled) {
        throw Exception('Tor is disabled. Please go back and enable it.');
      }
      final proxyInfo = await torSettings.getProxy();
      if (proxyInfo == null) throw Exception('Could not resolve a Tor proxy.');

      final response = await makeSocksHttpRequest(
        isNode ? 'GET' : 'POST',
        url,
        proxyInfo,
        maxBytes: maxProbeResponseBytes,
        timeout: const Duration(seconds: 20),
      );
      statusCode = response.statusCode;
      body = response.body;
    } else {
      final client = HttpClient();
      if (proxyPort != null && proxyPort.isNotEmpty) {
        client.findProxy = (_) => 'SOCKS localhost:$proxyPort';
      }
      try {
        final request = isNode
            ? await client.getUrl(Uri.parse(url))
            : await client.postUrl(Uri.parse(url));
        final response = await request.close().timeout(const Duration(seconds: 10));
        statusCode = response.statusCode;
        // Bounded and given a deadline of its own: the audit found this read had
        // neither. It is a connection *probe* against an address the user has
        // just typed and has no reason to trust yet; the one read most likely
        // to be pointed at something hostile, and the one that had no limit.
        if (isNode) {
          body = await readBoundedBody(
            response,
            maxBytes: maxProbeResponseBytes,
            timeout: const Duration(seconds: 10),
          );
        }
      } finally {
        client.close(force: true);
      }
    }

    if (isNode) {
      // A real monerod replies 200 with a JSON body carrying a height.
      if (statusCode != HttpStatus.ok) {
        throw Exception('Unexpected status $statusCode from the node');
      }
      if (!looksLikeMoneroNodeBody(body)) {
        throw Exception('That address did not respond like a Monero node.');
      }
      return;
    }

    // LWS answers an unauthenticated POST to /get_address_info with 500.
    // Anything else means it isn't a real LWS endpoint.
    if (statusCode != HttpStatus.internalServerError) {
      throw Exception('Unexpected status $statusCode from the LWS server');
    }
  }

  /// True when [body] is a `/get_height` response from a monerod.
  ///
  /// Pulled out of [testConnection] so it is testable without an HTTP seam,
  /// which is where the bug was: the port decoded with a bare `jsonDecode`, so a
  /// 200 that isn't JSON; a captive portal, a reverse proxy, a web server
  /// sitting on 18081; surfaced a raw `FormatException` instead of the sentence
  /// telling the user their address is not a node. Both apps guard the decode.
  ///
  /// The `is! int` check is stricter than either app, which accepted any non-null
  /// `height`: a string there means it is not a monerod.
  @visibleForTesting
  static bool looksLikeMoneroNodeBody(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return false;
    }
    return decoded is Map<String, dynamic> && decoded['height'] is int;
  }

  @override
  Future<bool> getIsConnected() async {
    final wallet = _wallet;
    if (wallet == null || !_daemonInitialised) return false;
    return await _backend.connected(wallet) != 0;
  }

  @override
  Future<void> refresh() async {
    final wallet = _wallet;
    if (wallet == null || !_daemonInitialised) return;

    if (_isNodeMode) {
      // Nudge the background scan thread rather than scanning here. Both apps do
      // this and the distinction is not cosmetic: `Wallet_refresh` is a blocking
      // one-shot that takes the wallet lock, so calling it on the 20s cycle
      // reintroduces exactly the contention `deferStatsUntilSynced` exists to
      // avoid. It also has to be *here* and not only at connect;
      // `pauseSync()` stops the thread for a background checkpoint, and nothing
      // else would ever start it again.
      await _backend.startRefresh(wallet);
      return;
    }

    // LWS: the server does the scanning, so this is a cheap local read.
    await _backend.refresh(wallet);
  }

  @override
  Future<void> loadIsSynced() async {
    final wallet = _wallet;
    if (wallet == null || !_daemonInitialised) return;
    _applySyncedFlag(await _backend.synchronized(wallet));
  }

  @override
  Future<void> loadSyncedHeight() async {
    final wallet = _wallet;
    if (wallet == null || !_daemonInitialised) return;
    setSyncedHeight(await _backend.blockChainHeight(wallet));
    _refreshDaemonHeightIfBehind();
  }

  /// Keeps the daemon's height fresh enough for "blocks remaining", without ever
  /// making the caller wait for it.
  ///
  /// Two changes from awaiting it on a 30-second clock. It is **not awaited**;
  /// this ran inside `loadSyncedHeight`, on the poll the user is watching, and
  /// `Wallet_daemonBlockChainHeight` is a real RPC over whatever the connection
  /// is, Tor included. And it refetches when the *scan catches up* to the cached
  /// value rather than on a timer, so a fresh figure arrives exactly when the
  /// old one has stopped being an upper bound, and no request is made while the
  /// scan is still hours behind. Cake's `getNodeHeightOrUpdate` has the same
  /// shape and the same fire-and-forget.
  ///
  /// The interval survives as a backstop, so a chain that overtakes the wallet
  /// while it sits synced still updates.
  void _refreshDaemonHeightIfBehind() {
    if (!_isNodeMode || _daemonHeightFetchInFlight) return;

    final now = DateTime.now();
    final scanned = syncedHeight ?? 0;
    final cached = _daemonTargetHeight;
    final caughtUp = cached == null || scanned >= cached;
    final stale =
        _lastDaemonHeightFetch == null ||
        now.difference(_lastDaemonHeightFetch!) > _daemonHeightBackstop;
    if (!caughtUp && !stale) return;

    _lastDaemonHeightFetch = now;
    final future = _fetchDaemonHeight();
    _daemonHeightFetch = future;
    unawaited(future.whenComplete(() => _daemonHeightFetch = null));
  }

  Future<void> _fetchDaemonHeight() async {
    try {
      final wallet = _wallet;
      if (wallet == null || !_daemonInitialised) return;
      final height = await _backend.daemonBlockChainHeight(wallet);
      if (height > 0) {
        _daemonTargetHeight = height;
        // Re-decide now that there is something to compare against, rather than
        // leaving a wrong "synced" up until the next poll.
        _applySyncedFlag(_reportedSynchronized);
        notifyListeners();
      }
    } catch (e) {
      walletLog(LogLevel.warn, 'daemon height fetch failed: ${e.runtimeType}');
    }
  }

  Future<void>? _daemonHeightFetch;

  /// The in-flight daemon-height fetch, or null.
  ///
  /// Exposed because the fetch is deliberately *not* awaited by its caller: a
  /// test reading [syncBlocksRemaining] straight after `loadSyncedHeight()`
  /// would otherwise be racing it, and pumping the event loop for an unbounded
  /// number of turns is not an assertion. Awaiting this is.
  @visibleForTesting
  Future<void>? get daemonHeightFetch => _daemonHeightFetch;

  bool get _daemonHeightFetchInFlight => _daemonHeightFetch != null;

  static const _daemonHeightBackstop = Duration(minutes: 2);

  @override
  Future<void> loadUnlockedBalance() async {
    final wallet = _wallet;
    if (wallet == null || !_daemonInitialised) return;
    setUnlockedBalanceBaseUnits(await _backend.unlockedBalance(wallet));
  }

  @override
  Future<void> loadTotalBalance() async {
    final wallet = _wallet;
    if (wallet == null || !_daemonInitialised) return;
    setTotalBalanceBaseUnits(await _backend.balance(wallet));
  }

  @override
  Future<int> getCurrentHeight() async => _backend.blockchainHeight(await _walletManager());

  @override
  Future<int> getRestoreHeight() async {
    final wallet = _wallet;
    if (wallet != null) {
      final height = await _backend.getRefreshFromBlockHeight(wallet);
      if (height > 0) return height;
    }
    // Fallback for rebuilding the other mode's file from the seed on an
    // LWS↔node switch, where the backend reports 0.
    return await SharedPreferencesService.get<int>(prefKey('walletRestoreHeight')) ?? 0;
  }

  /// Node-only: sync state flips on a native background thread,
  /// so it is polled here rather than waiting for the 20s refresh cycle. When it
  /// has just caught up, pull fresh stats immediately.
  ///
  /// One hop for both figures rather than two, and it tells nobody when nothing
  /// moved. Every `notifyListeners()` here reaches `WalletManager`, which
  /// debounces into a rebuild of every screen watching it; on a 3-second tick
  /// during a multi-hour scan that is a rebuild every 3 seconds to redraw
  /// identical numbers. Cake's tick opens with the same check.
  /// monero_c's `Wallet_synchronized`, narrowed by what the heights say.
  ///
  /// The flag is raised once the refresh thread has completed a pass, which in
  /// node mode is not the same as the scan having reached the chain -- and a
  /// wallet rebuilt for an LWS->node switch sits at its restore height when it
  /// first goes up. Reporting "Synced" there is untrue, and it also hides the
  /// evidence: [syncBlocksRemaining] returns null once synced, so the block
  /// countdown that would have contradicted it disappears too.
  ///
  /// Only ever demotes, and only on positive evidence. An unknown daemon height
  /// leaves the flag as reported, so a node whose height read fails still
  /// reaches "synced" exactly as before.
  bool _syncedGivenHeights(bool reported) {
    if (!reported || !_isNodeMode) return reported;
    final target = _daemonTargetHeight;
    final scanned = syncedHeight;
    if (target == null || scanned == null) return true;
    return scanned >= target;
  }

  void _applySyncedFlag(bool reported) {
    _reportedSynchronized = reported;
    setIsSynced(_syncedGivenHeights(reported));
  }

  @override
  Future<void> pollSyncStatus() async {
    final wallet = _wallet;
    if (!_isNodeMode || wallet == null || !_daemonInitialised) return;

    final wasSynced = isSynced;
    final previousHeight = syncedHeight;

    final stats = await _backend.walletStats(wallet);
    // Height first: the narrowing in [_applySyncedFlag] reads it.
    setSyncedHeight(stats.blockChainHeight);
    _applySyncedFlag(stats.synchronized);
    _refreshDaemonHeightIfBehind();

    if (isSynced != wasSynced || stats.blockChainHeight != previousHeight) {
      notifyListeners();
    }

    if (!wasSynced && isSynced) await loadAllStats();
  }

  // ----- Transactions -----

  @override
  List<TxDetails> readTxHistory() {
    // The base calls this synchronously; the history is read asynchronously
    // into _cachedHistory by [refreshTxHistory].
    return _cachedHistory;
  }

  List<TxDetails> _cachedHistory = const [];

  /// Transaction secret keys already fetched, by hash.
  ///
  /// Cleared with the wallet ([_closeOpenWallet]) and on commit, and never
  /// keyed on the native address; see the notes at both sites.
  final Map<String, String> _txKeyCache = {};

  /// Serialises [refreshTxHistory].
  ///
  /// It is reachable concurrently from three paths guarded by *different*
  /// in-flight flags; `refreshTask`→`loadAllStats` under `_refreshInFlight`,
  /// `pollSyncStatus`→`loadAllStats` on the sync transition under
  /// `_connectionCheckInFlight`, and `_retryConnectIfDue()`→`loadAllStats`
  /// **unawaited** under nothing at all; so no single one of those flags covers
  /// it. Two overlapping reads interleave index reads on one native history
  /// object and assign [_cachedHistory] twice. Cake guards the same thing with a
  /// mutex plus a re-entry flag.
  Future<void>? _historyRefreshInFlight;

  /// Reads the transaction list out of the wallet's own cache.
  Future<void> refreshTxHistory() async {
    // Join an in-flight read rather than starting a second one: the callers all
    // want "the history is now up to date", and the second read would return the
    // same answer having fought the first for the native object.
    final existing = _historyRefreshInFlight;
    if (existing != null) return existing;

    final future = _refreshTxHistoryOnce();
    _historyRefreshInFlight = future;
    try {
      await future;
    } finally {
      _historyRefreshInFlight = null;
    }
  }

  Future<void> _refreshTxHistoryOnce() async {
    final history = _history;
    final wallet = _wallet;
    if (history == null || wallet == null) return;

    await _backend.historyRefresh(history);

    // One isolate hop for the whole list, with the keys we already hold passed
    // in. A background wallet is asked for no keys at all: `WalletImpl::getTxKey`
    // refuses the call there and writes the refusal onto the wallet's *global*
    // error status, which `openExisting` and the restore paths read.
    final infos = await _backend.historyTransactions(
      wallet,
      history,
      knownTxKeys: _txKeyCache,
      withTxKeys: !_isBackgroundWallet,
    );

    final out = <TxDetails>[];
    for (var i = 0; i < infos.length; i++) {
      final info = infos[i];
      _rememberTxKey(info);
      out.add(
        TxDetails(
          index: i,
          direction: info.direction,
          hash: info.hash,
          amountBaseUnits: info.amount,
          feeBaseUnits: info.fee,
          recipients: await _recipientsFor(wallet, info),
          accountIndex: info.subaddrAccount,
          subaddrIndexList: info.subaddrIndex
              .split(',')
              .map((s) => int.tryParse(s.trim()))
              .whereType<int>()
              .toList(),
          timestamp: info.timestamp,
          height: info.blockHeight,
          confirmations: info.confirmations,
          // The transaction secret key, which is what both apps put here and
          // what Skylight's transaction screen offers the user to copy. It was
          // `paymentId`, a different value that proves nothing.
          key: info.txKey,
        ),
      );
    }

    // Newest first, matching what the UI expects.
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    _cachedHistory = out;
  }

  /// Caches [info]'s transaction key, including the *absence* of one, but not
  /// unconditionally.
  ///
  /// Caching a miss is what makes this worth having: an incoming transaction
  /// never has a key, so without it every incoming transaction is re-asked
  /// every cycle forever, and each miss makes wallet2 write "no tx keys found
  /// for this txid" onto the wallet's global error status. Cake had to
  /// whitelist that exact string at an unrelated call site because of it.
  ///
  /// But "written at construction time, never appears later" describes a
  /// restored wallet, not the API. A transient miss; the wallet busy, a status
  /// error left by an unrelated call, a transaction whose key has not reached
  /// the store yet; cached as permanent loses the transaction secret key,
  /// which is exactly what a user needs to prove a payment. So an outgoing
  /// transaction with no confirmations is never negative-cached: it is the one
  /// case where the key is expected to arrive shortly, and it is the case a
  /// user is most likely to ask about. (Cake caches it anyway; this is a
  /// deliberate divergence.) [commitTx] clears the cache for the same reason.
  void _rememberTxKey(NativeTxInfo info) {
    if (_isBackgroundWallet) return;
    if (info.txKey.isEmpty && info.direction == txDirectionOutgoing && info.confirmations == 0) {
      return;
    }
    _txKeyCache[info.hash] = info.txKey;
  }

  /// Who a transaction paid, or which of our addresses received it.
  ///
  /// Monero does not put this on the chain in a form a wallet can read back, so
  /// the two directions come from different places:
  ///
  ///  - **Outgoing**: the destinations the wallet recorded when it built the
  ///    transaction. Empty for one sent from another device on the same seed,
  ///    because there is nothing to recover them from.
  ///  - **Incoming**: derived from the subaddress the funds landed on, which is
  ///    the receiving address the sender was given.
  Future<List<TxRecipient>> _recipientsFor(NativeHandle wallet, NativeTxInfo info) async {
    if (info.direction == txDirectionOutgoing) {
      return [for (final d in info.destinations) TxRecipient(d.address, d.amount)];
    }

    // An incoming transaction can credit more than one subaddress; the amount
    // per subaddress is not broken out, so the whole amount is reported against
    // the first one rather than invented per address.
    final indices = info.subaddrIndex
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toList();
    if (indices.isEmpty) return const [];

    final address = await _backend.address(
      wallet,
      accountIndex: info.subaddrAccount,
      addressIndex: indices.first,
    );
    if (address.isEmpty) return const [];
    return [TxRecipient(address, info.amount)];
  }

  @override
  Future<void> loadTxHistory({bool persistCount = true}) async {
    await refreshTxHistory();
    await super.loadTxHistory(persistCount: persistCount);
  }

  @override
  String getPrimaryAddress() => _primaryAddress;
  String _primaryAddress = '';

  /// Caches the primary address; the base's [getPrimaryAddress] is synchronous.
  Future<void> loadPrimaryAddress() async {
    final wallet = _wallet;
    if (wallet == null) return;
    _primaryAddress = await _backend.address(wallet);
  }

  /// The wallet's private view key, or empty when no wallet is open.
  ///
  /// Surfaced for one screen: a light-wallet server has to be given this key to
  /// scan for the wallet, so an LWS user must be able to read it out of the app
  /// and hand it over. That is the only legitimate reason to expose it, and the
  /// FFI seam otherwise keeps it out of reach; before the seam existed the app
  /// reached through to the native wallet object for it, from `build()`.
  ///
  /// **Never log the return value**, not truncated, not fingerprinted
  /// Never log it. It is not a spend key, but anyone holding it
  /// sees every transaction this wallet has ever received.
  ///
  /// Deliberately not cached. The primary address is public and gets a field;
  /// this is read on demand so it is not sitting in the object between the two
  /// moments a user asks for it.
  Future<String> readSecretViewKey() async {
    final wallet = _wallet;
    if (wallet == null) return '';
    return _backend.secretViewKey(wallet);
  }

  Future<String> readSecretSpendKey() async {
    final wallet = _wallet;
    if (wallet == null) return '';
    return _backend.secretSpendKey(wallet);
  }

  Future<String> readPublicViewKey() async {
    final wallet = _wallet;
    if (wallet == null) return '';
    return _backend.publicViewKey(wallet);
  }

  Future<String> readPublicSpendKey() async {
    final wallet = _wallet;
    if (wallet == null) return '';
    return _backend.publicSpendKey(wallet);
  }

  /// The 25-word legacy (electrum) seed. Present for any wallet; a bip39/
  /// polyseed origin is not recoverable from it (see readPolyseed / SeedStore).
  Future<String> readLegacySeed() async {
    final wallet = _wallet;
    if (wallet == null) return '';
    return _backend.seed(wallet);
  }

  Future<String> readPolyseed() async {
    final wallet = _wallet;
    if (wallet == null) return '';
    return _backend.getPolyseed(wallet);
  }

  @override
  String? getReceiveAddress() {
    // A fresh subaddress per payment is the whole point of subaddresses; fall
    // back to the primary only when the server can't serve them.
    final index = _unusedSubaddressIndex;
    if (_serverSupportsSubaddresses == true && index != null && _subaddressCache != null) {
      return _subaddressCache;
    }
    return _primaryAddress.isEmpty ? null : _primaryAddress;
  }

  String? _subaddressCache;

  /// The next unused subaddress, or null when the server can't serve them.
  /// Unlike [getReceiveAddress] there is no primary-address fallback; the
  /// receive screen toggles between this and the primary itself.
  String? getUnusedSubaddress() {
    final index = _unusedSubaddressIndex;
    if (_serverSupportsSubaddresses == true && index != null) return _subaddressCache;
    return null;
  }

  /// The network this wallet's addresses belong to.
  ///
  /// Both apps ship Monero mainnet only. Named so the wallet factory and the
  /// address validator cannot disagree about it.
  int get networkType => MoneroConsts.mainnetNetworkType;

  @override
  bool isAddressValid(String address) {
    if (address.isEmpty) return false;
    return _backend.addressValid(address, networkType);
  }

  /// `Wallet_estimateTransactionFee` exists only in `magicgrants/monero_c`,
  /// which is why the build pins that fork.
  @override
  Future<BigInt?> estimateFee(
    String destinationAddress,
    BigInt amountBaseUnits, {
    int priority = 0,
  }) async {
    final wallet = _wallet;
    if (wallet == null) return null;
    try {
      return await _backend.estimateTransactionFee(
        wallet,
        destinations: [destinationAddress],
        amounts: [amountBaseUnits],
        priority: priority,
      );
    } catch (e) {
      walletLog(LogLevel.warn, 'estimateFee failed: $e');
      return null;
    }
  }

  @override
  Future<PendingTransaction> createTx(
    String destinationAddress,
    BigInt amountBaseUnits,
    bool isSweepAll, {
    int priority = 0,
  }) async {
    final wallet = _wallet;
    if (wallet == null) throw Exception('No open Monero wallet.');

    // Amount and destination are never logged.
    walletLog(
      LogLevel.info,
      'Creating tx to ${Redact.id(destinationAddress)} '
      '${Redact.amount(amountBaseUnits)} sweep=$isSweepAll',
    );

    // The fee is wallet2's, chosen inside monero_c from `priority` and the
    // daemon's own estimate. Nothing in Dart picks it and nothing here bounds
    // it. It comes back on the pending-tx handle and is reported as
    // `feeBaseUnits` for the application to show and judge.
    final handle = await _backend.createTransaction(
      wallet,
      destinations: [destinationAddress],
      amounts: [amountBaseUnits],
      isSweepAll: isSweepAll,
      mixinCount: MoneroConsts.mixinCount,
      priority: priority,
    );

    final error = await _backend.pendingTxErrorString(handle);
    if (error.isNotEmpty) {
      walletLog(LogLevel.error, 'Failed to create transaction: $error');
      throw Exception(error);
    }

    return MoneroPendingTransaction(
      handle: handle,
      amountBaseUnits: await _backend.pendingTxAmount(handle),
      feeBaseUnits: await _backend.pendingTxFee(handle),
    );
  }

  @override
  Future<void> commitTx(PendingTransaction tx, String destinationAddress) async {
    final pending = tx as MoneroPendingTransaction;

    final committed = await _backend.commitPendingTx(pending.handle);
    final status = await _backend.pendingTxStatus(pending.handle);
    final error = await _backend.pendingTxErrorString(pending.handle);

    if (error.isNotEmpty && error != 'Schema expected string') {
      walletLog(LogLevel.error, 'commit error: $error');
      throw FormatException(error);
    }

    // A broadcast can fail without setting errorString, so success is gated on
    // the commit result and status too; otherwise a send that never happened
    // is reported as done. Both apps have this fix; it is not optional.
    if (!committed || status != 0) {
      walletLog(LogLevel.error, 'commit failed: result=$committed status=$status');
      throw const FormatException('Failed to broadcast transaction.');
    }

    // The wallet just gained a transaction key that did not exist a moment ago,
    // and any negative entry for this hash; recorded before the send, or by a
    // read that raced it; would now be wrong and permanent. The key is what
    // proves this payment to its recipient, so the cache is dropped rather than
    // patched.
    _txKeyCache.clear();

    await refresh();
    // Persist so the just-sent unconfirmed tx; held in the wallet's cache, not
    // on chain yet; survives a restart before it is mined.
    await store();
    await Future.wait([loadTotalBalance(), loadUnlockedBalance()]);
    await loadTxHistory();
    notifyListeners();
    // Refresh the encrypted display snapshot too, so the pending transaction and
    // the reduced balance are on screen the moment the app reopens rather than
    // after the next sync.
    //
    // `persistWalletSnapshot()` only marks the cache dirty, so it would depend
    // on surviving until the next `loadAllStats`, which an app killed right
    // after a send does not. Flushed here, next to the `store()` above.
    await persistWalletSnapshot();
    await persistCache();
  }

  // ----- Subaddresses -----

  Future<void> loadPersistedSubaddressState() async {
    _serverSupportsSubaddresses = await SharedPreferencesService.get<bool>(
      prefKey('serverSupportsSubaddresses'),
    );
    _unusedSubaddressIndex = await SharedPreferencesService.get<int>(
      prefKey('unusedSubaddressIndex'),
    );
    _unusedSubaddressIndexIsSupported = await SharedPreferencesService.get<bool>(
      prefKey('unusedSubaddressIndexIsSupported'),
    );
  }

  Future<void> setUnusedSubaddressIndex(int? index, {bool? isSupported}) async {
    _unusedSubaddressIndex = index;
    if (index == null) {
      await SharedPreferencesService.remove(prefKey('unusedSubaddressIndex'));
    } else {
      await SharedPreferencesService.set<int>(prefKey('unusedSubaddressIndex'), index);
    }

    if (isSupported != null) {
      _unusedSubaddressIndexIsSupported = isSupported;
      await SharedPreferencesService.set<bool>(
        prefKey('unusedSubaddressIndexIsSupported'),
        isSupported,
      );
    }

    // After both fields are settled, because the address depends on each.
    await _refreshSubaddressCache();
    notifyListeners();
  }

  Future<void> setServerSupportsSubaddresses(bool value) async {
    _serverSupportsSubaddresses = value;
    await SharedPreferencesService.set<bool>(prefKey('serverSupportsSubaddresses'), value);
    notifyListeners();
  }

  /// The address index [getReceiveAddress] should hand out, or null.
  ///
  /// When the server could not provision the next index, fall back one; that is
  /// the highest index it *did* accept, so it is the newest address the server
  /// will actually scan. Handing out an unprovisioned subaddress means the
  /// payment arrives and the light-wallet server never reports it.
  int? get _effectiveSubaddressIndex {
    final index = _unusedSubaddressIndex;
    if (index == null) return null;
    return _unusedSubaddressIndexIsSupported == false ? index - 1 : index;
  }

  /// Resolves the current subaddress once, so the synchronous
  /// [getReceiveAddress] has something to return.
  Future<void> _refreshSubaddressCache() async {
    final wallet = _wallet;
    final index = _effectiveSubaddressIndex;
    if (wallet == null || index == null || index < 0) {
      _subaddressCache = null;
      return;
    }
    _subaddressCache = await _backend.address(wallet, accountIndex: 0, addressIndex: index);
  }

  /// Whether this server can serve subaddresses at all.
  ///
  /// A full node scans locally and always can. An LWS server has to be asked,
  /// and the answer is cached in prefs because the probe costs a round trip that
  /// carries the view key.
  Future<void> loadSubaddressSupport() async {
    if (_isNodeMode) {
      await setServerSupportsSubaddresses(true);
      return;
    }

    try {
      await setServerSupportsSubaddresses(await isSubaddressSupported(1));
    } catch (e) {
      // Best-effort: a server that cannot answer leaves the flag as it was, and
      // getReceiveAddress falls back to the primary address.
      walletLog(LogLevel.warn, 'subaddress support probe failed: ${e.runtimeType}');
    }
  }

  /// Finds the lowest subaddress index nothing has been received on, and asks
  /// the server to provision it.
  ///
  /// "Used" means it appears in the transaction history. Handing out a fresh
  /// index per payment is the whole point of subaddresses; reusing one links the
  /// two payments to each other for the sender.
  Future<void> loadUnusedSubaddressIndex() async {
    final usedIndexes = <int>{};
    for (final tx in readTxHistory()) {
      if (tx.accountIndex == 0) usedIndexes.addAll(tx.subaddrIndexList);
    }

    var nextSubaddrIndex = 1;
    while (usedIndexes.contains(nextSubaddrIndex)) {
      nextSubaddrIndex++;
    }

    // The lowest-unused index only ever moves forward: a subaddress that has
    // received a payment stays used. Never regress it. The index pref is shared
    // across LWS and node, so right after an LWS→node switch the node's
    // not-yet-synced (empty) history would otherwise reset it to 1 and hand out
    // an already-used address until the next restart.
    final current = _unusedSubaddressIndex;
    if (current != null && current > nextSubaddrIndex) {
      nextSubaddrIndex = current;
    }

    // A node provisions nothing; every index is already scannable. Asserted
    // *before* the unchanged-index early return below, because the index and
    // the supported flag have different lifetimes: the index is deliberately
    // shared across LWS and node, while the flag describes one server. An LWS
    // that ran out of subaddresses leaves `isSupported: false` persisted, and
    // if the index happens not to move across the switch, an early return here
    // would carry that `false` into node mode -- where the receive screen shows
    // "you have reached the maximum number of subaddresses supported by this
    // server" about a node that has no such limit.
    if (_isNodeMode) {
      if (_unusedSubaddressIndex != nextSubaddrIndex || _unusedSubaddressIndexIsSupported != true) {
        await setUnusedSubaddressIndex(nextSubaddrIndex, isSupported: true);
      }
      return;
    }

    if (_unusedSubaddressIndex == nextSubaddrIndex) return;

    try {
      final isSupported = await isSubaddressSupported(nextSubaddrIndex);
      await setUnusedSubaddressIndex(nextSubaddrIndex, isSupported: isSupported);
    } catch (e) {
      walletLog(LogLevel.warn, 'unused subaddress probe failed: ${e.runtimeType}');
    }
  }

  /// Asks the LWS server to provision `(0, [subaddrIndex])` via
  /// `upsert_subaddrs`, and reports whether it accepted.
  ///
  /// **This request carries the private view key**, which is why it fails closed
  /// rather than falling back to clearnet: a connection configured for Tor with
  /// no Tor available must not send it, and neither must one configured for a
  /// custom SOCKS proxy. Skylight only proxied the Tor case and went direct when
  /// a custom proxy port was set. Both are honoured here.
  Future<bool> isSubaddressSupported(int subaddrIndex) async {
    final wallet = _wallet;
    if (wallet == null) throw StateError('Wallet is not open.');

    // Scheme derived like the daemon connection: https for a routable host,
    // plaintext only for an onion or local one.
    final proto = _addressRequiresSsl(connectionAddress) ? 'https' : 'http';
    final url = Uri.parse('$proto://$connectionAddress/upsert_subaddrs');

    // Node mode has no light-wallet server to talk to and no reason to send the
    // key anywhere, so refuse rather than trusting the address to be an LWS one.
    // The mode and the address are bound together now, but this is the request
    // that pays for a mismatch, so it asserts the mode rather than assuming it.
    if (_isNodeMode) {
      throw StateError('Refusing to send the view key: this wallet is in node mode.');
    }

    // Carries the private view key, so check before `secretViewKey` reads it.
    // `viaTor` must be the route actually taken — Tor's port or the custom SOCKS
    // proxy resolved below — not just `connectionUseTor`. Both callers read a
    // throw as "no subaddress support" and fall back to the primary address.
    requireConfidentialChannel(
      url,
      carrying: 'the private view key',
      viaTor: connectionUseTor || connectionProxyPort.isNotEmpty,
    );

    final body = jsonEncode({
      'address': getPrimaryAddress(),
      'view_key': await _backend.secretViewKey(wallet),
      'subaddrs': [
        {
          'key': 0,
          'value': [
            [0, subaddrIndex],
          ],
        },
      ],
      'get_all': false,
    });

    // The endpoint is the user's own configuration and worth logging. The
    // primary address is not, and the view key must never be logged.
    walletLog(
      LogLevel.info,
      'upsert_subaddrs $url for index $subaddrIndex '
      '(address ${Redact.id(getPrimaryAddress())}, view key ${Redact.secret})',
    );

    ({InternetAddress host, int port})? proxyInfo;
    if (connectionUseTor) {
      proxyInfo = await TorSettingsService.sharedInstance.getProxy();
      if (proxyInfo == null) {
        throw Exception('Connection requires Tor but no Tor proxy is available.');
      }
    } else if (connectionProxyPort.isNotEmpty) {
      final port = int.tryParse(connectionProxyPort);
      if (port == null) {
        throw Exception('Connection has a proxy port that is not a number.');
      }
      proxyInfo = (host: InternetAddress.loopbackIPv4, port: port);
    }

    var httpStatus = 0;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (proxyInfo != null) {
          final response = await makeSocksHttpRequest(
            'POST',
            url.toString(),
            proxyInfo,
            body: body,
            maxBytes: maxProbeResponseBytes,
            timeout: const Duration(seconds: 20),
          );
          httpStatus = response.statusCode;
        } else {
          httpStatus = await postJson(url, body).timeout(const Duration(seconds: 5));
        }
        break;
      } catch (e) {
        if (attempt == 2) {
          walletLog(LogLevel.warn, 'upsert_subaddrs failed after 3 attempts: ${e.runtimeType}');
          rethrow;
        }
      }
    }

    final result = httpStatus == 200;
    walletLog(LogLevel.info, 'upsert_subaddrs index $subaddrIndex: $result (status $httpStatus)');
    return result;
  }

  /// Unproxied POST, injected so the probe is testable.
  ///
  /// The proxied path already goes through `makeSocksHttpRequest`, which a test
  /// cannot intercept either; this is the seam for both. Returns the status code.
  @visibleForTesting
  Future<int> Function(Uri url, String body) postJson = _postJson;

  static Future<int> _postJson(Uri url, String body) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(url);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      // Set Content-Length explicitly. Left to `write()`, HttpClient streams the
      // body as Transfer-Encoding: chunked, which the monero-lws server rejects
      // with a 500; package:http (Skylight's old path) always sent a length.
      final bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> load() async {
    await loadPersistedSubaddressState();
    await loadPrimaryAddress();
    await super.load();
    // After the sync, because the unused index is derived from the transaction
    // history and both probes need an open connection.
    await loadSubaddressSupport();
    await loadUnusedSubaddressIndex();
    // The cache is runtime-only; repopulate it every load so a reload with an
    // unchanged index (loadUnusedSubaddressIndex early-returns) still resolves
    // a subaddress rather than leaving getUnusedSubaddress null.
    await _refreshSubaddressCache();
    notifyListeners();
  }

  /// A new transaction may have consumed the index we were handing out.
  @override
  Future<void> onTxHistoryGrew() async {
    await loadUnusedSubaddressIndex();
  }
}
