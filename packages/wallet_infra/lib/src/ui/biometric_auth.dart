import 'package:local_auth/local_auth.dart';

import '../logging.dart';

/// Outcome of a [BiometricAuth.authenticate] prompt.
///
/// [failed] and [error] are kept distinct because callers treat them
/// differently: an auto-prompt with a password fallback (the unlock screen)
/// stays silent on [failed] (the user declined, and can try again) but surfaces
/// [error] (a lockout, something misconfigured).
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

  /// Whether this device can authenticate its owner at all: biometrics, or a
  /// passcode or screen lock. False on a device with no lock set up, where
  /// [authenticate] can only fail.
  ///
  /// True when the device cannot say: false lets the caller skip a prompt, so
  /// a check that fails must never be read as "no lock".
  static Future<bool> isAvailable() async {
    try {
      return await LocalAuthentication().isDeviceSupported();
    } catch (error) {
      log(LogLevel.warn, 'Could not tell whether device authentication is set up: $error');
      return true;
    }
  }

  /// [authenticate], for App Lock and the checks behind it (the unlock
  /// screen, the seed, secret keys): always asks, except on a device with no
  /// lock at all (no passcode, no biometrics), where there is nothing to ask and
  /// this reports [authenticated]. The app warns about that in Settings.
  ///
  /// No downgrade: the lock cannot be taken off the device without passing it,
  /// and a device that has one but cannot use it right now (a lockout) gets
  /// [error], not a way in. Shared so the apps and their gates cannot drift.
  static Future<BiometricAuthResult> confirmOwner({required String reason}) async {
    final result = await authenticate(reason: reason);
    if (result == BiometricAuthResult.error && !await isAvailable()) {
      return BiometricAuthResult.authenticated;
    }
    return result;
  }
}
