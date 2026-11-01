import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ui/wallet_ui.dart';

/// Onboarding's Tor step starts on Built-in, the recommended mode, in both apps
/// and on the desktop screens too, as the price step starts on Tor-Only. Only
/// Continue reports a choice: the app saves it there, and only then starts Tor.
void main() {
  const labels = TorChoiceLabels(
    title: 'Tor',
    subtitle: 'How should the wallet use Tor?',
    builtIn: 'Built-in',
    builtInDesc: 'Bundled',
    external: 'External',
    externalDesc: 'Orbot',
    noTor: 'No Tor',
    noTorDesc: 'Servers see your IP',
    socksPortLabel: 'SOCKS Port',
    orbotLabel: 'Use Orbot',
    testButton: 'Test',
    connected: 'Connected',
    testFailed: 'Failed',
    continueText: 'Next',
  );

  Future<List<int>> pumpView(WidgetTester tester) async {
    final continued = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TorChoiceView(
          labels: labels,
          onTest: (_) async => false,
          onContinue: ({required modeIndex, required port, required useOrbot}) =>
              continued.add(modeIndex),
          stepCount: 4,
          stepIndex: 0,
        ),
      ),
    );
    return continued;
  }

  bool isSelected(WidgetTester tester, String title) =>
      tester.widget<ModeSelectCard>(find.widgetWithText(ModeSelectCard, title)).selected;

  bool canContinue(WidgetTester tester) =>
      tester.widget<BrandButton>(find.widgetWithText(BrandButton, 'Next')).onPressed != null;

  testWidgets('Built-in starts selected, and Continue reports it', (tester) async {
    final continued = await pumpView(tester);
    expect(isSelected(tester, 'Built-in'), isTrue);
    expect(isSelected(tester, 'External'), isFalse);
    expect(isSelected(tester, 'No Tor'), isFalse);
    expect(canContinue(tester), isTrue);
    expect(continued, isEmpty, reason: 'a preselection is not a choice');

    await tester.tap(find.text('Next'));
    expect(continued, [0]);
  });

  testWidgets('selecting reports nothing until Continue', (tester) async {
    final continued = await pumpView(tester);
    await tester.tap(find.text('No Tor'));
    await tester.pump();
    expect(isSelected(tester, 'No Tor'), isTrue);
    expect(isSelected(tester, 'Built-in'), isFalse);
    expect(continued, isEmpty);

    await tester.tap(find.text('Next'));
    expect(continued, [2]);
  });

  testWidgets('External waits for a passing connection test', (tester) async {
    await pumpView(tester);
    await tester.tap(find.text('External'));
    await tester.pump();
    expect(canContinue(tester), isFalse);
  });
}
