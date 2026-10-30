import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// App Lock is always on: the unlock screen can offer the recovery phrase when
/// the device cannot confirm its owner. (The gate in front of secrets,
/// AppLockGate, is tested in wallet_fhse.)
void main() {
  group('UnlockView', () {
    Future<void> show(
      WidgetTester tester, {
      String? recoveryLabel,
      VoidCallback? onRecovery,
    }) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: UnlockView(
            logo: const SizedBox.shrink(),
            labels: const UnlockLabels(
              title: 'Locked',
              passwordHint: 'Password',
              unlockButton: 'Unlock',
            ),
            isDesktop: false,
            passwordController: TextEditingController(),
            obscure: true,
            onToggleObscure: () {},
            onUnlockPassword: () {},
            onUnlockBiometric: () {},
            recoveryLabel: recoveryLabel,
            onUseRecoveryPhrase: onRecovery,
          ),
        ),
      );
    }

    testWidgets('no recovery phrase until the app offers it', (tester) async {
      await show(tester, onRecovery: () {});
      expect(find.text('Use recovery phrase'), findsNothing);
    });

    testWidgets('offered: one tap away', (tester) async {
      var used = 0;
      await show(tester, recoveryLabel: 'Use recovery phrase', onRecovery: () => used++);
      await tester.tap(find.text('Use recovery phrase'));
      expect(used, 1);
    });
  });
}
