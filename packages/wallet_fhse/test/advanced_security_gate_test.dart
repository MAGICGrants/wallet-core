import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/security_keys_ui.dart';
import 'package:wallet_infra/wallet_infra.dart' show BiometricAuthResult;

/// Advanced Security asks who it is every time it opens: the device's own
/// authentication where App Lock exists, the wallet password on Linux and
/// Windows. The screen itself is stood in for by a text.

class _Manager extends WalletManager {
  _Manager() : super(coins: () => const []);

  final tried = <String>[];

  @override
  Future<bool> checkTypedPassword(String password) async {
    tried.add(password);
    return password == 'right';
  }
}

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

  tearDown(SecurityKeysUi.resetForTesting);

  Future<void> open(
    WidgetTester tester, {
    bool typesPassword = false,
    BiometricAuthResult device = BiometricAuthResult.authenticated,
    bool deviceHasLock = true,
  }) async {
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
                  builder: (_) => GuardedAdvancedSecurityScreen(
                    typesPassword: typesPassword,
                    authenticate: (_) async => device,
                    deviceCanAuthenticate: () async => deviceHasLock,
                    child: const Text('advanced security'),
                  ),
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
      await open(tester, device: BiometricAuthResult.failed);
      expect(find.text('advanced security'), findsNothing);
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('a device that is locked out goes back and says so', (tester) async {
      await open(tester, device: BiometricAuthResult.error);
      expect(find.text('advanced security'), findsNothing);
      expect(find.text('settings'), findsOneWidget);
      expect(find.text("Couldn't confirm it's you."), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a device with no lock at all has nothing to ask: it opens', (tester) async {
      await open(tester, device: BiometricAuthResult.error, deviceHasLock: false);
      expect(find.text('advanced security'), findsOneWidget);
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
      expect(find.text("That password isn't right."), findsOneWidget);
      expect(find.text('advanced security'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);

      await tester.enterText(find.byType(TextField), 'right');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('advanced security'), findsOneWidget);
      expect(manager.tried, ['wrong', 'right']);
    });

    testWidgets('going back never shows the screen', (tester) async {
      await open(tester, typesPassword: true);
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pumpAndSettle();
      expect(find.text('advanced security'), findsNothing);
      expect(find.text('settings'), findsOneWidget);
    });
  });
}
