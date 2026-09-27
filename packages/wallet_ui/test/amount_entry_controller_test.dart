import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fiat/wallet_fiat.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_ui/wallet_ui.dart';

class _Quotes extends ChangeNotifier implements FiatQuoteSource {
  final Map<String, FiatQuote> _quotes = {};

  @override
  FiatQuote? quoteFor(String coinSymbol) => _quotes[coinSymbol];

  void set(String coin, double? rate, [FiatCurrency currency = FiatCurrency.usd]) {
    if (rate == null) {
      _quotes.remove(coin);
    } else {
      _quotes[coin] = (currency: currency, rate: rate);
    }
    notifyListeners();
  }
}

final _piconero = BigInt.from(10).pow(12);

void main() {
  late _Quotes quotes;

  setUp(() {
    SharedPreferencesService.store = MemoryPreferenceStore();
    quotes = _Quotes()..set('XMR', 356.03);
  });

  tearDown(SharedPreferencesService.resetForTesting);

  AmountEntryController entry({String coin = 'XMR', int decimals = 12, bool restore = false}) {
    final c = AmountEntryController(
      quotes: quotes,
      coinSymbol: coin,
      coinDecimals: decimals,
      restoreUnit: restore,
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a coin amount is read as typed and priced in fiat', () {
    final c = entry();
    c.field.text = '0.5';
    expect(c.unit, AmountUnit.coin);
    expect(c.baseUnits, _piconero ~/ BigInt.two);
    expect(c.coinText, '0.5');
    // 0.5 × 356.03 = 178.015, half up.
    expect(c.fiatMinorUnits, BigInt.from(17802));
  });

  test('a typed fiat amount converts at full precision', () {
    final c = entry();
    c.swap();
    c.field.text = '150.00';
    expect(c.unit, AmountUnit.fiat);
    expect(c.coinText, '0.421312810718');
    expect(c.fiatMinorUnits, BigInt.from(15000));
  });

  test('swapping back and forth never changes the amount', () {
    final c = entry();
    c.field.text = '0.123456789012';
    final exact = c.baseUnits;

    c.swap();
    expect(c.field.text, '43.95'); // rounded for display
    expect(c.baseUnits, exact);

    c.swap();
    expect(c.field.text, '0.123456789012');
    expect(c.baseUnits, exact);
  });

  test('editing after a swap makes the field the amount again', () {
    final c = entry();
    c.field.text = '0.5';
    c.swap();
    c.field.text = '100';
    expect(c.baseUnits, fiatToBaseUnits('100', 356.03, fiatDecimals: 2, coinDecimals: 12));
  });

  test('a rate update keeps a typed fiat value and moves the coin amount', () {
    final c = entry();
    c.swap();
    c.field.text = '150';
    final before = c.baseUnits;

    quotes.set('XMR', 349.8);
    expect(c.field.text, '150');
    expect(c.baseUnits, isNot(before));
    expect(c.baseUnits, fiatToBaseUnits('150', 349.8, fiatDecimals: 2, coinDecimals: 12));
  });

  test('a rate update after a swap follows the fiat figure shown', () {
    final c = entry();
    c.field.text = '0.5';
    c.swap(); // shows 178.02
    quotes.set('XMR', 349.8);
    expect(c.field.text, '178.02');
    expect(c.baseUnits, fiatToBaseUnits('178.02', 349.8, fiatDecimals: 2, coinDecimals: 12));
  });

  test('MAX holds the coin amount through a rate update in fiat', () {
    final c = entry();
    c.swap();
    final balance = BigInt.parse('1234567890123');
    c.setMax(balance);
    expect(c.baseUnits, balance);
    expect(c.field.text, '439.54');

    quotes.set('XMR', 349.8);
    expect(c.baseUnits, balance);
    expect(c.field.text, '431.85');
  });

  test('losing the rate falls back to the coin and keeps the amount', () {
    final c = entry();
    c.swap();
    c.field.text = '150';
    final before = c.baseUnits;

    quotes.set('XMR', null);
    expect(c.unit, AmountUnit.coin);
    expect(c.canSwap, isFalse);
    expect(c.baseUnits, before);
    expect(c.field.text, '0.421312810718');
  });

  test('losing the rate on an empty fiat field falls back to the coin', () {
    final c = entry();
    c.swap();
    quotes.set('XMR', null);
    expect(c.unit, AmountUnit.coin);
    expect(c.field.text, isEmpty);
  });

  test('without a rate there is nothing to swap to', () {
    quotes.set('XMR', null);
    final c = entry();
    c.field.text = '1';
    c.swap();
    expect(c.unit, AmountUnit.coin);
    expect(c.fiatMinorUnits, isNull);
    expect(c.field.text, '1');
  });

  test('a coin-denominated amount switches entry to the coin', () {
    final c = entry();
    c.swap();
    c.field.text = '20';
    c.setCoinText('0.25');
    expect(c.unit, AmountUnit.coin);
    expect(c.field.text, '0.25');
    expect(c.coinText, '0.25');
  });

  test('changing coin carries a fiat amount over and clears a coin one', () {
    quotes.set('DAI', 0.9999);
    final c = entry(coin: 'ETH', decimals: 18);
    quotes.set('ETH', 2500);

    c.swap();
    c.field.text = '100';
    c.setCoin('DAI', 18);
    expect(c.unit, AmountUnit.fiat);
    expect(c.field.text, '100');
    expect(c.coinText, '100.010001000100010001');

    c.swap();
    expect(c.unit, AmountUnit.coin);
    c.setCoin('ETH', 18);
    expect(c.field.text, isEmpty);
  });

  test('changing to an unpriced coin drops back to coin entry', () {
    final c = entry(coin: 'ETH', decimals: 18);
    quotes.set('ETH', 2500);
    c.swap();
    c.field.text = '100';
    c.setCoin('USDC', 6);
    expect(c.unit, AmountUnit.coin);
    expect(c.field.text, isEmpty);
  });

  test('yen is typed and shown in whole yen', () {
    quotes.set('XMR', 53412.0, FiatCurrency.jpy);
    final c = entry();
    c.field.text = '1';
    c.swap();
    expect(c.field.text, '53412');
  });

  test('a currency change re-expresses the amount rather than reinterpreting it', () {
    final c = entry();
    c.swap();
    c.field.text = '150';
    final before = c.baseUnits;
    quotes.set('XMR', 330.0, FiatCurrency.eur);
    expect(c.baseUnits, before);
    expect(c.field.text, '139.03');
  });

  group('remembered unit', () {
    test('a swap is remembered', () async {
      final c = entry();
      c.swap();
      await pumpEventQueue();
      expect(await SharedPreferencesService.get<String>(SettingsKeys.sendAmountUnit), 'fiat');
    });

    test('the next entry opens in fiat', () async {
      await SharedPreferencesService.set<String>(SettingsKeys.sendAmountUnit, 'fiat');
      final c = entry(restore: true);
      await pumpEventQueue();
      expect(c.unit, AmountUnit.fiat);
    });

    test('waits for a rate before opening in fiat', () async {
      await SharedPreferencesService.set<String>(SettingsKeys.sendAmountUnit, 'fiat');
      quotes.set('XMR', null);
      final c = entry(restore: true);
      await pumpEventQueue();
      expect(c.unit, AmountUnit.coin);

      quotes.set('XMR', 356.03);
      expect(c.unit, AmountUnit.fiat);
    });

    test('never switches a field that already has an amount', () async {
      await SharedPreferencesService.set<String>(SettingsKeys.sendAmountUnit, 'fiat');
      final c = entry(restore: true);
      c.setCoinText('0.25'); // a prefilled request, before the preference loads
      await pumpEventQueue();
      expect(c.unit, AmountUnit.coin);
      expect(c.field.text, '0.25');
    });
  });
}
