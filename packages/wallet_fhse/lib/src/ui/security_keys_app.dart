import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wallet_domain/wallet_domain.dart' show SeedSource, WalletManager;
import 'package:wallet_infra/wallet_infra.dart' show SharedPreferencesService;

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
  final password = await FhseVault.unlock(authenticator: key, verification: verification);
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
  final password = await FhseVault.recoverWithSeed(seed);
  await manager.unlockWithGuardedPassword(password);
  manager.openWalletFilesAndSync();
}

/// Closes the wallet and forgets its password and FHSE's unlocked copy: what
/// "Fully lock after" does once the time is up.
Future<void> fullyLockWallet(BuildContext context) async {
  await _manager(context).fullyLock();
  FhseVault.endSession();
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

/// "Fully lock after", for the app's lifecycle observer: with security keys on,
/// the timer that closes the wallet if the app stays in the background, and
/// whether that already happened. The timer only fires while the process gets
/// CPU (often on Android, rarely on a suspended iOS app), so the elapsed time
/// is also checked on resume, before anything is shown.
class SecurityKeyFullLock {
  DateTime? _backgroundedAt;
  Timer? _timer;
  bool _fullyLocked = false;

  /// On background, with security keys on and the wallet open: note the time
  /// and set the timer. [context] must outlive the timer (the app root's).
  Future<void> onBackground(BuildContext context) async {
    if (!await walletIsUnlockedBehindSecurityKey(context)) return;
    _backgroundedAt = DateTime.now();
    final minutes = await SecurityKeysPreferences.fullLockMinutes();
    _timer?.cancel();
    if (!context.mounted) return;
    _timer = Timer(Duration(minutes: minutes), () => unawaited(_fullyLock(context)));
  }

  /// On resume: true when the wallet was closed (now or while away), so the
  /// app replaces the stack with its lock screens rather than covering it.
  Future<bool> onResume(BuildContext context) async {
    _timer?.cancel();
    _timer = null;
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    final due =
        backgroundedAt != null &&
        DateTime.now().difference(backgroundedAt) >=
            Duration(minutes: await SecurityKeysPreferences.fullLockMinutes());
    if (!_fullyLocked && !due) return false;
    if (!context.mounted) return false;
    await _fullyLock(context);
    _fullyLocked = false;
    return true;
  }

  Future<void> _fullyLock(BuildContext context) async {
    if (!context.mounted || !await walletIsUnlockedBehindSecurityKey(context)) return;
    if (!context.mounted) return;
    await fullyLockWallet(context);
    _fullyLocked = true;
  }

  void dispose() => _timer?.cancel();
}
