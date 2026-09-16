import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// The re-authentication gates in front of the seed and secret keys follow the
/// app-lock setting: with app lock off there is no prompt, because the user has
/// said this app does not ask the device who is holding the phone.
///
/// Under `flutter test` there is no platform to prompt on, so an attempt to
/// prompt can only come back as [BiometricAuthResult.error]. That is what
/// separates "skipped the prompt" from "tried to prompt" here -- the error the
/// third case logs is the prompt being attempted, and is expected.
void main() {
  setUp(() => SharedPreferencesService.store = MemoryPreferenceStore());
  tearDown(SharedPreferencesService.resetForTesting);

  group('authenticateIfAppLockEnabled', () {
    test('app lock unset: passes without prompting', () async {
      expect(
        await BiometricAuth.authenticateIfAppLockEnabled(reason: 'reveal the seed'),
        BiometricAuthResult.authenticated,
      );
    });

    test('app lock off: passes without prompting', () async {
      await SharedPreferencesService.set<bool>(SettingsKeys.appLockEnabled, false);
      expect(
        await BiometricAuth.authenticateIfAppLockEnabled(reason: 'reveal the seed'),
        BiometricAuthResult.authenticated,
      );
    });

    test('app lock on: still prompts', () async {
      await SharedPreferencesService.set<bool>(SettingsKeys.appLockEnabled, true);
      expect(
        await BiometricAuth.authenticateIfAppLockEnabled(reason: 'reveal the seed'),
        isNot(BiometricAuthResult.authenticated),
      );
    });
  });
}
