import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart' show SecureScreenMixin;
import 'package:wallet_ui/wallet_ui.dart';

/// Screen readers, Switch Access and keyboards reach the shared controls, and
/// a covered secret stays out of the semantics tree until it is revealed.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: WalletUiLocalizations.localizationsDelegates,
      supportedLocales: WalletUiLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );

  group('Tappable', () {
    testWidgets('Tab reaches it and Enter or Space runs onTap', (tester) async {
      var taps = 0;
      await pump(tester, Tappable(onTap: () => taps++, child: const Text('Reveal')));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(taps, 2);
    });

    testWidgets('is a named button that a screen reader can tap', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await pump(
        tester,
        Tappable(onTap: () => taps++, semanticLabel: 'Copy', child: const Icon(Icons.copy)),
      );
      final node = find.bySemanticsLabel('Copy');
      expect(
        tester.getSemantics(node),
        matchesSemantics(
          label: 'Copy',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      tester.semantics.tap(find.semantics.byLabel('Copy'));
      expect(taps, 1);
      handle.dispose();
    });

    testWidgets('a toggle reads as a switch with its state', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, BrandSwitch(value: true, onChanged: (_) {}, semanticLabel: 'Tor'));
      expect(
        tester.getSemantics(find.bySemanticsLabel('Tor')),
        matchesSemantics(
          label: 'Tor',
          hasToggledState: true,
          isToggled: true,
          hasEnabledState: true,
          isEnabled: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('control: false adds no tab stop', (tester) async {
      var taps = 0;
      await pump(
        tester,
        Column(
          children: [
            Tappable(onTap: () => taps++, control: false, child: const Text('Padding')),
            Tappable(onTap: () => taps += 10, child: const Text('Control')),
          ],
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 10);
    });
  });

  testWidgets('settings toggle row is one switch named by its title', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, SettingsToggleTile(title: 'Notifications', value: false, onChanged: (_) {}));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Notifications')),
      matchesSemantics(
        label: 'Notifications',
        hasToggledState: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    handle.dispose();
  });

  // find.semantics searches the live semantics tree: what a screen reader or
  // accessibility service could actually be given.
  group('covered secrets', () {
    const words = ['abandon', 'ability', 'able', 'about'];

    testWidgets('seed words are not in the semantics tree until revealed', (tester) async {
      final handle = tester.ensureSemantics();
      Widget grid(bool revealed) =>
          SeedGrid(words: words, revealed: revealed, revealLabel: 'Tap to reveal', onReveal: () {});
      await pump(tester, grid(false));
      for (final word in words) {
        expect(find.semantics.byLabel(RegExp(word)), findsNothing);
      }
      expect(find.semantics.byLabel('Tap to reveal'), findsOne);

      await pump(tester, grid(true));
      expect(find.semantics.byLabel(RegExp('abandon')), findsOne);
      handle.dispose();
    });

    testWidgets('creating a password is a protected screen while open', (tester) async {
      SecureScreenMixin.resetForTesting();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: WalletUiLocalizations.localizationsDelegates,
          supportedLocales: WalletUiLocalizations.supportedLocales,
          home: CreatePasswordView(
            labels: const CreatePasswordLabels(
              title: 'Create Password',
              description: 'It unlocks this wallet.',
              passwordHint: 'Password',
              confirmPasswordHint: 'Confirm password',
              submit: 'Continue',
              fieldEmptyError: 'Enter a password',
              tooShortError: 'Too short',
              doNotMatchError: 'They do not match',
            ),
            loading: false,
            onSubmit: (_) {},
          ),
        ),
      );
      expect(SecureScreenMixin.mountedProtectedScreens, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(SecureScreenMixin.mountedProtectedScreens, 0);
    });

    testWidgets('a revealable key is not in the semantics tree until revealed', (tester) async {
      final handle = tester.ensureSemantics();
      const secret = '0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0';
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: WalletUiLocalizations.localizationsDelegates,
          supportedLocales: WalletUiLocalizations.supportedLocales,
          home: KeyRevealView(
            title: 'Secret Keys',
            revealLabel: 'Tap to reveal',
            onCopy: (_) {},
            fields: const [
              KeyRevealField(label: 'Secret View Key', value: secret, revealable: true),
            ],
          ),
        ),
      );
      expect(find.semantics.byLabel(RegExp(secret)), findsNothing);
      // The copy chip is named by the field, never by its value.
      expect(find.semantics.byLabel('Copy Secret View Key'), findsOne);

      await tester.tap(find.text('Tap to reveal'));
      await tester.pump();
      expect(find.semantics.byLabel(RegExp(secret)), findsOne);
      handle.dispose();
    });
  });
}
