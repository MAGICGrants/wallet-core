import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/security_keys_ui.dart';
import 'package:wallet_infra/wallet_infra.dart' show WalletSecrets;

/// Advanced Security needs a passing App Lock every time it opens: the device's
/// own prompt where the keystore holds the password, the wallet password on
/// Linux and Windows. The screen itself is stood in for by a text. (The gate
/// itself, a device with no lock included, is tested in app_lock_gate_test.)

class _Manager extends WalletManager {
  _Manager() : super(coins: () => const []);

  final tried = <String>[];

  @override
  Future<bool> checkTypedPassword(String password) async {
    tried.add(password);
    return password == 'right';
  }
}

const _localAuth = MethodChannel('plugins.flutter.io/local_auth');

void main() {
  late _Manager manager;

  setUp(() {
    manager = _Manager();
    SecurityKeysUi.install(
      SecurityKeysUiConfig(
        appName: 'Test Wallet',
        walletManagerOf: (_) => manager,
        homeRoute: '/home',
        logo: (_) => const SizedBox.shrink(),
      ),
    );
  });

  tearDown(() {
    SecurityKeysUi.resetForTesting();
    WalletSecrets.resetForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _localAuth,
      null,
    );
  });

  /// [typesPassword]: Linux and Windows. Otherwise the device's prompt answers
  /// [device] (an [Exception] is thrown).
  Future<void> open(
    WidgetTester tester, {
    bool typesPassword = false,
    Object? device = true,
  }) async {
    WalletSecrets.holdsWalletPassword = !typesPassword;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _localAuth,
      (call) async => switch (call.method) {
        'authenticate' => device is Exception ? throw device : device,
        'isDeviceSupported' => true,
        _ => null,
      },
    );
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: FhseLocalizations.localizationsDelegates,
        supportedLocales: FhseLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const GuardedAdvancedSecurityScreen(child: Text('advanced security')),
                ),
              ),
              child: const Text('settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('settings'));
    await tester.pumpAndSettle();
  }

  group('where App Lock exists (Android, iOS, macOS)', () {
    testWidgets('opens once the device confirms the owner', (tester) async {
      await open(tester);
      expect(find.text('advanced security'), findsOneWidget);
    });

    testWidgets('a declined prompt goes back, the screen never shown', (tester) async {
      await open(tester, device: false);
      expect(find.text('advanced security'), findsNothing);
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('a device that is locked out goes back and says so', (tester) async {
      await open(tester, device: PlatformException(code: 'LockedOut'));
      expect(find.text('advanced security'), findsNothing);
      expect(find.text('settings'), findsOneWidget);
      expect(find.text("Couldn't confirm it's you."), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('where the password is typed (Linux, Windows)', () {
    testWidgets('a wrong password is refused, the right one opens it', (tester) async {
      await open(tester, typesPassword: true);
      expect(find.text('advanced security'), findsNothing);
      expect(find.text('Enter your password'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Incorrect password.'), findsOneWidget);
      expect(find.text('advanced security'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);

      await tester.enterText(find.byType(TextField), 'right');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('advanced security'), findsOneWidget);
      expect(manager.tried, ['wrong', 'right']);
    });

    testWidgets('closing the password sheet goes back, the screen never shown', (tester) async {
      await open(tester, typesPassword: true);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text('advanced security'), findsNothing);
      expect(find.text('settings'), findsOneWidget);
    });
  });
}
