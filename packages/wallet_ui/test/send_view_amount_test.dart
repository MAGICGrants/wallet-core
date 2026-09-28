import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fiat/wallet_fiat.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_ui/wallet_ui.dart';

class _Quotes extends ChangeNotifier implements FiatQuoteSource {
  FiatQuote? quote = (currency: FiatCurrency.usd, rate: 356.03);

  @override
  FiatQuote? quoteFor(String coinSymbol) => quote;

  void set(FiatQuote? next) {
    quote = next;
    notifyListeners();
  }
}

const _labels = SendLabels(
  title: 'Send',
  toLabel: 'To',
  amount: 'Amount',
  priorityHeading: 'Priority',
  networkFee: 'Network fee',
  sendButton: 'Send',
  cancel: 'Cancel',
  pasteButton: 'Paste',
  scanButton: 'Scan',
  contactsButton: 'Contacts',
  maxButton: 'MAX',
  addressHint: 'Address',
  priorityLabels: ['Low', 'Normal', 'High'],
  switchUnit: 'Switch amount unit',
);

void main() {
  late _Quotes quotes;
  late AmountEntryController amount;

  setUp(() {
    SharedPreferencesService.store = MemoryPreferenceStore();
    quotes = _Quotes();
    amount = AmountEntryController(
      quotes: quotes,
      coinSymbol: 'XMR',
      coinDecimals: 12,
      restoreUnit: false,
    );
  });

  tearDown(() {
    amount.dispose();
    SharedPreferencesService.resetForTesting();
  });

  Future<void> pump(
    WidgetTester tester, {
    String? availableText = '1.23 available',
    double width = 360,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: SendView(
          labels: _labels,
          onBack: () {},
          addressController: TextEditingController(),
          addressError: '',
          openAliasResolving: false,
          onPaste: () {},
          onPickContact: () {},
          amount: amount,
          amountError: '',
          onMax: () => amount.setMax(BigInt.parse('1234567890123')),
          availableText: availableText,
          selectedPriority: 1,
          onSelectPriority: (_) {},
          feeValue: const Text('—'),
          onCancel: () {},
          onSend: null,
        ),
      ),
    );
  }

  Finder amountFieldFinder() =>
      find.byWidgetPredicate((w) => w is TextField && w.controller == amount.field);

  double amountFontSize(WidgetTester tester) {
    final field = tester.widget<TextField>(
      find.byWidgetPredicate((w) => w is TextField && w.controller == amount.field),
    );
    return field.style!.fontSize!;
  }

  testWidgets('the unit chip swaps entry and shows the other unit underneath', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byWidgetPredicate((w) => w is TextField && w.controller == amount.field),
      '0.5',
    );
    await tester.pump();

    expect(find.text('XMR'), findsOneWidget);
    expect(find.text('≈ \$178.02'), findsOneWidget);
    expect(find.text('1 XMR ≈ \$356.03'), findsOneWidget);

    await tester.tap(find.text('XMR'));
    await tester.pump();

    expect(amount.unit, AmountUnit.fiat);
    expect(find.text('USD'), findsOneWidget);
    expect(find.text('\$'), findsOneWidget); // the prefix
    expect(find.text('0.5 XMR'), findsOneWidget);
  });

  testWidgets('tapping the converted amount swaps too', (tester) async {
    await pump(tester);
    amount.field.text = '0.5';
    await tester.pump();

    await tester.tap(find.text('≈ \$178.02'));
    await tester.pump();
    expect(amount.unit, AmountUnit.fiat);
  });

  testWidgets('a long amount shrinks to fit instead of scrolling', (tester) async {
    // The test font's glyphs are 1em wide, twice Ubuntu Mono's, so this uses
    // the view's full 480px to stand in for a phone with the real font.
    await pump(tester, width: 480);
    amount.field.text = '1';
    await tester.pump();
    expect(amountFontSize(tester), 26);

    amount.field.text = '12345678.123456789012';
    await tester.pump();

    expect(tester.takeException(), isNull);
    final size = amountFontSize(tester);
    expect(size, lessThan(26));

    // The whole amount is laid out within the field: nothing to scroll to.
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: amountFieldFinder(), matching: find.byType(Scrollable)),
    );
    expect(scrollable.position.maxScrollExtent, 0);
  });

  testWidgets('with no rate there is no chip, conversion, or rate line', (tester) async {
    quotes.set(null);
    await pump(tester);
    amount.field.text = '0.5';
    await tester.pump();

    expect(find.byIcon(Icons.swap_vert), findsNothing);
    expect(find.textContaining('≈'), findsNothing);
    expect(find.text('XMR'), findsOneWidget);
  });

  testWidgets('losing the rate mid-entry hides the swap and keeps the amount', (tester) async {
    await pump(tester);
    amount.swap();
    amount.field.text = '150';
    await tester.pump();

    quotes.set(null);
    await tester.pump();

    expect(amount.unit, AmountUnit.coin);
    expect(amount.field.text, '0.421312810718');
    expect(find.byIcon(Icons.swap_vert), findsNothing);
    expect(find.textContaining('≈'), findsNothing);
  });

  testWidgets('without an available line the bottom line is the rate alone', (tester) async {
    await pump(tester, availableText: null);
    expect(find.text('1 XMR ≈ \$356.03'), findsOneWidget);
  });
}
