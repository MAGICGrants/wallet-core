import 'dart:async';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/foundation.dart';
import 'package:polyseed/polyseed.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'app_config.dart';
import 'app_session.dart';
import 'crypto_wallet.dart';
import 'metadata_backup.dart';
import 'seed/seed.dart';
import 'seed/seed_policy.dart';
import 'stores/seed_check_store.dart';
import 'stores/seed_store.dart';
import 'wallet_password_guard.dart';
import 'wallet_password_store.dart';

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

  /// App Lock's old on/off switch. App Lock is always on now; the key is only
  /// removed with the wallet.
  static const legacyAppLockEnabled = 'appLockEnabled';
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

  /// Installed by an app that keeps the generated (mobile) password somewhere
  /// safer than the keystore; see [WalletPasswordGuard]. Null keeps the
  /// keystore behaviour.
  static WalletPasswordGuard? passwordGuard;

  String? _password;

  /// Where [_password] came from.
  _PasswordSource _passwordSource = _PasswordSource.typed;

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

  /// The in-memory password, for a [passwordGuard]'s own set-up and release
  /// (moving it between the keystore and the guard). Null while locked. Not
  /// for anything else.
  String? get passwordForGuard => _password;

  void setWalletPassword(String password) => _setPassword(password, _PasswordSource.typed);

  /// Sets the in-memory password and, with it, the cost of encrypting files
  /// under it: [WalletFileCrypto.typedPasswordIterations] for one the user
  /// typed, the lower [WalletFileCrypto.generatedPasswordIterations] for a
  /// generated or seed-derived one, which nobody can guess anyway.
  void _setPassword(String? password, _PasswordSource source) {
    if (password != null && isUnattendedRun) {
      log(LogLevel.error, '[WalletManager] An unattended run was handed the wallet password');
      return;
    }
    _password = password;
    _passwordSource = source;
    if (password != null) _useFileCost(typed: source == _PasswordSource.typed);
  }

  static void _useFileCost({required bool typed}) {
    WalletFileCrypto.walletPasswordIterations = typed
        ? WalletFileCrypto.typedPasswordIterations
        : WalletFileCrypto.generatedPasswordIterations;
  }

  /// True if [password] decrypts the stored seed.
  Future<bool> verifyWalletPassword(String password) async {
    try {
      return await SeedStore.load(password) != null;
    } catch (_) {
      return false;
    }
  }

  /// The Linux and Windows unlock: true if the typed [password] is right.
  ///
  /// What it opens is the [WalletPasswordStore]'s business: the wallet
  /// password kept in `wallet.key`, or for an older wallet the typed password
  /// itself. With a [passwordGuard] engaged (security keys on) it only proves
  /// the typed password: this returns true with no password in memory, and the
  /// guard's own unlock comes next ([isPasswordGuarded], then
  /// [unlockWithGuardedPassword]).
  Future<bool> unlockWithTypedPassword(String password) async {
    final opened = await WalletPasswordStore.current.unlockTyped(password, guard: passwordGuard);
    switch (opened.kind) {
      case TypedUnlockKind.wrongPassword:
        return false;
      case TypedUnlockKind.engaged:
        _password = null;
      case TypedUnlockKind.unlocked:
        _setPassword(
          opened.walletPassword,
          opened.walletPasswordIsTyped ? _PasswordSource.typed : _PasswordSource.guard,
        );
    }
    return true;
  }

  /// Re-authentication on Linux and Windows: true if [password] is the one the
  /// user unlocks with (with security keys on, FHSE's outer password), checked
  /// without changing what is unlocked or held.
  Future<bool> checkTypedPassword(String password) =>
      WalletPasswordStore.current.checkTyped(password, guard: passwordGuard);

  /// Mints a random password. Used on mobile, where the user authenticates via
  /// the device rather than typing one; [restoreAll] persists it to the
  /// keystore.
  void useGeneratedPassword() => _setPassword(genWalletPassword(), _PasswordSource.generated);

  /// Clears the in-memory password, e.g. when App Lock locks.
  void clearPassword() => _password = null;

  /// Whether an engaged [passwordGuard] holds the password, so the keystore
  /// has none and an open needs [unlockWithGuardedPassword] first.
  Future<bool> isPasswordGuarded() async => await passwordGuard?.isEngaged() ?? false;

  /// Takes the password a [passwordGuard] released once the user unlocked it,
  /// for this session. Held in memory only, across App Lock relocks, until
  /// [fullyLock].
  ///
  /// Throws [StateError], taking nothing, when the keystore still keeps a
  /// different password: the guard is then not this wallet's (left by an
  /// earlier wallet whose delete was cut short), and the kept copy is what
  /// still opens this one.
  Future<void> unlockWithGuardedPassword(String password) async {
    final store = WalletPasswordStore.current;
    String? copy;
    try {
      copy = await store.readCopy();
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to read the kept password: $e');
    }
    if (copy != null && copy != password) {
      throw StateError("The password guard does not hold this wallet's password");
    }
    _setPassword(password, _PasswordSource.guard);
    // Engaging a guard writes the guard first and deletes the kept copy last,
    // so a crash in between leaves both, holding the same password. The guard
    // has just proven it works; finish the delete. (On Linux and Windows the
    // copy is `wallet.key`, which [WalletPasswordStore.readCopy] never returns.)
    try {
      await store.deleteCopy();
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to delete the kept password: $e');
    }
  }

  /// Has every open wallet keep what an unattended run needs to check in
  /// without the password (see [CryptoWallet.prepareViewOnly]). Call when a
  /// [passwordGuard] engages, before the keystore copy goes; otherwise
  /// [applyViewOnlySetting] keeps it in step with the toggles.
  Future<void> prepareViewOnlyAll() async {
    await Future.wait([
      for (final w in loadedWallets)
        w.prepareViewOnly().catchError((Object e) {
          log(LogLevel.warn, 'prepareViewOnly failed: $e', coin: w.coinSymbol);
        }),
    ]);
  }

  /// Undoes [prepareViewOnlyAll]; see [applyViewOnlySetting] for when.
  Future<void> forgetViewOnlyAll() async {
    await Future.wait([
      for (final w in _wallets.values)
        w.forgetViewOnly().catchError((Object e) {
          log(LogLevel.warn, 'forgetViewOnly failed: $e', coin: w.coinSymbol);
        }),
    ]);
  }

  /// Keeps the view-only material ([prepareViewOnlyAll]) in step with what runs
  /// without the user: kept while any unattended run is on
  /// ([unattendedRunsEnabled]: either sync, or notifications) or security keys
  /// are (an unattended run there has nothing else), forgotten otherwise. Runs
  /// after every open with the password; best effort.
  ///
  /// Every unattended run is view-only, keys or not ([isUnattendedRun]), so
  /// without this material it can check nothing.
  Future<void> applyViewOnlySetting() async {
    if (isUnattendedRun || _password == null) return;
    // Only where the keystore holds the password (Android, iOS, macOS). Linux
    // and Windows run nothing in the background, and their keystores are weak:
    // a Bitcoin xpub there would show the account's whole history for nothing.
    if (!WalletSecrets.holdsWalletPassword) return;
    try {
      if (await unattendedRunsEnabled() || await isPasswordGuarded()) {
        await prepareViewOnlyAll();
      } else {
        await forgetViewOnlyAll();
      }
    } catch (e) {
      log(LogLevel.warn, '[WalletManager] Could not update the view-only material: $e');
    }
  }

  /// After the user changes a sync or notifications toggle: sets up or removes
  /// Monero's view-only background copy ([applyBackgroundSyncSettingAll]) and
  /// the other coins' view-only material ([applyViewOnlySetting]) now, so the
  /// next background run finds them, rather than at the next launch.
  Future<void> applySyncSettings() async {
    await applyBackgroundSyncSettingAll();
    await applyViewOnlySetting();
  }

  /// Closes every wallet and forgets the password and everything decrypted
  /// with it, keeping the files. The next open needs the password again: from
  /// the keystore, the typed password, or for a guarded password, from
  /// unlocking the guard.
  ///
  /// App Lock alone only covers the screen; this is the lock that takes the
  /// key out of memory.
  Future<void> fullyLock() async {
    AppSession.lock();
    // The password goes first, before the slow part (each close stores its
    // wallet). Nothing below needs it: every wallet closes with its own cache
    // password and native state. And nothing else can use it meanwhile.
    _password = null;
    WalletPasswordStore.current.endSession();
    await _closeBackup();
    await Future.wait([
      for (final w in _wallets.values)
        w.close().catchError((Object e) {
          log(LogLevel.warn, 'close failed: $e', coin: w.coinSymbol);
        }),
    ]);
    notifyListeners();
  }

  /// The spend wallet locks: the wallet password leaves memory, and every open
  /// wallet drops its spending keys ([CryptoWallet.enterViewOnly]). Monero on a
  /// node keeps scanning with its view key (wallet2's background mode, when its
  /// view-only copy is set up), Bitcoin keeps watching with the account xpub and
  /// Ethereum with the address; anything else closes. [AppSession] locks first.
  ///
  /// When: App Lock locking with security keys off ([armAppLockRelock]); the
  /// full lock with security keys on, when Continuous Sync keeps the app
  /// running (otherwise [fullyLock] closes everything). The next open with the
  /// password ([unlockSpend], [openWalletFilesAndSync]) takes the keys back.
  Future<void> lockSpend() async {
    AppSession.lock();
    // The password first, as in [fullyLock]: nothing below needs it.
    _password = null;
    WalletPasswordStore.current.endSession();
    await _closeBackup();
    await Future.wait([
      for (final w in _wallets.values)
        w.enterViewOnly().catchError((Object e) {
          log(LogLevel.warn, 'locking the spend wallet failed: $e', coin: w.coinSymbol);
        }),
    ]);
    notifyListeners();
  }

  /// Whether a wallet is waiting for the password: view-only since
  /// [lockSpend], or not open.
  bool get isSpendLocked => _visibleWallets.any((w) => w.isViewOnly || !w.isLoaded);

  /// After the password is back: wallets [lockSpend] left view-only take their
  /// keys back (Monero replays what it watched), and closed ones open again,
  /// then everything syncs. Joins an open under way.
  Future<void> unlockSpend() async {
    if (isUnattendedRun || _password == null) return;
    await _openWalletFiles();
    syncInBackground();
    notifyListeners();
  }

  /// Locks App Lock: the app has been away for its "Lock after" time.
  ///
  /// Returns whether there is a wallet to lock (false during onboarding), and
  /// drops the in-memory password so nothing can be decrypted until the user
  /// authenticates again. App Lock is always on; how long the app may be away
  /// first is the app's setting.
  Future<bool> armAppLockRelock() async {
    if (!await hasAnyExistingWallet()) return false;
    // From here until the user passes App Lock again, nothing may open a
    // screen or a payment link ([AppSession]).
    AppSession.lock();
    // With security keys off the spend wallet locks here: the password and
    // every spending key leave memory ([lockSpend]). A guarded password cannot
    // be read back from the keystore after a relock, so it stays in memory
    // until the full lock; App Lock is the screen in front of it. Linux and
    // Windows keep theirs too: it was typed and cannot be read back, and their
    // App Lock checks the password again rather than reopening.
    if (WalletSecrets.holdsWalletPassword && !await isPasswordGuarded()) await lockSpend();
    return true;
  }

  /// App Lock's way in when the device cannot confirm its owner (a biometric
  /// lockout, a prompt that keeps failing): true when [mnemonic] is this
  /// wallet's recovery phrase, checked against the stored seed. The password
  /// then stays in memory, or comes back from the keystore.
  ///
  /// False, with nothing loaded, for any other phrase. Never reads a guarded
  /// password: with security keys on and the wallet locked this is false, and
  /// the keys' own recovery is the way in.
  Future<bool> unlockWithRecoveryPhrase(String mnemonic) async {
    final SeedSource? typed;
    try {
      // A keyboard that capitalises the first word must not make it wrong.
      typed = SeedSource.detect(_phrase(mnemonic));
    } catch (_) {
      return false;
    }
    if (typed == null) return false;
    final password =
        _password ??
        (await isPasswordGuarded() ? null : await WalletPasswordStore.current.readCopy());
    if (password == null) return false;
    final ({SeedSource seed, RestorePoint from})? stored;
    try {
      stored = await SeedStore.load(password);
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to read stored seed: $e');
      return false;
    }
    if (stored == null || _phrase(stored.seed.mnemonic) != _phrase(typed.mnemonic)) return false;
    if (_password == null) _setPassword(password, _PasswordSource.generated);
    return true;
  }

  static String _phrase(String mnemonic) =>
      mnemonic.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Takes the password from its kept copy, where one can be read without the
  /// user: the keystore. Always false on Linux and Windows, so nothing there
  /// opens or decrypts before the user types the password, and false behind an
  /// engaged guard, whose leftover copy (if any) is not read back.
  ///
  /// A copy in the keystore is generated or seed-derived, so files under it
  /// get the generated-password cost.
  Future<bool> loadStoredPassword() async {
    // Never in an unattended run: it checks in with view-only material.
    if (isUnattendedRun) return false;
    if (await isPasswordGuarded()) return false;
    final stored = await WalletPasswordStore.current.readCopy();
    if (stored == null) return false;
    _setPassword(stored, _PasswordSource.generated);
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
    if (isUnattendedRun) {
      assert(password == null, 'An unattended run never holds the wallet password');
      assert(
        _wallets.values.every((w) => w.unattended),
        'A manager is unattended for every coin or for none',
      );
      await loadCachedDisplayState();
      if (displayOnly) return;
      // Background sync, continuous sync and notification checks: whatever the
      // configuration, only view-only material (see [isUnattendedRun]). A coin
      // without it is skipped.
      await _openViewOnly();
      return;
    }

    if (password != null) setWalletPassword(password);

    await loadCachedDisplayState();
    if (displayOnly) return;

    if (_password == null && !await loadStoredPassword()) {
      log(LogLevel.warn, '[WalletManager] openAll called without a password');
      return;
    }

    await _openWalletFiles();
  }

  /// A run the user is not doing (background sync, continuous sync, a
  /// notification check): its wallets were marked
  /// [CryptoWallet.markUnattended] before opening. It holds view-only material
  /// only, whether or not security keys are on: it never loads the wallet
  /// password, never decrypts the seed store and never opens a wallet with its
  /// spend key ([openAll], [loadStoredPassword], [_setPassword]).
  bool get isUnattendedRun => _wallets.values.any((w) => w.unattended);

  Future<void> _openViewOnly() async {
    await Future.wait([
      for (final w in _visibleWallets)
        () async {
          try {
            if (!await w.openViewOnly()) {
              log(
                LogLevel.info,
                'No password and no view-only path; skipping.',
                coin: w.coinSymbol,
              );
            }
          } catch (e) {
            log(LogLevel.warn, 'View-only open failed: $e', coin: w.coinSymbol);
          }
        }(),
    ]);
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

    // Cached balances live in the password-encrypted cache. App Lock is always
    // on, so nothing is decrypted before the user authenticates: without a
    // password in memory, hydration waits for the post-unlock open path. Linux
    // and Windows wait for the typed password the same way.
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

  /// Asked before this app opens its wallet files with the password, so
  /// nothing else in the process holds them: on Android, the Continuous Sync
  /// service lets go of its view-only copies first (wallet_background's
  /// `ForegroundSyncLink`). Null where nothing else can hold them.
  static Future<void> Function()? claimWalletFiles;

  /// Closes the native wallets an app isolate of this process left open when
  /// Android destroyed it, other than [exceptToken]'s (a live isolate's,
  /// [WalletIsolate.token]). Called by whoever takes the wallets next: the
  /// Continuous Sync service, or the app's next isolate. Installed by the app's
  /// bootstrap in every isolate (wallet_monero's `closeOrphanedMoneroWallets`);
  /// null where no coin keeps native wallets.
  static Future<void> Function({String? exceptToken})? closeOrphanedWallets;

  Future<void> _openWalletFilesOnce() async {
    final password = _password;
    if (isUnattendedRun || password == null) return;
    try {
      await claimWalletFiles?.call();
    } catch (e) {
      log(LogLevel.warn, '[WalletManager] Could not claim the wallet files: $e');
    }
    try {
      // Wallets left view-only by [lockSpend] take their keys back first,
      // before the seed is read: a send right after an unlock waits on exactly
      // this ([CryptoWallet.leaveViewOnly]).
      final leaving = {
        for (final w in _visibleWallets)
          if (w.isViewOnly) w: w.leaveViewOnly(password),
      };
      final storedSeed = await _loadStoredSeed();

      // Fan out so per-wallet opens (each in its own isolate or FFI thread)
      // overlap. A failure in one wallet must not cancel the others.
      await Future.wait([
        for (final w in _visibleWallets)
          leaving.containsKey(w)
              ? _afterLeavingViewOnly(w, leaving[w]!, storedSeed)
              : _openOneWallet(w, storedSeed),
      ]);
      // With logging on, once per process: how long a key derivation
      // takes here, to choose the iteration counts from real numbers.
      unawaited(WalletFileCrypto.logDerivationTimes());

      if (storedSeed != null) _openBackup(storedSeed.seed);
      await applyViewOnlySetting();
    } finally {
      _openWalletFilesInFlight = null;
    }
  }

  /// A wallet that could not take its keys back in place is closed and opened
  /// again, which also merges what it watched (Monero's open replays its
  /// view-only copy).
  Future<void> _afterLeavingViewOnly(
    CryptoWallet w,
    Future<bool> leaving,
    ({SeedSource seed, RestorePoint from})? storedSeed,
  ) async {
    if (await leaving) return;
    log(LogLevel.warn, 'Keys not taken back in place; reopening.', coin: w.coinSymbol);
    try {
      await w.close();
    } catch (e) {
      log(LogLevel.warn, 'close failed: $e', coin: w.coinSymbol);
    }
    await _openOneWallet(w, storedSeed);
  }

  /// The persisted original mnemonic for the reveal-seed screen, or null when
  /// nothing has been stored yet.
  Future<({SeedSource seed, RestorePoint from})?> loadStoredSeed() => _loadStoredSeed();

  Future<({SeedSource seed, RestorePoint from})?> _loadStoredSeed() async {
    final password = _password;
    if (password == null || isUnattendedRun) return null;
    try {
      return await SeedStore.load(password);
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to read stored seed: $e');
      return null;
    }
  }

  /// Re-runs the open path for one wallet, after a connection change that needs
  /// the wallet rebuilt for a different server kind (Monero LWS↔node).
  Future<void> reopenWallet(String coinSymbol) async {
    if (_password == null) await loadStoredPassword();
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
    if (_password == null) await loadStoredPassword();
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
    if (_password == null) await loadStoredPassword();
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

    // Decrypt the cache now the password is available; covers the typed unlock,
    // where loadCachedDisplayState ran before there was one.
    await _hydrateWalletCache(w);

    try {
      if (await w.hasExistingWallet()) {
        final timer = Stopwatch()..start();
        await w.openExisting(password: _password!);
        log(LogLevel.info, 'Wallet opened in ${timer.elapsedMilliseconds}ms', coin: w.coinSymbol);
      } else if (storedSeed != null) {
        log(LogLevel.info, 'Bootstrapping from stored seed.', coin: w.coinSymbol);
        await _restoreOne(w, storedSeed.seed, storedSeed.from, _password!);
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
          await _restoreOne(w, storedSeed.seed, storedSeed.from, _password!);
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
  Future<void> _restoreOne(
    CryptoWallet w,
    SeedSource seed,
    RestorePoint from,
    String password, {
    bool freshSeed = false,
  }) async {
    if (!_seedPolicy.accepts(seed.format) || !w.supportedSeedFormats.contains(seed.format)) {
      log(
        LogLevel.info,
        'Skipping restore: ${seed.format.name} seeds are not supported by this coin.',
        coin: w.coinSymbol,
      );
      return;
    }
    await w.restoreFromSeed(seed: seed, from: from, password: password);
    if (freshSeed) w.markFreshlyGenerated();

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
      if (_password == null) await loadStoredPassword();
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
      if (_password == null) await loadStoredPassword();
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
  ///
  /// [freshSeed] is for a seed [generateSeed] just produced, never a typed one:
  /// such a seed has received nothing, so each wallet starts at a known zero
  /// balance instead of none until its first sync. See
  /// [CryptoWallet.markFreshlyGenerated].
  Future<void> restoreAll({
    required SeedSource seed,
    required RestorePoint from,
    bool freshSeed = false,
  }) async {
    if (_password == null) {
      throw StateError('Wallet password must be set before restoring wallets.');
    }
    // Linux and Windows keep no copy of a generated password, so a wallet
    // encrypted with one could not be opened again.
    if (_passwordSource == _PasswordSource.generated && WalletPasswordStore.current.typesPassword) {
      throw StateError('On Linux and Windows the wallet password must be the one the user typed.');
    }
    if (!_seedPolicy.accepts(seed.format)) {
      throw UnsupportedSeedFormatException(
        seed.format,
        'this app does not accept ${seed.format.name} seeds',
      );
    }

    // A guard supplies the password in place of the random one minted at
    // onboarding. Where the user types one (Linux, Windows) it supplies it too,
    // and the typed one only unlocks it (WalletPasswordStore). Without a guard
    // a typed password is the wallet password.
    final guard = passwordGuard;
    final store = WalletPasswordStore.current;
    if (_passwordSource == _PasswordSource.guard && store.typesPassword && guard != null) {
      // The typed password that must open the new wallet is not in memory.
      throw StateError('On Linux and Windows a new wallet needs the password the user typed.');
    }
    final typed = _passwordSource == _PasswordSource.typed ? _password : null;
    final guarded = guard != null && (typed == null || store.typesPassword);

    // Held here, and only made the manager's once the restore succeeds: a
    // retry after a failure then starts from the same typed or generated
    // password, and derives and keeps a copy again.
    var walletPassword = _password!;
    if (guarded) walletPassword = await guard.passwordForNewWallet(seed);
    _useFileCost(typed: !guarded && typed != null);

    // The copy before any file: if the keystore refuses it (on macOS, a
    // release build that is not team-signed), onboarding stops with nothing
    // encrypted under a password no one holds. On Linux and Windows the copy
    // is `wallet.key`, under the typed password. A copy kept with no wallet is
    // never read, since startup loads one only when a wallet exists, and the
    // next onboarding replaces it.
    await store.saveCopy(walletPassword, typed: typed);

    for (final w in _visibleWallets) {
      w.setCachePassword(walletPassword);
      await _restoreOne(w, seed, from, walletPassword, freshSeed: freshSeed);
    }

    // Persist the seed so coins added in a future release can be bootstrapped
    // on the next unlock without re-prompting, and so a bip39/polyseed restore
    // can be shown back verbatim, since the wallet only yields its derived
    // legacy seed.
    await SeedStore.save(seed: seed, from: from, password: walletPassword);
    // A new wallet starts unverified: the keystore can outlive an uninstall
    // (iOS), so a record from a wallet that was here before must not carry over.
    await SeedCheckStore.delete();

    if (guarded) await guard.walletCreated(walletPassword);
    _setPassword(walletPassword, guarded ? _PasswordSource.guard : _passwordSource);

    for (final w in _visibleWallets) {
      await w.loadPersistedConnection();
    }

    // Onboarding is done: the user who just created or restored the wallet is
    // past every lock it has (none yet).
    AppSession.markUnlocked();
    _openBackup(seed, restored: true);
  }

  // ----- Metadata backup -----

  /// Opens the metadata backup, if the app installed one. Not awaited by the
  /// callers: it derives keys (PBKDF2) and reads storage, and neither may hold
  /// up an unlock or a restore.
  void _openBackup(SeedSource seed, {bool restored = false}) {
    final backup = MetadataBackup.instance;
    if (backup == null) return;
    unawaited(
      backup.open(seed, wallets: _visibleWallets.toList(), restored: restored).catchError((
        Object e,
      ) {
        log(LogLevel.warn, '[WalletManager] Metadata backup did not open: $e');
      }),
    );
  }

  Future<void> _closeBackup() async {
    try {
      await MetadataBackup.instance?.close();
    } catch (e) {
      log(LogLevel.warn, '[WalletManager] Metadata backup did not close: $e');
    }
  }

  /// Deletes every wallet file and clears the keys this layer owns.
  ///
  /// [extraPrefKeys] lets the app clear its own (contacts, pending txs,
  /// notification state) in the same pass; the manager does not know them.
  Future<void> deleteAll({List<String> extraPrefKeys = const []}) async {
    AppSession.lock();
    // The guard first: one left behind by a delete cut short would make the
    // next wallet look guarded, and release this one's password for it.
    try {
      await passwordGuard?.walletDeleted();
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to clear the password guard: $e');
    }
    try {
      await MetadataBackup.instance?.deleteLocal();
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to delete the local metadata backup: $e');
    }

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
    await SeedCheckStore.delete();

    _password = null;
    final store = WalletPasswordStore.current;
    try {
      await store.deleteCopy();
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to delete the kept password: $e');
    }
    store.endSession();
    // After the guard: its file may be bound too. Nothing bound is left.
    try {
      await PcBinding.deleteRecord();
    } catch (e) {
      log(LogLevel.error, '[WalletManager] Failed to delete the PC binding: $e');
    }

    await SharedPreferencesService.remove(DomainPreferenceKeys.legacyAppLockEnabled);
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

/// Where [WalletManager]'s in-memory password came from.
enum _PasswordSource {
  /// Typed by the user (Linux, Windows).
  typed,

  /// Minted by [WalletManager.useGeneratedPassword] (mobile, macOS).
  generated,

  /// Supplied or released by [WalletManager.passwordGuard].
  guard,
}
