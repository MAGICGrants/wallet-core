import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fiat/wallet_fiat.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_ui/wallet_ui.dart';

final _strings = lookupWalletUiLocalizations(const Locale('en'));

void main() {
  setUp(() => SharedPreferencesService.store = MemoryPreferenceStore());
  tearDown(SharedPreferencesService.resetForTesting);

  Future<FiatRateModel> open(WidgetTester tester, {List<TrimPreviewCoin>? coins}) async {
    final fiatRate = FiatRateModel();
    addTearDown(fiatRate.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showTrimDecimalsSheet(
                context,
                fiatRate: fiatRate,
                strings: _strings,
                coins: coins ?? const [(coinSymbol: 'XMR', baseUnitDecimals: 12)],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return fiatRate;
  }

  testWidgets('offers Off and the three levels in the display currency', (tester) async {
    await open(tester);
    expect(find.text('Trim Decimals'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Every digit'), findsOneWidget);
    expect(find.text(r'Below $0.01'), findsOneWidget);
    expect(find.text(r'Below $0.10'), findsOneWidget);
    expect(find.text(r'Below $1.00'), findsOneWidget);
  });

  testWidgets('with no price yet, the levels say they wait for one', (tester) async {
    await open(tester);
    expect(find.text('Starts once prices load'), findsNWidgets(3));
    expect(find.textContaining('Prices are still loading'), findsOneWidget);
  });

  testWidgets('saved digits preview the levels while prices load', (tester) async {
    await SharedPreferencesService.set<String>(
      SettingsKeys.trimDigits,
      SavedTrimDigits.empty.withRate('XMR', 152.37, FiatCurrency.usd).encode(),
    );
    await FiatRateModel.saveFiatApiMode(FiatApiMode.disabled);
    final fiatRate = await open(tester);
    // Loaded as a disabled API, so nothing is fetched; then switched back on
    // in memory the way the app's own start would leave it.
    await FiatRateModel.saveFiatApiMode(FiatApiMode.torOnly);
    await tester.runAsync(() async {
      FiatRates.getTorProxy = () async => null;
      await fiatRate.startService();
    });
    await tester.pumpAndSettle();
    expect(find.text('1.23456 XMR'), findsOneWidget);
    expect(find.text('1.2345 XMR'), findsOneWidget);
    expect(find.text('1.234 XMR'), findsOneWidget);

    // Stops the poll and retry timers the start armed.
    await tester.runAsync(() async {
      await FiatRateModel.saveFiatApiMode(FiatApiMode.disabled);
      await fiatRate.startService();
    });
  });

  testWidgets('tapping a level applies and saves it at once', (tester) async {
    final fiatRate = await open(tester);
    expect(fiatRate.trimDecimals, TrimDecimals.belowOne);

    await tester.tap(find.text(r'Below $0.10'));
    await tester.pumpAndSettle();

    expect(fiatRate.trimDecimals, TrimDecimals.belowTen);
    expect(await SharedPreferencesService.get<String>(SettingsKeys.trimDecimals), '10');
  });

  test('the row value names the level in the display currency', () {
    expect(trimDecimalsValue(_strings, TrimDecimals.off, FiatCurrency.usd), 'Off');
    expect(trimDecimalsValue(_strings, TrimDecimals.belowOne, FiatCurrency.usd), r'Below $0.01');
    expect(trimDecimalsValue(_strings, TrimDecimals.belowOne, FiatCurrency.jpy), 'Below ¥1');
    expect(trimDecimalsValue(_strings, TrimDecimals.belowHundred, FiatCurrency.eur), 'Below €1.00');
  });
}
