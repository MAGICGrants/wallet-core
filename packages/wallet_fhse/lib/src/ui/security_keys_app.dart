import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:wallet_domain/wallet_domain.dart' show AppSession, SeedSource, WalletManager;
import 'package:wallet_infra/wallet_infra.dart'
    show
        BiometricAuth,
        BiometricAuthResult,
        BoundToAnotherPcException,
        LogLevel,
        SettingsKeys,
        SharedPreferencesService,
        WalletSecrets,
        log;

import '../fhse_native.dart';
import '../fhse_vault.dart';
import '../security_key_service.dart';

/// What an app supplies to the shared security-key screens. Installed once,
/// in the UI isolate, before any of them is shown.
class SecurityKeysUi {
  SecurityKeysUi._();

  static SecurityKeysUiConfig? _config;

  static void install(SecurityKeysUiConfig config) => _config = config;

  static SecurityKeysUiConfig get config =>
      _config ?? (throw StateError('SecurityKeysUi.install was not called'));

  @visibleForTesting
  static void resetForTesting() => _config = null;
}

class SecurityKeysUiConfig {
  const SecurityKeysUiConfig({
    required this.appName,
    required this.walletManagerOf,
    required this.homeRoute,
    required this.logo,
  });

  /// The app's name, in the few strings that say who does what.
  final String appName;

  /// The app's [WalletManager], from wherever it keeps it.
  final WalletManager Function(BuildContext context) walletManagerOf;

  /// Where an unlock lands: the wallet's home screen, as a named route.
  final String homeRoute;

  /// The mark above the unlock screen.
  final WidgetBuilder logo;
}

/// Preference keys and choices for "Fully lock after".
class SecurityKeysPreferences {
  SecurityKeysPreferences._();

  /// Minutes in the background after which, with security keys on, the wallet
  /// is closed and its password forgotten. See [fullLockMinuteOptions].
  static const fullLockAfterMinutes = 'fullLockAfterMinutes';

  /// The "Fully lock after" choices, in minutes, and the default.
  static const fullLockMinuteOptions = [10, 30, 60, 1440];
  static const fullLockDefaultMinutes = 30;

  static Future<int> fullLockMinutes() async =>
      await SharedPreferencesService.get<int>(fullLockAfterMinutes) ?? fullLockDefaultMinutes;
}

/// Preference key and choices for App Lock's "Lock after".
///
/// App Lock is always on: the device's own prompt (Face ID, a fingerprint, the
/// passcode, Touch ID or the Mac's password) on Android, iOS and macOS, the
/// wallet password on Linux and Windows. This is how long the app may be away
/// first: in the background on a phone ([AppLockTimer]), without use on a
/// computer ([DesktopAutoLock.appLock]). It can be shortened or lengthened, not
/// turned off.
class AppLockPreferences {
  AppLockPreferences._();

  static const lockAfterMinutes = 'appLockAfterMinutes';

  /// The choices, in minutes: 0 is "Immediately".
  static const minuteOptions = [0, 1, 10, 60];
  static const defaultMinutes = 10;

  static Future<int> minutes() async {
    final stored = await SharedPreferencesService.get<int>(lockAfterMinutes);
    // Only the listed choices: anything else written there counts as the default.
    return minuteOptions.contains(stored) ? stored! : defaultMinutes;
  }

  static Future<void> setMinutes(int minutes) {
    if (!minuteOptions.contains(minutes)) throw ArgumentError.value(minutes, 'minutes');
    return SharedPreferencesService.set<int>(lockAfterMinutes, minutes);
  }

  /// The time without use after which a desktop OS shows App Lock. A computer
  /// has no "background": "Immediately" there locks as the window is hidden or
  /// minimised (the app's lifecycle observer does that) and otherwise after a
  /// minute without use, not at every pause in typing.
  static Future<Duration> desktopIdleLimit() async {
    final m = await minutes();
    return Duration(minutes: m == 0 ? 1 : m);
  }
}

WalletManager _manager(BuildContext context) => SecurityKeysUi.config.walletManagerOf(context);

/// What Settings > Advanced Security shows.
class SecurityKeysState {
  const SecurityKeysState({
    required this.available,
    required this.engaged,
    required this.keys,
    this.unreadable = false,
  });

  /// The wallet was created on a build whose password is FHSE's root, on a
  /// platform with a way to reach a key.
  final bool available;

  /// Keys are set up: the keystore no longer holds the wallet password.
  final bool engaged;
  final List<SecurityKeyRecord> keys;

  /// Keys are on but their file cannot be opened here (after a move to a new
  /// phone, whose keystore did not carry the file's outer password). Setting
  /// keys up again and turning them off both still work.
  final bool unreadable;
}

/// Never throws for a file it cannot open: that is [SecurityKeysState.unreadable],
/// so the screen can offer a way out rather than wait forever. The file is not
/// deleted: for a 25-word wallet it is the only copy of the password.
Future<SecurityKeysState> securityKeysState() async {
  final available = SecurityKeyService.isSupportedPlatform && await FhseVault.isAvailable();
  final engaged = await FhseVault.isEngaged();
  if (!engaged) return SecurityKeysState(available: available, engaged: false, keys: const []);
  try {
    return SecurityKeysState(available: available, engaged: true, keys: await FhseVault.keys());
  } catch (_) {
    return SecurityKeysState(available: available, engaged: true, keys: const [], unreadable: true);
  }
}

/// Whether security keys guard this wallet, for the home's security
/// checklist. Null where they cannot be set up: a platform with no way to
/// reach a key, or a wallet created before keys existed.
Future<bool?> securityKeysOn() async {
  if (!SecurityKeyService.isSupportedPlatform || !await FhseVault.isAvailable()) return null;
  return FhseVault.isEngaged();
}

/// True when the wallet cannot open until a security key releases its
/// password: keys are on and the password is not in memory.
Future<bool> walletNeedsSecurityKey(BuildContext context) => securityKeyCheck(context)();

/// [walletNeedsSecurityKey], bound now and asked later: for callers that only
/// know whether to ask after an async gap.
Future<bool> Function() securityKeyCheck(BuildContext context) {
  final manager = _manager(context);
  return () async => !manager.hasPassword && await manager.isPasswordGuarded();
}

/// True when keys are on and the wallet is open: what "Fully lock after" can
/// close.
Future<bool> walletIsUnlockedBehindSecurityKey(BuildContext context) async {
  final manager = _manager(context);
  return manager.hasPassword && await manager.isPasswordGuarded();
}

/// Opens the wallet with a security key, verified by its PIN or fingerprint,
/// then syncs.
Future<void> unlockWithSecurityKey(
  BuildContext context,
  KeyVerification verification,
  SecurityKeyAuthenticator key,
) async {
  final manager = _manager(context);
  await _awaitFullLock();
  final password = await FhseVault.unlock(authenticator: key, verification: verification);
  // A full lock that began while the key was being read must finish before the
  // wallets open again; it would otherwise close them under the new session.
  await _awaitFullLock();
  await manager.unlockWithGuardedPassword(password);
  manager.openWalletFilesAndSync();
}

/// Opens the wallet with its recovery phrase when every key is lost. Throws
/// FhseVaultException when the phrase is not this wallet's, or is a 25-word
/// one whose FHSE seed was random.
Future<void> unlockWithRecoveryPhrase(BuildContext context, String mnemonic) async {
  final manager = _manager(context);
  final seed = SeedSource.detect(mnemonic);
  if (seed == null) throw Exception('Invalid mnemonic.');
  await _awaitFullLock();
  final password = await FhseVault.recoverWithSeed(seed);
  await _awaitFullLock();
  await manager.unlockWithGuardedPassword(password);
  manager.openWalletFilesAndSync();
}

/// App Lock's way in when the device cannot confirm its owner (a lockout, a
/// prompt that keeps failing): the recovery phrase. Throws
/// `Exception('Invalid mnemonic.')` when it is not this wallet's.
///
/// The phrase is checked against the stored seed and the password comes back
/// from memory or the keystore ([WalletManager.unlockWithRecoveryPhrase]). With
/// security keys on and the wallet locked there is no password to check it
/// with, so the keys' own recovery opens it ([unlockWithRecoveryPhrase]): the
/// phrase stands in for the key too, as it does on the key screen, and this
/// returns true. No downgrade: whoever has the phrase has the wallet.
Future<bool> unlockAppLockWithRecoveryPhrase(BuildContext context, String mnemonic) async {
  final manager = _manager(context);
  await _awaitLocks();
  if (await manager.unlockWithRecoveryPhrase(mnemonic)) {
    if (manager.isSpendLocked) unawaited(manager.unlockSpend());
    return false;
  }
  if (!manager.hasPassword && await manager.isPasswordGuarded()) {
    if (!context.mounted) throw StateError('The unlock screen went away');
    await unlockWithRecoveryPhrase(context, mnemonic);
    return true;
  }
  throw Exception('Invalid mnemonic.');
}

/// Locks App Lock now ([WalletManager.armAppLockRelock]): [AppSession] locks
/// and the keystore password is dropped. Returns false with no wallet to lock.
/// The app's unlock paths wait for it ([waitForFullLock], [reopenAfterAppLock]),
/// so a prompt passed quickly cannot be undone by the relock finishing after it.
Future<bool> lockAppLock(BuildContext context) => _lockAppLock(_manager(context));

Future<bool>? _appLockInFlight;

Future<bool> _lockAppLock(WalletManager manager) async {
  final relock = manager.armAppLockRelock();
  _appLockInFlight = relock;
  try {
    return await relock;
  } finally {
    if (identical(_appLockInFlight, relock)) _appLockInFlight = null;
  }
}

/// Waits for an App Lock relock and a full lock under way.
Future<void> _awaitLocks() async {
  try {
    await _appLockInFlight;
  } catch (_) {}
  await _awaitFullLock();
}

/// The full lock under way, if any. One at a time: every caller (the timer, a
/// resume, a second resume) shares it, and the unlocks above wait for it.
Future<void>? _fullLockInFlight;

/// Closes the wallet and forgets its password and FHSE's unlocked copy: what
/// "Fully lock after" does once the time is up. Joins a lock already under way.
///
/// The secrets go first: the FHSE session here, and the password at the start
/// of [WalletManager.fullyLock], before the wallets are stored and closed, which
/// takes a while. Nothing still on screen can use either in the meantime.
Future<void> fullyLockWallet(BuildContext context) =>
    _fullLockInFlight ??= _fullyLock(_manager(context));

Future<void> _fullyLock(WalletManager manager) async {
  try {
    FhseVault.endSession();
    // With Continuous Sync on, the wallets keep watching for payments,
    // view-only ([WalletManager.lockSpend]); otherwise they close. Either way
    // the password and every spending key leave memory.
    final keepWatching =
        await SharedPreferencesService.get<bool>(SettingsKeys.foregroundSyncEnabled) ?? false;
    await (keepWatching ? manager.lockSpend() : manager.fullyLock());
  } finally {
    _fullLockInFlight = null;
  }
}

/// Locks the wallet, as "Fully lock after" does when its time is up, with the
/// unlock screen in front: for a screen that must lock by itself, such as the
/// recovery phrase check after repeated wrong answers. The stack goes first,
/// so nothing that was open stays reachable behind the unlock screen.
///
/// Bound now and run later: the wallet and the navigator are taken from
/// [context] here, so the lock still runs if that screen has been closed in
/// the meantime.
Future<void> Function() lockWalletAction(BuildContext context) {
  final manager = _manager(context);
  final navigator = Navigator.of(context);
  return () {
    navigator.pushNamedAndRemoveUntil('/unlock', (_) => false);
    return _fullLockInFlight ??= _fullyLock(manager);
  };
}

/// Waits for a full lock under way, for an app's own unlock path: it must not
/// reopen wallets that are still being closed. Waits for an App Lock relock
/// too ([lockAppLock]), which would otherwise drop the password just loaded.
Future<void> waitForFullLock() => _awaitLocks();

/// Waits for a full lock under way, so an unlock never reopens wallets that are
/// still being closed. A lock that failed does not stop the unlock.
Future<void> _awaitFullLock() async {
  try {
    await _fullLockInFlight;
  } catch (_) {}
}

/// Starts setting keys up from nothing (first time, or again to remove one).
Future<FhseSetup> beginSecurityKeySetup(BuildContext context) {
  final password = _manager(context).passwordForGuard;
  if (password == null) throw StateError('The wallet must be unlocked to set up security keys');
  return FhseVault.beginSetup(walletPassword: password);
}

/// Writes the keys set up in [setup] and takes the password out of the keystore.
Future<void> finishSecurityKeySetup(BuildContext context, FhseSetup setup) =>
    FhseWalletGuard.engage(setup, _manager(context));

/// Adds one key to keys that are already on, without tapping an existing one.
Future<SecurityKeyRecord> addSecurityKey({
  required SecurityKeyAuthenticator key,
  required KeyVerification verification,
  required String name,
}) => FhseVault.addKey(authenticator: key, verification: verification, name: name);

/// The keys registered for this wallet, with their names and serial numbers.
Future<List<SecurityKeyRecord>> registeredSecurityKeys() => FhseVault.keys();

/// Renames a key that is already on.
Future<void> renameSecurityKey(SecurityKeyRecord record, String name) =>
    FhseVault.renameKey(record.id, name);

/// Turns security keys off: the password goes back into the keystore.
Future<void> turnOffSecurityKeys(BuildContext context) =>
    FhseWalletGuard.release(_manager(context));

/// Nanoseconds on a clock the user cannot set, for the lock deadlines: FHSE's
/// boot clock ([FhseNative.bootClockNanos], which also counts sleep) where its
/// library loads, otherwise a monotonic clock in this process (which may stop
/// while the computer sleeps, so the wall clock may be the one that decides).
/// Null when unreadable.
int? lockClockNanos() {
  if (_nativeLockClock != false) {
    try {
      final ns = FhseNative.instance.bootClockNanos();
      _nativeLockClock = true;
      return ns;
    } catch (_) {
      _nativeLockClock = false;
    }
  }
  return _processClock.elapsedMicroseconds * 1000;
}

bool? _nativeLockClock;
final _processClock = Stopwatch()..start();

/// Whether this platform locks after a time without use ([DesktopAutoLock]):
/// the desktop OSes. Mobile locks after a time in the background instead
/// ([SecurityKeyFullLock]).
final bool isDesktopAutoLockPlatform = Platform.isMacOS || Platform.isLinux || Platform.isWindows;

/// After App Lock has let the user in: puts the keystore password back in
/// memory (an App Lock relock drops it) and takes the spend wallet back: the
/// wallets App Lock left view-only get their keys again, and closed ones open
/// ([WalletManager.unlockSpend]). Not awaited: the home screen shows the cached
/// balance meanwhile, and a send waits for the keys. Does nothing when
/// security keys hold the password; a key comes next ([walletNeedsSecurityKey]).
///
/// False when no password could be put back (the keystore has no copy, or a
/// full lock took it meanwhile): the wallet is not open, and App Lock stays.
Future<bool> reopenAfterAppLock(BuildContext context) => _reopenAfterAppLock(_manager(context));

Future<bool> _reopenAfterAppLock(WalletManager manager) async {
  await _awaitLocks();
  if (!manager.hasPassword) await manager.loadStoredPassword();
  if (!manager.hasPassword) return false;
  if (manager.isSpendLocked) unawaited(manager.unlockSpend());
  return true;
}

/// Where App Lock's unlock screen goes next ([unlockAppLockWithDevice],
/// [unlockAppLockWithPassword]). The screen only shows it: what each outcome
/// means is decided here, once for both apps.
enum AppLockUnlock {
  /// Past App Lock with nothing more to ask: the session is unlocked
  /// ([AppSession.markUnlocked]) and the wallet opening behind the home.
  unlocked,

  /// Past App Lock; with security keys on and the wallet closed, a key comes
  /// next.
  needsKey,

  /// The owner turned the device's prompt down. Stay quiet: the unlock button
  /// asks again.
  declined,

  /// The device could not confirm its owner (a lockout), or did but the wallet
  /// password could not be put back (no keystore copy): offer the recovery
  /// phrase ([showAppLockRecoveryPhrase]). With the typed password, the unlock
  /// failed for a reason other than the password.
  failed,

  /// The typed password is not the wallet's.
  wrongPassword,

  /// The wallet's files are bound to another PC's TPM (Windows).
  boundToAnotherPc,
}

/// App Lock at the unlock screen where the device's own prompt is App Lock
/// (Android, iOS, macOS): asks with [reason], then waits for a lock still
/// closing the wallets, and either hands over to a security key or puts the
/// keystore password back and reopens the wallet ([reopenAfterAppLock]).
Future<AppLockUnlock> unlockAppLockWithDevice(
  BuildContext context, {
  required String reason,
}) async {
  final manager = _manager(context);
  // Always asks (App Lock is always on); a device with no lock at all has
  // nothing to ask and passes, and Settings warns about it.
  final result = await BiometricAuth.confirmOwner(reason: reason);
  if (result == BiometricAuthResult.failed) return AppLockUnlock.declined;
  if (result == BiometricAuthResult.error) return AppLockUnlock.failed;
  // A full lock still closing the wallets decides what comes next.
  await _awaitLocks();
  // With security keys on and the wallet closed, a key comes next.
  if (!manager.hasPassword && await manager.isPasswordGuarded()) return AppLockUnlock.needsKey;
  if (!await _reopenAfterAppLock(manager)) {
    unawaited(log(LogLevel.error, 'App Lock passed but no wallet password came back'));
    return AppLockUnlock.failed;
  }
  AppSession.markUnlocked();
  return AppLockUnlock.unlocked;
}

/// App Lock at the unlock screen where the wallet password is typed (Linux,
/// Windows). After a time without use the wallet stayed open, so [password]
/// is only checked again ([WalletManager.checkTypedPassword]); otherwise it
/// opens the wallet, or, with security keys on, a key comes next. Never
/// throws: every failure is an outcome the screen can show.
Future<AppLockUnlock> unlockAppLockWithPassword(BuildContext context, String password) async {
  final manager = _manager(context);
  // A lock still closing the wallets finishes first, so it cannot drop the
  // password this unlock is about to set.
  await _awaitLocks();
  final bool stayedOpen;
  try {
    stayedOpen = manager.hasPassword;
    final right = stayedOpen
        ? await manager.checkTypedPassword(password)
        : await manager.unlockWithTypedPassword(password);
    if (!right) return AppLockUnlock.wrongPassword;
  } on BoundToAnotherPcException {
    return AppLockUnlock.boundToAnotherPc;
  } catch (e) {
    unawaited(log(LogLevel.error, 'Unlocking with the typed password failed: ${e.runtimeType}'));
    return AppLockUnlock.failed;
  }
  if (!stayedOpen) {
    // With security keys on, the password was right and a key comes next.
    if (!manager.hasPassword) return AppLockUnlock.needsKey;
    // The cached balances first, for the home to show, then the wallets open
    // behind it, as after App Lock on a phone.
    try {
      await manager.loadCachedDisplayState();
    } catch (e) {
      unawaited(log(LogLevel.warn, 'Cached balances not loaded: ${e.runtimeType}'));
    }
    unawaited(manager.unlockSpend());
  }
  AppSession.markUnlocked();
  return AppLockUnlock.unlocked;
}

/// Whether "Lock after" has anything to do on a desktop OS: the wallet is open
/// (its password in memory, or its files) and something will be asked for to
/// open it again:
/// the typed password (Linux, Windows), security keys, or App Lock (macOS).
/// Without any of these a lock would reopen at once, so it is skipped.
Future<bool> desktopAutoLockApplies(BuildContext context) async {
  final manager = _manager(context);
  // An App Lock relock drops the password but leaves the wallets open; those
  // still need closing.
  if (!manager.hasPassword && manager.loadedWallets.isEmpty) return false;
  if (!WalletSecrets.holdsWalletPassword) return true;
  if (await manager.isPasswordGuarded()) return true;
  // App Lock is always on, unless the Mac has no way to confirm its owner.
  return BiometricAuth.isAvailable();
}

/// "Lock after" on a desktop OS: once the app has gone
/// [SecurityKeysPreferences.fullLockMinutes] without use, the wallet is closed
/// and its password forgotten, and the app shows its unlock screen (the typed
/// password on Linux and Windows; App Lock and, with keys on, a key on macOS).
///
/// [DesktopAutoLock.appLock] is the same clock for App Lock's shorter
/// [AppLockPreferences.desktopIdleLimit]: the app covers itself with App Lock
/// and keeps the wallet open and syncing.
///
/// "Without use" means no pointer or key input reached the app while it was
/// unlocked: a window that is hidden, minimised or behind others gets none, so
/// this covers leaving the app as well as leaving the computer. Input at App
/// Lock's cover or the unlock screen is not use of the wallet, or typing
/// password guesses there would keep the wallet open behind the cover with no
/// end; an unlock is, and starts the time again. The time is measured as for "Fully
/// lock after" ([fullLockDue]): on the wall clock and on a clock the user
/// cannot set, either one deciding, so setting the date back does not skip it.
///
/// The app records use from its root ([recordUse]), calls [start] once with
/// what to do when the time is up, and calls [check] when the app comes back
/// to the front (timers can stall while a computer sleeps). The lock itself is
/// the app's: put the unlock screen up first, then [lock].
class DesktopAutoLock {
  /// "Lock after": [SecurityKeysPreferences.fullLockMinutes].
  DesktopAutoLock()
    : _readLimit = _fullLockLimit,
      _limit = const Duration(minutes: SecurityKeysPreferences.fullLockDefaultMinutes);

  /// App Lock's time without use: [AppLockPreferences.desktopIdleLimit].
  DesktopAutoLock.appLock()
    : _readLimit = AppLockPreferences.desktopIdleLimit,
      _limit = const Duration(minutes: AppLockPreferences.defaultMinutes);

  static Future<Duration> _fullLockLimit() async =>
      Duration(minutes: await SecurityKeysPreferences.fullLockMinutes());

  final Future<Duration> Function() _readLimit;
  DateTime _lastUse = SecurityKeyFullLock.wallClock();
  int? _lastUseBootNs = SecurityKeyFullLock.bootClock();
  Duration _limit;
  Timer? _ticker;
  Future<void> Function()? _onDue;
  bool _checking = false;

  /// How often the time is checked while the app runs.
  static const tick = Duration(seconds: 15);

  void start(Future<void> Function() onDue) {
    _onDue = onDue;
    _ticker?.cancel();
    _ticker = Timer.periodic(tick, (_) => unawaited(check()));
    AppSession.unlocked.removeListener(_onSessionChanged);
    AppSession.unlocked.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (AppSession.isUnlocked) _restart();
  }

  void _restart() {
    _lastUse = SecurityKeyFullLock.wallClock();
    _lastUseBootNs = SecurityKeyFullLock.bootClock();
  }

  /// Input reached the app. It counts only while [AppSession] is unlocked, and
  /// once the time has run out it locks instead: a computer that slept past the
  /// time gets input before the next [check], and that must not cancel the
  /// lock. Cheap enough for every pointer move: it reads the clocks at most
  /// once a second.
  void recordUse() {
    if (!AppSession.isUnlocked) return;
    final now = SecurityKeyFullLock.wallClock();
    final sinceLast = now.difference(_lastUse);
    if (!sinceLast.isNegative && sinceLast < const Duration(seconds: 1)) return;
    if (isDue) {
      unawaited(check());
      return;
    }
    _lastUse = now;
    _lastUseBootNs = SecurityKeyFullLock.bootClock();
  }

  /// Whether the time without use has run out, from the setting last read.
  bool get isDue => fullLockDue(
    limit: _limit,
    backgroundedAt: _lastUse,
    now: SecurityKeyFullLock.wallClock(),
    backgroundedBootNs: _lastUseBootNs,
    nowBootNs: SecurityKeyFullLock.bootClock(),
  );

  /// Re-reads the setting and, when the time has run out, runs the app's
  /// `onDue` once. Afterwards the time starts again from now.
  Future<void> check() async {
    final onDue = _onDue;
    if (onDue == null || _checking) return;
    _checking = true;
    try {
      _limit = await _readLimit();
      if (!isDue) return;
      await onDue();
      _restart();
    } finally {
      _checking = false;
    }
  }

  /// Closes the wallet and forgets its password ([fullyLockWallet]), joining
  /// a lock already under way.
  Future<void> lock(BuildContext context) => fullyLockWallet(context);

  void dispose() {
    _ticker?.cancel();
    _ticker = null;
    AppSession.unlocked.removeListener(_onSessionChanged);
  }
}

/// App Lock's "Lock after" on a phone, for the app's lifecycle observer: once
/// the app has been in the background for [AppLockPreferences.minutes], coming
/// back shows App Lock, and the password is dropped on the way
/// ([WalletManager.armAppLockRelock]). "Immediately" locks as the app leaves.
///
/// Timed like [SecurityKeyFullLock]: a [Timer] drops the password on time when
/// the process gets CPU, and [takeDueOnReturn] decides from the two clocks
/// ([fullLockDue]) either way, so setting the date back does not skip it. It is
/// synchronous, so the app can put App Lock up before it awaits anything; it
/// locks [AppSession] at once, before a payment link could land.
class AppLockTimer {
  DateTime? _backgroundedAt;
  int? _backgroundedBootNs;
  var _limit = const Duration(minutes: AppLockPreferences.defaultMinutes);
  Timer? _timer;
  bool _locked = false;

  /// Due on the last return with the timer not yet run: [lock] has it to do.
  bool _lockPending = false;

  /// Bumped on every return, so an [onBackground] still reading its setting
  /// when the app comes back does not arm a timer in the foreground.
  var _generation = 0;

  /// On background, with a wallet: note the time on both clocks and set the
  /// timer, or lock now for "Immediately". [context] must outlive the timer
  /// (the app root's).
  ///
  /// The clocks are read before anything is awaited, and kept at once when a
  /// wallet is open, measured against the setting last read: the OS can
  /// suspend the app before the checks below return, and a return that comes
  /// first still finds them.
  ///
  /// Not while App Lock itself is showing: the app is locked already, and the
  /// device's own prompt can send the app to the background (Android's PIN
  /// screen is another app), which must not lock it again mid-unlock.
  Future<void> onBackground(BuildContext context) async {
    final generation = _generation;
    final manager = _manager(context);
    final at = SecurityKeyFullLock.wallClock();
    final bootNs = SecurityKeyFullLock.bootClock();
    if (AppSession.isUnlocked) {
      _backgroundedAt = at;
      _backgroundedBootNs = bootNs;
    }
    final hasWallet = await manager.hasAnyExistingWallet();
    final minutes = hasWallet ? await AppLockPreferences.minutes() : null;
    if (generation != _generation) return;
    if (minutes == null) {
      _backgroundedAt = null;
      _backgroundedBootNs = null;
      return;
    }
    _backgroundedAt = at;
    _backgroundedBootNs = bootNs;
    _limit = Duration(minutes: minutes);
    _timer?.cancel();
    if (minutes == 0) {
      _timer = null;
      return _lock(manager);
    }
    _timer = Timer(_limit, () => unawaited(_lock(manager)));
  }

  Future<void> _lock(WalletManager manager) async {
    _timer = null;
    // Before the relock, not after: a return during it still shows App Lock.
    _locked = true;
    await _lockAppLock(manager);
  }

  /// On the way back from the background: whether App Lock must show, because
  /// the time is up or the timer already locked. Decided at once, before the
  /// timer is cancelled and before anything is awaited; when true, [AppSession]
  /// is locked here, and the app puts App Lock up and then calls [lock].
  bool takeDueOnReturn() {
    _generation++;
    final backgroundedAt = _backgroundedAt;
    final due =
        _locked ||
        (backgroundedAt != null &&
            fullLockDue(
              limit: _limit,
              backgroundedAt: backgroundedAt,
              now: SecurityKeyFullLock.wallClock(),
              backgroundedBootNs: _backgroundedBootNs,
              nowBootNs: SecurityKeyFullLock.bootClock(),
            ));
    _timer?.cancel();
    _timer = null;
    _backgroundedAt = null;
    _backgroundedBootNs = null;
    _lockPending = due && !_locked;
    _locked = false;
    if (due) AppSession.lock();
    return due;
  }

  /// Drops the password ([lockAppLock]) when [takeDueOnReturn] found the time
  /// up before the timer did. Nothing when the timer already locked: a second
  /// relock could land after an unlock that followed the first.
  Future<void> lock(BuildContext context) async {
    if (!_lockPending) return;
    _lockPending = false;
    await lockAppLock(context);
  }

  void dispose() => _timer?.cancel();
}

/// Whether "Fully lock after" is due: [limit] has passed since the app went to
/// the background on either clock, or the clocks cannot be trusted.
///
/// Due when the wall clock says [limit] has passed, or went backwards (set back
/// to skip the lock), or when the boot clock says [limit] has passed, cannot be
/// read, or went backwards (it never does within one process). The boot clock
/// keeps counting while the phone sleeps and cannot be set; the wall clock
/// covers a boot clock that undercounts. Either one alone could be fooled.
@visibleForTesting
bool fullLockDue({
  required Duration limit,
  required DateTime backgroundedAt,
  required DateTime now,
  required int? backgroundedBootNs,
  required int? nowBootNs,
}) {
  final wallElapsed = now.difference(backgroundedAt);
  if (wallElapsed.isNegative || wallElapsed >= limit) return true;
  if (backgroundedBootNs == null || nowBootNs == null || nowBootNs < backgroundedBootNs) {
    return true;
  }
  return Duration(microseconds: (nowBootNs - backgroundedBootNs) ~/ 1000) >= limit;
}

/// "Fully lock after", for the app's lifecycle observer: with security keys on,
/// closes the wallet and forgets its password once the app has been in the
/// background too long.
///
/// Two things decide it. A [Timer] closes the wallet on time when the process
/// gets CPU, which is often on Android and rarely for a suspended iOS app; it
/// does not run while Android sleeps. So on resume [takeDueOnResume] checks the
/// time itself ([fullLockDue]), on a boot clock the user cannot set as well as
/// the wall clock, so setting the date back does not skip the lock.
///
/// [takeDueOnResume] is synchronous, from what [onBackground] kept in memory,
/// so the app can put its lock screen up before it awaits anything, and only
/// then call [lock]: the screen it is leaving must not stay usable while the
/// wallets close.
class SecurityKeyFullLock {
  DateTime? _backgroundedAt;
  int? _backgroundedBootNs;
  var _limit = const Duration(minutes: SecurityKeysPreferences.fullLockDefaultMinutes);
  Timer? _timer;
  bool _fullyLocked = false;

  /// Bumped on every resume, so an [onBackground] still reading its setting
  /// when the app comes back does not arm a timer in the foreground.
  var _generation = 0;

  /// The boot clock ([lockClockNanos]); replaced in tests.
  @visibleForTesting
  static int? Function() bootClock = lockClockNanos;

  /// The wall clock; replaced in tests.
  @visibleForTesting
  static DateTime Function() wallClock = DateTime.now;

  /// On background, with security keys on and the wallet open: note the time on
  /// both clocks and set the timer. [context] must outlive the timer (the app
  /// root's).
  ///
  /// The clocks are read before anything is awaited, and kept at once when the
  /// wallet is open behind a key as far as is known without waiting, measured
  /// against the setting last read. The OS can suspend the app before the
  /// checks below return; the time away still counts from leaving, and a
  /// return that comes first still finds it.
  Future<void> onBackground(BuildContext context) async {
    final generation = _generation;
    final at = wallClock();
    final bootNs = bootClock();
    if (_manager(context).hasPassword && FhseVault.lastKnownEngaged) {
      _backgroundedAt = at;
      _backgroundedBootNs = bootNs;
    }
    final behindKey = await walletIsUnlockedBehindSecurityKey(context);
    final minutes = behindKey ? await SecurityKeysPreferences.fullLockMinutes() : null;
    if (generation != _generation || !context.mounted) return;
    if (minutes == null) {
      _backgroundedAt = null;
      _backgroundedBootNs = null;
      return;
    }
    _limit = Duration(minutes: minutes);
    _backgroundedAt = at;
    _backgroundedBootNs = bootNs;
    _timer?.cancel();
    _timer = Timer(_limit, () => unawaited(_lockFromTimer(context)));
  }

  /// On resume: whether the wallet must be fully locked, because the time is up
  /// or because the timer already did it. Decided at once, before the timer is
  /// cancelled and before anything is awaited. When true, the app replaces its
  /// stack with the lock screens first and then calls [lock].
  bool takeDueOnResume() {
    _generation++;
    final backgroundedAt = _backgroundedAt;
    final due =
        _fullyLocked ||
        (backgroundedAt != null &&
            fullLockDue(
              limit: _limit,
              backgroundedAt: backgroundedAt,
              now: wallClock(),
              backgroundedBootNs: _backgroundedBootNs,
              nowBootNs: bootClock(),
            ));
    _timer?.cancel();
    _timer = null;
    _backgroundedAt = null;
    _backgroundedBootNs = null;
    _fullyLocked = false;
    return due;
  }

  /// Closes the wallet and forgets its password, or waits for a full lock that
  /// is already under way (the timer's, say).
  Future<void> lock(BuildContext context) async {
    if (!context.mounted || !await walletIsUnlockedBehindSecurityKey(context)) {
      return _awaitFullLock();
    }
    if (!context.mounted) return _awaitFullLock();
    await fullyLockWallet(context);
  }

  Future<void> _lockFromTimer(BuildContext context) async {
    _timer = null;
    if (!context.mounted || !await walletIsUnlockedBehindSecurityKey(context)) return;
    if (!context.mounted) return;
    // Before the close, not after: a resume during it must still replace the
    // stack rather than return to the screen being locked.
    _fullyLocked = true;
    await fullyLockWallet(context);
  }

  void dispose() => _timer?.cancel();
}
