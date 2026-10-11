import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wallet_domain/wallet_domain.dart' show SeedSource, WalletManager;
import 'package:wallet_infra/wallet_infra.dart' show SharedPreferencesService;

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

WalletManager _manager(BuildContext context) => SecurityKeysUi.config.walletManagerOf(context);

/// What Settings > Advanced security shows.
class SecurityKeysState {
  const SecurityKeysState({required this.available, required this.engaged, required this.keys});

  /// The wallet was created on a build whose password is FHSE's root, on a
  /// platform with a way to reach a key.
  final bool available;

  /// Keys are set up: the keystore no longer holds the wallet password.
  final bool engaged;
  final List<SecurityKeyRecord> keys;
}

Future<SecurityKeysState> securityKeysState() async {
  final available = SecurityKeyService.isSupportedPlatform && await FhseVault.isAvailable();
  final engaged = await FhseVault.isEngaged();
  return SecurityKeysState(
    available: available,
    engaged: engaged,
    keys: engaged ? await FhseVault.keys() : const [],
  );
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
    await manager.fullyLock();
  } finally {
    _fullLockInFlight = null;
  }
}

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

  /// The boot clock ([FhseNative.bootClockNanos]); replaced in tests.
  @visibleForTesting
  static int? Function() bootClock = () => FhseNative.instance.bootClockNanos();

  /// The wall clock; replaced in tests.
  @visibleForTesting
  static DateTime Function() wallClock = DateTime.now;

  /// On background, with security keys on and the wallet open: note the time on
  /// both clocks and set the timer. [context] must outlive the timer (the app
  /// root's).
  Future<void> onBackground(BuildContext context) async {
    final generation = _generation;
    if (!await walletIsUnlockedBehindSecurityKey(context)) return;
    final minutes = await SecurityKeysPreferences.fullLockMinutes();
    if (generation != _generation || !context.mounted) return;
    _limit = Duration(minutes: minutes);
    _backgroundedAt = wallClock();
    _backgroundedBootNs = bootClock();
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
