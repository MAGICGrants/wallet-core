import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// A shared sub-page sits in the app's desktop frame only when opened from
/// inside it (`arguments: true`), and its back link says where it returns.
void main() {
  const shellKey = Key('shell');
  final chrome = SubPageChrome(
    back: 'Back',
    parent: 'Settings',
    desktopShell: (page) => KeyedSubtree(
      key: shellKey,
      child: Material(child: page),
    ),
  );

  Future<void> open(WidgetTester tester, {required bool inShell}) {
    return tester.pumpWidget(
      MaterialApp(
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: RouteSettings(name: settings.name, arguments: inShell),
          builder: (_) => SubPageScaffold(title: 'Terms', chrome: chrome, child: const SizedBox()),
        ),
      ),
    );
  }

  testWidgets('from Settings: in the frame, back to Settings', (tester) async {
    if (!isDesktopLayout) return; // the frame is desktop-only; tests run on one
    await open(tester, inShell: true);

    expect(find.byKey(shellKey), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Terms'), findsOneWidget);
  });

  testWidgets('from onboarding: no frame, plain Back', (tester) async {
    if (!isDesktopLayout) return;
    await open(tester, inShell: false);

    expect(find.byKey(shellKey), findsNothing);
    expect(find.text('Back'), findsOneWidget);
  });
}
