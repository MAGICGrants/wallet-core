import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// Desktop keyboard use: the Back shortcut, Esc on open panels and dropdowns,
/// and focus moving into and out of a dropdown's list. These tests run on a
/// desktop host, where the shared widgets use their desktop layout.
void main() {
  Widget app(Widget home, {GlobalKey<NavigatorState>? navigatorKey}) => MaterialApp(
    navigatorKey: navigatorKey,
    localizationsDelegates: WalletUiLocalizations.localizationsDelegates,
    supportedLocales: WalletUiLocalizations.supportedLocales,
    builder: navigatorKey == null
        ? null
        : (context, child) => DesktopBackShortcut(navigatorKey: navigatorKey, child: child!),
    home: home,
  );

  group('Back shortcut', () {
    Future<void> pushSecond(WidgetTester tester, GlobalKey<NavigatorState> key) async {
      await tester.pumpWidget(app(const Text('first'), navigatorKey: key));
      key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('second')));
      await tester.pumpAndSettle();
      expect(find.text('second'), findsOneWidget);
    }

    testWidgets('Alt+Left goes back on Windows and Linux', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final key = GlobalKey<NavigatorState>();
      await pushSecond(tester, key);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(find.text('second'), findsNothing);
      expect(find.text('first'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Cmd+[ goes back on a Mac', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final key = GlobalKey<NavigatorState>();
      await pushSecond(tester, key);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.text('first'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the first screen stays', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(app(const Text('first'), navigatorKey: key));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(find.text('first'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('EscapeCloses', () {
    testWidgets('closes while active, not otherwise', (tester) async {
      var closed = 0;
      Widget panel(bool active) =>
          app(EscapeCloses(active: active, onClose: () => closed++, child: const Text('panel')));
      await tester.pumpWidget(panel(false));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, 0);
      await tester.pumpWidget(panel(true));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(closed, 1);
    });

    testWidgets('a dialog over the screen takes Esc for itself', (tester) async {
      var closed = 0;
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        app(
          EscapeCloses(onClose: () => closed++, child: const Text('panel')),
          navigatorKey: key,
        ),
      );
      showDialog<void>(context: key.currentContext!, builder: (_) => const Text('dialog'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(closed, 0);
      expect(find.text('dialog'), findsNothing);
    });
  });

  group('dropdown', () {
    final selected = <String>[];
    Widget picker() => app(
      Scaffold(
        body: Column(
          children: [
            const Text('Page text'),
            ReceiveAssetSelectorCard(
              coinSymbol: 'XMR',
              iconAsset: '',
              coinName: 'Monero',
              blockchainSubtitle: null,
              options: const [
                (coinSymbol: 'XMR', iconAsset: '', coinName: 'Monero'),
                (coinSymbol: 'BTC', iconAsset: '', coinName: 'Bitcoin'),
              ],
              onSelect: selected.add,
            ),
          ],
        ),
      ),
    );

    // The list's options sit in DropdownLayer's own focus scope.
    bool focusInList() {
      FocusNode? node = FocusManager.instance.primaryFocus;
      while (node != null) {
        if (node.debugLabel == 'DropdownLayer') return true;
        node = node.parent;
      }
      return false;
    }

    testWidgets('from the keyboard: focus goes into the list and back on Esc', (tester) async {
      await tester.pumpWidget(picker());
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Bitcoin'), findsOneWidget);
      expect(focusInList(), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Bitcoin'), findsNothing);
      expect(focusInList(), isFalse);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'ReceiveAssetSelector');
    });

    testWidgets('a tap on an option picks it', (tester) async {
      selected.clear();
      await tester.pumpWidget(picker());
      await tester.tap(find.text('Monero'));
      await tester.pumpAndSettle();
      // Hit-tested where the list is drawn, not on the barrier under it.
      await tester.tap(find.text('Bitcoin'));
      await tester.pumpAndSettle();
      expect(selected, ['BTC']);
      expect(find.text('Bitcoin'), findsNothing);
    });

    testWidgets('with the mouse: focus stays put, and Esc still closes', (tester) async {
      await tester.pumpWidget(picker());
      await tester.tap(find.text('Monero'));
      await tester.pumpAndSettle();
      expect(find.text('Bitcoin'), findsOneWidget);
      expect(focusInList(), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Bitcoin'), findsNothing);
    });

    testWidgets('screen readers get the list and a Close action, not the page', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(picker());
      // find.semantics searches the live semantics tree, where a hidden node
      // is gone (bySemanticsLabel would still find its render object's).
      expect(find.semantics.byLabel('Page text'), findsOne);
      await tester.tap(find.text('Monero'));
      await tester.pumpAndSettle();
      expect(find.semantics.byLabel('Page text'), findsNothing);
      expect(find.semantics.byLabel(RegExp('Bitcoin')), findsOne);

      tester.semantics.tap(find.semantics.byLabel('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Bitcoin'), findsNothing);
      expect(find.semantics.byLabel('Page text'), findsOne);
      handle.dispose();
    });
  });

  group('BrandTextField on desktop', () {
    testWidgets('autofocus takes focus, and Enter leaves it there', (tester) async {
      var submitted = 0;
      final controller = TextEditingController();
      await tester.pumpWidget(
        app(
          Scaffold(
            body: BrandTextField(
              controller: controller,
              hint: 'Password',
              autofocus: true,
              onSubmitted: (_) => submitted++,
            ),
          ),
        ),
      );
      await tester.pump();
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
      await tester.enterText(find.byType(EditableText), 'wrong');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(submitted, 1);
      expect(field.focusNode.hasFocus, isTrue);
    });
  });
}
