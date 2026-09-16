import 'package:local_auth/local_auth.dart';

import '../logging.dart';
import '../storage/preferences.dart';

/// Outcome of a [BiometricAuth.authenticate] prompt.
///
/// [failed] and [error] are kept distinct because callers treat them
/// differently: an auto-prompt with a password fallback (the unlock screen)
/// stays silent on [failed] (the user chose to type a password) but surfaces
/// [error] (something is misconfigured), while an explicit opt-in (the app-lock
/// toggle) reports both.
enum BiometricAuthResult { authenticated, failed, error }

/// Device biometric / passcode authentication, via `local_auth`.
class BiometricAuth {
  BiometricAuth._();

  /// Prompts for device authentication with [reason]. Returns [authenticated] on
  /// success, [failed] when the user declines or fails, and [error] when the
  /// platform throws (no enrolment, lockout, unavailable); errors are logged
  /// here, not thrown.
  static Future<BiometricAuthResult> authenticate({required String reason}) async {
    try {
      final ok = await LocalAuthentication().authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(useErrorDialogs: true, sensitiveTransaction: true),
      );
      return ok ? BiometricAuthResult.authenticated : BiometricAuthResult.failed;
    } catch (error) {
      log(LogLevel.error, 'Biometric authentication failed: $error');
      return BiometricAuthResult.error;
    }
  }

  /// [authenticate], but only when the user has app lock on; with it off this
  /// reports [authenticated] without prompting.
  ///
  /// For the re-authentication gates in front of already-unlocked screens (the
  /// seed and secret keys). Turning app lock off is the user saying this app
  /// does not ask the device who is holding the phone -- so a prompt that
  /// appears anyway reads as the setting being ignored. The gates that
  /// *establish* the lock (the toggle, the unlock screen) still prompt
  /// unconditionally; they are the setting, not a consequence of it.
  ///
  /// Shared rather than reimplemented per app so the two cannot drift, as with
  /// `WalletManager.armAppLockRelock`.
  static Future<BiometricAuthResult> authenticateIfAppLockEnabled({required String reason}) async {
    final appLockEnabled =
        await SharedPreferencesService.get<bool>(SettingsKeys.appLockEnabled) ?? false;
    if (!appLockEnabled) return BiometricAuthResult.authenticated;
    return authenticate(reason: reason);
  }
}
