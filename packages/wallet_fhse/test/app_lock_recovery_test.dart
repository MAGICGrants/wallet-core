import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/security_keys_ui.dart';
import 'package:wallet_infra/wallet_infra.dart' show SecureScreenMixin;

/// App Lock's "Use recovery phrase", for a device that cannot confirm its
/// owner: the phrase checked against the wallet opens it, any other is refused.

const _phrase =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon address';

class _Manager extends WalletManager {
  _Manager() : super(coins: () => const []);

  final tried = <String>[];
  int opens = 0;

  @override
  Future<bool> unlockWithRecoveryPhrase(String mnemonic) async {
    tried.add(mnemonic);
    return mnemonic == _phrase;
  }

  @override
  Future<bool> isPasswordGuarded() async => false;

  /// Locked, as after App Lock: the phrase's unlock takes the keys back.
  @override
  bool get isSpendLocked => true;

  @override
  Future<void> unlockSpend() async => opens++;
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

  Future<List<bool>> open(WidgetTester tester) async {
    final results = <bool>[];
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
              onPressed: () async => results.add(await showAppLockRecoveryPhrase(context)),
              child: const Text('locked'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('locked'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('another phrase is refused and nothing opens', (tester) async {
    await open(tester);
    expect(find.textContaining('your recovery phrase opens Test Wallet'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'legal winner thank year');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text("That recovery phrase is not this wallet's."), findsOneWidget);
    expect(manager.opens, 0);
  });

  testWidgets("the wallet's phrase opens it", (tester) async {
    final results = await open(tester);
    await tester.enterText(find.byType(TextField), _phrase);
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(results, [true]);
    expect(manager.opens, 1);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the phrase sheet is screen-protected and keeps nothing in the keyboard', (
    tester,
  ) async {
    SecureScreenMixin.resetForTesting();
    final results = await open(tester);
    expect(SecureScreenMixin.mountedProtectedScreens, 1);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(results, [false]);
    expect(SecureScreenMixin.mountedProtectedScreens, 0);
  });

  testWidgets('dismissed: still locked', (tester) async {
    final results = await open(tester);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(results, [false]);
  });
}
