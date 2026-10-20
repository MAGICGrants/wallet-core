import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart' show WalletSecrets;
import 'package:wallet_ui/wallet_ui.dart';

/// App Lock is always on: the unlock screen can offer the recovery phrase when
/// the device cannot confirm its owner, and the gates in front of secrets
/// always ask, except on a device with no lock at all.
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

  group('ReauthGate', () {
    const channel = MethodChannel('plugins.flutter.io/local_auth');

    setUp(() => WalletSecrets.holdsWalletPassword = true);
    tearDown(() {
      WalletSecrets.resetForTesting();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      );
    });

    void device({required Object? authenticate, bool hasLock = true}) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'authenticate' => authenticate is Exception ? throw authenticate : authenticate,
          'isDeviceSupported' => hasLock,
          _ => null,
        },
      );
    }

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const ReauthGate(reason: 'Show the seed', child: Text('the seed')),
                ),
              ),
              child: const Text('settings'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('settings'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the secret once the owner confirms', (tester) async {
      device(authenticate: true);
      await open(tester);
      expect(find.text('the seed'), findsOneWidget);
    });

    testWidgets('a declined prompt goes back without it', (tester) async {
      device(authenticate: false);
      await open(tester);
      expect(find.text('the seed'), findsNothing);
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('a lockout goes back without it', (tester) async {
      device(authenticate: PlatformException(code: 'LockedOut'));
      await open(tester);
      expect(find.text('the seed'), findsNothing);
    });

    testWidgets('a device with no lock at all has nothing to ask', (tester) async {
      device(authenticate: PlatformException(code: 'NotAvailable'), hasLock: false);
      await open(tester);
      expect(find.text('the seed'), findsOneWidget);
    });
  });
}
