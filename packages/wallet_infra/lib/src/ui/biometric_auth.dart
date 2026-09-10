import 'package:local_auth/local_auth.dart';

import '../logging.dart';

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
}
