import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/security_keys_ui.dart';
import 'package:wallet_infra/wallet_infra.dart' show WalletSecrets;

/// A screen that needs a passing App Lock gets the platform's App Lock, asked
/// again every time: the device's own prompt where the keystore holds the
/// wallet password, the typed password on Linux and Windows. Driven through
/// the real platform switch ([WalletSecrets.holdsWalletPassword]) and the
/// real device check, with only the plugin underneath stood in.

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

  /// The device's lock: what `authenticate` answers (an [Exception] is
  /// thrown), and whether it has a lock at all.
  void device({required Object? authenticate, bool hasLock = true}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _localAuth,
      (call) async => switch (call.method) {
        'authenticate' => authenticate is Exception ? throw authenticate : authenticate,
        'isDeviceSupported' => hasLock,
        _ => null,
      },
    );
  }

  Future<void> open(WidgetTester tester) async {
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
                      const AppLockGate(reason: 'Show the phrase', child: Text('the phrase')),
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

  group('where the keystore holds the password (Android, iOS, macOS)', () {
    setUp(() => WalletSecrets.holdsWalletPassword = true);

    testWidgets('shows the secret once the device confirms the owner', (tester) async {
      device(authenticate: true);
      await open(tester);
      expect(find.text('the phrase'), findsOneWidget);
      expect(manager.tried, isEmpty);
    });

    testWidgets('a declined prompt goes back without it', (tester) async {
      device(authenticate: false);
      await open(tester);
      expect(find.text('the phrase'), findsNothing);
      expect(find.text('settings'), findsOneWidget);
    });

    testWidgets('a lockout goes back without it and says so', (tester) async {
      device(authenticate: PlatformException(code: 'LockedOut'));
      await open(tester);
      expect(find.text('the phrase'), findsNothing);
      expect(find.text("Couldn't confirm it's you."), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a device with no lock at all has nothing to ask', (tester) async {
      device(authenticate: PlatformException(code: 'NotAvailable'), hasLock: false);
      await open(tester);
      expect(find.text('the phrase'), findsOneWidget);
    });
  });

  group('where the password is typed (Linux, Windows)', () {
    setUp(() => WalletSecrets.holdsWalletPassword = false);

    testWidgets('asks for the password, not the device', (tester) async {
      var deviceAsked = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        _localAuth,
        (call) async {
          deviceAsked = true;
          return true;
        },
      );
      await open(tester);
      expect(find.text('the phrase'), findsNothing);
      expect(find.text('Enter your password'), findsOneWidget);
      expect(deviceAsked, isFalse);
    });

    testWidgets('a wrong password is refused, the right one shows it', (tester) async {
      await open(tester);
      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Incorrect password.'), findsOneWidget);
      expect(find.text('the phrase'), findsNothing);

      await tester.enterText(find.byType(TextField), 'right');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('the phrase'), findsOneWidget);
      expect(manager.tried, ['wrong', 'right']);
    });

    testWidgets('closing the password sheet goes back without it', (tester) async {
      await open(tester);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text('the phrase'), findsNothing);
      expect(find.text('settings'), findsOneWidget);
      expect(manager.tried, isEmpty);
    });
  });

  testWidgets('a sheet opened after passAppLock waits for the password', (tester) async {
    WalletSecrets.holdsWalletPassword = false;
    bool? passed;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: FhseLocalizations.localizationsDelegates,
        supportedLocales: FhseLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => passed = await passAppLock(context, reason: 'Show keys'),
              child: const Text('view keys'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('view keys'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the password you use to unlock Test Wallet.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'right');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(passed, isTrue);
  });
}
