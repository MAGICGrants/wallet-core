import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_ui/wallet_ui.dart';

final _strings = lookupWalletUiLocalizations(const Locale('en'));
final _now = DateTime.utc(2026, 11, 2, 12);
const LabeledAddressCoin _xmr = (
  coinSymbol: 'XMR',
  baseUnitDecimals: 12,
  kind: RotatingAddressKind.subaddress,
);

UsedReceiveAddress _used(int index, {int ago = 3600, int txs = 1, int piconero = 250000000000}) =>
    UsedReceiveAddress(
      address: '8address$index${'x' * 80}',
      index: index,
      receivedBaseUnits: BigInt.from(piconero),
      txCount: txs,
      lastUsed: _now.millisecondsSinceEpoch ~/ 1000 - ago,
    );

void main() {
  tearDown(() => debugIsDesktopModalOverride = null);

  group('timeAgo', () {
    String ago(Duration d) => timeAgo(_strings, _now.subtract(d), now: _now);

    test('words it as timeago did', () {
      expect(ago(const Duration(seconds: 10)), 'a moment ago');
      expect(ago(const Duration(seconds: 60)), 'a minute ago');
      expect(ago(const Duration(minutes: 5)), '5 minutes ago');
      expect(ago(const Duration(minutes: 50)), 'about an hour ago');
      expect(ago(const Duration(hours: 3)), '3 hours ago');
      expect(ago(const Duration(hours: 30)), 'a day ago');
      expect(ago(const Duration(days: 9)), '9 days ago');
      expect(ago(const Duration(days: 40)), 'about a month ago');
      expect(ago(const Duration(days: 150)), '5 months ago');
      expect(ago(const Duration(days: 400)), 'about a year ago');
      expect(ago(const Duration(days: 1000)), '3 years ago');
      expect(ago(const Duration(seconds: -30)), 'a moment ago', reason: 'a clock running ahead');
    });
  });

  group('LabeledAddressList', () {
    final opened = <int>[];
    final labelled = <int>[];

    Future<void> pump(WidgetTester tester, List<LabeledAddress>? entries) async {
      opened.clear();
      labelled.clear();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LabeledAddressList(
                strings: _strings,
                coin: _xmr,
                entries: entries,
                now: _now,
                onOpen: (e) => opened.add(e.used.index),
                onLabel: (e) => labelled.add(e.used.index),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('labeled rows by label, the rest with a Label button and when they were used', (
      tester,
    ) async {
      await pump(tester, [
        (used: _used(9, ago: 3 * 3600), label: null),
        (used: _used(12, txs: 7, piconero: 4215000000000), label: 'Donations'),
      ]);
      expect(find.text('Used Subaddresses · 2'.toUpperCase()), findsOneWidget);
      expect(find.text('Subaddress #9'), findsOneWidget);
      expect(find.text('Last used 3 hours ago'), findsOneWidget);
      expect(find.text('Donations'), findsOneWidget);
      expect(find.text('4.2150 XMR'), findsOneWidget, reason: 'four decimals, not twelve');
      expect(find.text('7 transactions'), findsOneWidget);

      await tester.tap(find.text('Donations'));
      await tester.tap(find.text('Label'));
      expect(opened, [12]);
      expect(labelled, [9]);
    });

    testWidgets('Hide Unlabeled is off until tapped, then leaves the labeled ones', (tester) async {
      await pump(tester, [(used: _used(9), label: null), (used: _used(12), label: 'Donations')]);
      expect(find.text('Subaddress #9'), findsOneWidget);

      await tester.tap(find.text('Hide Unlabeled'));
      await tester.pump();
      expect(find.text('Subaddress #9'), findsNothing);
      expect(find.text('Donations'), findsOneWidget);
      expect(find.text('Labeled Subaddresses · 1'.toUpperCase()), findsOneWidget);
    });

    testWidgets('nothing used yet says so; still loading spins', (tester) async {
      await pump(tester, const []);
      expect(find.text('No used subaddresses yet'), findsOneWidget);
      await pump(tester, null);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('showAddressLabelSheet', () {
    String? result;
    var closed = false;

    Future<void> open(WidgetTester tester, {String? initial}) async {
      result = null;
      closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showAddressLabelSheet(
                    context: context,
                    strings: _strings,
                    coin: _xmr,
                    used: _used(11, ago: 9 * 86400),
                    initialLabel: initial,
                    now: _now,
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('saves what was typed, trimmed; Cancel saves nothing', (tester) async {
      debugIsDesktopModalOverride = false;
      await open(tester);
      expect(find.text('Label Subaddress #11'), findsOneWidget);
      expect(find.text('Last used 9 days ago'), findsOneWidget);
      expect(find.text('LABEL'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '  Market stall ');
      await tester.tap(find.text('Save Label'));
      await tester.pumpAndSettle();
      expect((closed, result), (true, 'Market stall'));

      await open(tester, initial: 'Market stall');
      expect(find.text('Market stall'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((closed, result), (true, null));
    });

    testWidgets('clearing the field saves a removal', (tester) async {
      debugIsDesktopModalOverride = false;
      await open(tester, initial: 'Old');
      await tester.enterText(find.byType(TextField), '');
      await tester.tap(find.text('Save Label'));
      await tester.pumpAndSettle();
      expect(result, '');
    });

    testWidgets('on desktop, in a modal with Cancel beside Save', (tester) async {
      debugIsDesktopModalOverride = true;
      await open(tester);
      expect(find.byType(DesktopModalCard), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Save Label'), findsOneWidget);
    });
  });
}
