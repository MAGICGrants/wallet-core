import 'dart:async';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/foundation.dart';
import 'package:polyseed/polyseed.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'app_config.dart';
import 'crypto_wallet.dart';
import 'seed/seed.dart';
import 'seed/seed_policy.dart';
import 'stores/seed_store.dart';

/// Supplies the coins this app supports. Called once, at construction.
///
/// **App-owned, not compiled in.** A multicoin app registers Monero, Bitcoin,
/// Ethereum and the tokens; a Monero-only app registers Monero and never links
/// the others. Beyond binary size, that keeps its audit surface small.
///
/// **Must return freshly constructed wallets on every call.** A [WalletManager]
/// takes ownership of what it is given and disposes it, and two managers can
/// exist over the same registry; `runTxNotifier` builds a throwaway probe
/// manager, disposes it, then builds the real one. A registry that hands out a
/// captured list gives the second manager already-disposed wallets, which throw
/// on `addListener`.
typedef CoinRegistry = List<CryptoWallet> Function();

/// Preference keys owned by the domain layer.
class DomainPreferenceKeys {
  DomainPreferenceKeys._();

  static const testnetCoinsEnabled = 'testnetCoinsEnabled';
  static const appLockEnabled = 'appLockEnabled';
}

/// Top-level state holder shared by every screen.
///
/// Owns every registered [CryptoWallet] and orchestrates the flows that touch
/// all of them: opening from a stored password, restoring from a seed,
/// deleting. Each child wallet is its own [ChangeNotifier]; the manager
/// re-broadcasts their notifications (debounced) so widgets watching only the
/// manager still update.
class WalletManager with ChangeNotifier {
  WalletManager({required CoinRegistry coins}) : _wallets = {} {
    for (final wallet in coins()) {
      _register(wallet);
    }
  }

  final Map<String, CryptoWallet> _wallets;

  String? _password;
  bool _testnetCoinsEnabled = false;
  Timer? _notifyDebounce;

  SeedPolicy get _seedPolicy => WalletAppConfig.instance.seedPolicy;

  void _register(CryptoWallet wallet) {
    _wallets[wallet.coinSymbol.toUpperCase()] = wallet;
    wallet.addListener(_onWalletChanged);
  }

  /// Coalesces a burst of per-wallet notifications into one rebuild. With
  /// several coins syncing at once this is the difference between a handful of
  /// rebuilds and hundreds.
  void _onWalletChanged() {
    _notifyDebounce?.cancel();
    _notifyDebounce = Timer(const Duration(milliseconds: 100), notifyListeners);
  }

  // ----- Visibility -----

  Future<void> loadPreferences() async {
    _testnetCoinsEnabled =
        await SharedPreferencesService.get<bool>(DomainPreferenceKeys.testnetCoinsEnabled) ?? false;
    _applyTestnetVisibility();
    notifyListeners();
  }

  bool get testnetCoinsEnabled => _testnetCoinsEnabled;

  Future<void> setTestnetCoinsEnabled(bool enabled) async {
    if (_testnetCoinsEnabled == enabled) return;
    _testnetCoinsEnabled = enabled;
    await SharedPreferencesService.set<bool>(DomainPreferenceKeys.testnetCoinsEnabled, enabled);
    _applyTestnetVisibility();
    notifyListeners();
    if (enabled && _password != null) openWalletFilesAndSync();
  }

  void _applyTestnetVisibility() {
    for (final w in _wallets.values) {
      if (w.isTestnet) w.setEnabledInApp(_testnetCoinsEnabled);
    }
  }

  bool _isVisible(CryptoWallet w) => !w.isTestnet || _testnetCoinsEnabled;

  Iterable<CryptoWallet> get _visibleWallets => _wallets.values.where(_isVisible);

  // ----- Public surface -----

  Map<String, CryptoWallet> get wallets => Map.unmodifiable(_wallets);
  List<CryptoWallet> get allWallets => List.unmodifiable(_visibleWallets);
  List<CryptoWallet> get activeWallets =>
      _visibleWallets.where((w) => w.isActive).toList(growable: false);
  List<CryptoWallet> get loadedWallets =>
      _visibleWallets.where((w) => w.isLoaded).toList(growable: false);

  CryptoWallet? getWallet(String coinSymbol) {
    final wallet = _wallets[coinSymbol.toUpperCase()];
    if (wallet == null || !_isVisible(wallet)) return null;
    return wallet;
  }

  // ----- Password -----

  bool get hasPassword => _password != null;

  void setWalletPassword(String password) => _password = password;

  /// Mints a random password. Used on mobile, where the user authenticates via
  /// the device rather than typing one; [restoreAll] persists it to the
  /// keystore.
  void useGeneratedPassword() => _password = genWalletPassword();

  /// Clears the in-memory password, e.g. on background with app lock enabled.
  void clearPassword() => _password = null;

  Future<void> persistMobileWalletPassword() async {
    final password = _password;
    if (password == null) throw StateError('Cannot persist password: none set');
    await storeMobileWalletPassword(password);
  }

  Future<bool> loadMobileWalletPassword() async {
    final stored = await getMobileWalletPassword();
    if (stored == null) return false;
    _password = stored;
    return true;
  }

  // ----- Lifecycle across all wallets -----

  Future<bool> hasAnyExistingWallet() async {
    for (final w in _wallets.values) {
      if (await w.hasExistingWallet()) return true;
    }
    return false;
  }

  Future<void> openAll({String? password, bool displayOnly = false}) async {
    if (password != null) _password = password;

    await loadCachedDisplayState();
    if (displayOnly) return;

    if (_password == null && !await loadMobileWalletPassword()) {
      log(LogLevel.warn, '[WalletManager] openAll called without a password');
      return;
    }

    await _openWalletFiles();
  }

  /// Restores persisted connection settings and cached balances. Fast; meant
  /// to run before navigating to the home screen.
  Future<void> loadCachedDisplayState() async {
    await loadPreferences();

    await Future.wait(
      _visibleWallets.map((w) async {
        try {
          await w.loadPersistedConnection();
        } catch (e) {
          log(LogLevel.error, 'Failed to load connection: $e', coin: w.coinSymbol);
        }
      }),
    );

    // Cached balances live in the password-encrypted cache. With app lock off
    // the password can be auto-loaded and the numbers shown immediately; with
    // it on we must not decrypt before the user authenticates, so hydration is
    // deferred to the post-unlock open path.
    final appLockEnabled =
        await SharedPreferencesService.get<bool>(DomainPreferenceKeys.appLockEnabled) ?? false;
    if (_password == null && !appLockEnabled) await loadMobileWalletPassword();

    await Future.wait(_visibleWallets.map(_hydrateWalletCache));
  }

  Future<void> _hydrateWalletCache(CryptoWallet w) async {
    if (_password == null) return;
    try {
      w.setCachePassword(_password);
      await w.loadCache();
      await w.loadPersistedSnapshot();
    } catch (e) {
      log(LogLevel.error, 'Failed to hydrate cache: $e', coin: w.coinSymbol);
    }
  }

  Future<void>? _openWalletFilesInFlight;

  Future<void> _openWalletFiles() => _openWalletFilesInFlight ??= _openWalletFilesOnce();

  Future<void> _openWalletFilesOnce() async {
    try {
      final storedSeed = await _loadStoredSeed();

      // Fan out so per-wallet opens (each in its own isolate or FFI thread)
      // overlap. A failure in one wallet must not cancel the others.
      await Future.wait([for (final w in _visibleWallets) _openOneWallet(w, storedSeed)]);
    } finally {
      _openWalletFilesInFlight = null;
    }
  }

  /// The persisted original mnemonic for the reveal-seed screen, or null when
  /// nothing has been stored yet.
  Future<({SeedSource seed, RestorePoint from})?> loadStoredSeed() => _loadStoredSeed();

  Future<({SeedSource seed, RestorePoint from})?> _loadStoredSeed() async {
    try {
      return await SeedStore.load(_password!);
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to read stored seed: $e');
      return null;
    }
  }

  /// Re-runs the open path for one wallet, after a connection change that needs
  /// the wallet rebuilt for a different server kind (Monero LWS↔node).
  Future<void> reopenWallet(String coinSymbol) async {
    if (_password == null) await loadMobileWalletPassword();
    if (_password == null) return;

    final w = getWallet(coinSymbol);
    if (w == null) return;

    // Only a server-kind change needs a rebuild; plain tweaks (Tor, SSL,
    // address) are picked up by the following load() without reopening.
    if (!await w.needsRebuildForCurrentConnection()) return;

    await _openOneWallet(w, await _loadStoredSeed());
  }

  /// Applies a change to the background-sync setting the app has already
  /// persisted.
  ///
  /// Call it next to the background-task re-registration, for the same reason
  /// that exists: the setting has two effects and only one of them is
  /// scheduling. The other is written **into the wallet file**; Monero in node
  /// mode gains or loses a view-only background cache; so it needs an
  /// open wallet and the wallet password, and without this hook nothing would
  /// reach the wallet until the next launch. A wake-up in between would fall
  /// back to syncing the real wallet while the UI said otherwise.
  ///
  /// A no-op for every coin whose unattended run is a check. Per-wallet failures
  /// are logged and swallowed: a wallet that cannot configure background sync
  /// still syncs in the foreground.
  Future<void> applyBackgroundSyncSettingAll() async {
    if (_password == null) await loadMobileWalletPassword();
    final password = _password;
    if (password == null) {
      log(LogLevel.warn, '[WalletManager] no password; background sync setting not applied');
      return;
    }

    await Future.wait([
      for (final w in loadedWallets)
        w.applyBackgroundSyncSetting(password: password).catchError((Object e) {
          log(LogLevel.warn, 'applyBackgroundSyncSetting failed: $e', coin: w.coinSymbol);
        }),
    ]);
  }

  /// Applies a connection change the app has already set + persisted: rebuilds
  /// the wallet for a new server kind if needed (Monero LWS↔node), then syncs.
  /// Unlike [reopenWallet] this always reconnects, so plain tweaks (Tor, SSL,
  /// address) take effect too.
  Future<void> applyConnectionChange(String coinSymbol) async {
    if (_password == null) await loadMobileWalletPassword();
    final password = _password;
    if (password == null) return;

    final w = getWallet(coinSymbol);
    if (w == null) return;

    await w.applyConnectionChange(password: password);
  }

  Future<void> _openOneWallet(
    CryptoWallet w,
    ({SeedSource seed, RestorePoint from})? storedSeed,
  ) async {
    // Coins whose daemon connect needs no wallet state can handshake in the
    // shadow of the file open, so the sync that follows already has a socket.
    // Not awaited: a slow Tor handshake must not stall the open path, and
    // load() dedupes via the connect's in-flight future.
    unawaited(_connectBeforeOpenSafely(w));

    // Decrypt the cache now the password is available; covers desktop unlock,
    // where loadCachedDisplayState ran before there was one.
    await _hydrateWalletCache(w);

    try {
      if (await w.hasExistingWallet()) {
        final timer = Stopwatch()..start();
        await w.openExisting(password: _password!);
        log(LogLevel.info, 'Wallet opened in ${timer.elapsedMilliseconds}ms', coin: w.coinSymbol);
      } else if (storedSeed != null) {
        log(LogLevel.info, 'Bootstrapping from stored seed.', coin: w.coinSymbol);
        await _restoreOne(w, storedSeed.seed, storedSeed.from);
      }
    } catch (e) {
      log(LogLevel.error, 'Failed to open: $e', coin: w.coinSymbol);

      if (storedSeed != null && _isCorruptWalletFile(e)) {
        try {
          log(
            LogLevel.warn,
            'Removing corrupt wallet file and re-bootstrapping.',
            coin: w.coinSymbol,
          );
          await w.deleteFiles();
          await _restoreOne(w, storedSeed.seed, storedSeed.from);
        } catch (e2) {
          log(LogLevel.error, 'Failed to re-bootstrap: $e2', coin: w.coinSymbol);
        }
      }
    }
  }

  /// Restores one wallet, skipping coins the seed cannot derive.
  ///
  /// A multicoin wallet restored from a polyseed would otherwise throw for
  /// every non-Monero coin. The two-sided check makes "this coin can't use
  /// this seed" a skip rather than a failure of the whole restore.
  Future<void> _restoreOne(CryptoWallet w, SeedSource seed, RestorePoint from) async {
    if (!_seedPolicy.accepts(seed.format) || !w.supportedSeedFormats.contains(seed.format)) {
      log(
        LogLevel.info,
        'Skipping restore: ${seed.format.name} seeds are not supported by this coin.',
        coin: w.coinSymbol,
      );
      return;
    }
    await w.restoreFromSeed(seed: seed, from: from, password: _password!);

    // Everything this seed already received is history, not news. Done here
    // rather than inside each coin's `restoreFromSeed` so a coin added later
    // cannot forget it; without the marker, the scan that follows announces
    // every historical receipt as if it had just arrived.
    await w.markExistingTxsAsNotified();
  }

  /// Announces incoming transactions across every open wallet.
  ///
  /// The app calls this from wherever it wants notifications to come from; a
  /// periodic task, a foreground service, and **not** from the refresh path.
  /// Each isolate refreshes history on its own timer, so announcing there would
  /// let whichever one ran first consume the marker for all of them.
  ///
  /// [announce] false records current history as seen without firing any
  /// notification; the foreground uses it (e.g. on app pause) so a tx the user
  /// just watched arrive is not re-announced by a background isolate.
  Future<void> notifyNewIncomingTxsAll({bool announce = true}) async {
    await Future.wait([
      for (final w in loadedWallets)
        w.notifyNewIncomingTxs(announce: announce).catchError((Object e) {
          log(LogLevel.warn, 'notifyNewIncomingTxs failed: $e', coin: w.coinSymbol);
        }),
    ]);
  }

  Future<void> _connectBeforeOpenSafely(CryptoWallet w) async {
    if (!w.canConnectBeforeOpen) return;
    try {
      final timer = Stopwatch()..start();
      await w.connectBeforeOpen();
      log(LogLevel.info, 'Pre-open connect in ${timer.elapsedMilliseconds}ms', coin: w.coinSymbol);
    } catch (e) {
      log(LogLevel.warn, 'Pre-open connect failed: $e', coin: w.coinSymbol);
    }
  }

  void openWalletFilesAndSync() {
    unawaited(() async {
      if (_password == null) await loadMobileWalletPassword();
      if (_password == null) return;
      await _openWalletFiles();
      syncInBackground();
    }());
  }

  /// Steady-state refresh for every configured wallet, in parallel, with
  /// per-coin failures isolated so one bad node can't sink the rest.
  Future<void> loadAll() async {
    await Future.wait([
      for (final w in _visibleWallets)
        if (w.isActive)
          w.load().catchError((Object e) {
            log(LogLevel.warn, 'load failed: $e', coin: w.coinSymbol);
          }),
    ]);
  }

  Future<void> bootstrap() async {
    await loadCachedDisplayState();
    if (loadedWallets.isEmpty) {
      if (_password == null) await loadMobileWalletPassword();
      if (_password != null) await _openWalletFiles();
    }
    syncInBackground();
  }

  void syncInBackground() => unawaited(loadAll());

  /// Checkpoints every open wallet before a background task ends.
  ///
  /// Nothing closes a wallet when a background isolate finishes, so a refresh
  /// left running keeps pulling blocks past the end of the task and everything
  /// scanned since the last checkpoint goes with the isolate.
  Future<void> pauseSyncAndStoreAll() async {
    await Future.wait([
      for (final w in loadedWallets)
        w.pauseSyncAndStore().catchError((Object e) {
          log(LogLevel.warn, 'pauseSyncAndStore failed: $e', coin: w.coinSymbol);
        }),
    ]);
  }

  static bool _isCorruptWalletFile(Object error) {
    if (error is! FormatException) return false;
    final msg = error.message.toLowerCase();
    return msg.contains('too short') ||
        msg.contains('magic mismatch') ||
        msg.contains('corrupt') ||
        msg.contains('decryption failed') ||
        msg.contains('unsupported wallet blob');
  }

  // ----- Seed generation and restore -----

  /// Generates a new seed in the app's configured format. Nothing is created or
  /// persisted until [restoreAll] runs, after the user confirms they wrote it
  /// down.
  ///
  /// Both formats are generated in pure Dart. The `polyseed` package produces
  /// the same standard seed as monero_c's `Wallet_createPolyseed` and keeps
  /// `wallet_domain` free of FFI, but it is a different code path; a test
  /// against the real library should confirm a seed generated here restores to
  /// the same address through monero_c.
  ({SeedSource seed, DateTime restoreDate}) generateSeed() {
    final now = DateTime.now();
    return switch (_seedPolicy.generate) {
      // 160 bits -> 15 words.
      SeedFormat.bip39 => (
        seed: Bip39Seed(bip39.generateMnemonic(strength: 160)),
        restoreDate: now,
      ),
      SeedFormat.polyseed => (
        seed: PolyseedSeed(
          Polyseed.create().encode(
            PolyseedLang.getByEnglishName('English'),
            PolyseedCoin.POLYSEED_MONERO,
          ),
        ),
        restoreDate: now,
      ),
      // Never generated; only ever accepted on restore.
      SeedFormat.moneroLegacy => throw StateError(
        'A 25-word legacy seed can be restored but never generated.',
      ),
    };
  }

  /// Restores every supported coin from one seed.
  ///
  /// Coins that cannot derive from this seed format are skipped rather than
  /// failing the restore; see [_restoreOne].
  Future<void> restoreAll({required SeedSource seed, required RestorePoint from}) async {
    if (_password == null) {
      throw StateError('Wallet password must be set before restoring wallets.');
    }
    if (!_seedPolicy.accepts(seed.format)) {
      throw UnsupportedSeedFormatException(
        seed.format,
        'this app does not accept ${seed.format.name} seeds',
      );
    }

    for (final w in _visibleWallets) {
      w.setCachePassword(_password);
      await _restoreOne(w, seed, from);
    }

    // Persist the seed so coins added in a future release can be bootstrapped
    // on the next unlock without re-prompting, and so a bip39/polyseed restore
    // can be shown back verbatim, since the wallet only yields its derived
    // legacy seed.
    await SeedStore.save(seed: seed, from: from, password: _password!);

    await persistMobileWalletPassword();

    for (final w in _visibleWallets) {
      await w.loadPersistedConnection();
    }
  }

  /// Deletes every wallet file and clears the keys this layer owns.
  ///
  /// [extraPrefKeys] lets the app clear its own (contacts, pending txs,
  /// notification state) in the same pass; the manager does not know them.
  Future<void> deleteAll({List<String> extraPrefKeys = const []}) async {
    for (final w in _wallets.values) {
      try {
        await w.delete();
      } catch (e) {
        log(LogLevel.error, 'Failed to delete: $e', coin: w.coinSymbol);
      }
    }

    try {
      await SeedStore.delete();
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to delete stored seed: $e');
    }

    _password = null;
    try {
      await deleteMobileWalletPassword();
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to delete stored password: $e');
    }

    await SharedPreferencesService.remove(DomainPreferenceKeys.appLockEnabled);
    for (final key in extraPrefKeys) {
      await SharedPreferencesService.remove(key);
    }
  }

  // ----- Aggregates -----

  /// Sum of unlocked balance × fiat rate across visible mainnet coins.
  ///
  /// `double` is fine here and only here: this is a fiat display total, not a
  /// coin amount. Rates are doubles to begin with, and the result is rounded
  /// for display. Anything that moves money still goes through base units.
  double totalUnlockedFiat(Map<String, double?> ratesBySymbol) {
    var total = 0.0;
    for (final w in _visibleWallets) {
      if (w.isTestnet) continue;
      total += (w.unlockedBalance ?? 0) * (ratesBySymbol[w.fiatBaseSymbol] ?? 0);
    }
    return total;
  }

  @override
  void dispose() {
    _notifyDebounce?.cancel();
    for (final w in _wallets.values) {
      w.removeListener(_onWalletChanged);
      w.dispose();
    }
    super.dispose();
  }
}
