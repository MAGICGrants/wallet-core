import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart' show baseUnitsToDecimalString;
import 'package:wallet_fiat/wallet_fiat.dart';

void main() {
  group('fiatToBaseUnits', () {
    test('converts at the coin\'s full precision', () {
      final units = fiatToBaseUnits('150.00', 356.03, fiatDecimals: 2, coinDecimals: 12);
      // 150 / 356.03 = 0.421312810718197904…, rounded to the piconero.
      expect(baseUnitsToDecimalString(units, 12), '0.421312810718');
    });

    test('rounds to the nearest base unit, which may overshoot a round figure', () {
      // $1 of DAI at 0.9999 needs every one of the 18 decimals.
      final units = fiatToBaseUnits('1', 0.9999, fiatDecimals: 2, coinDecimals: 18);
      expect(baseUnitsToDecimalString(units, 18), '1.0001000100010001');
    });

    test('rounds half up', () {
      // 1 cent at 3 per coin, 2 coin decimals: 0.00333… -> 0; 5 cents -> 0.01666… -> 0.02.
      expect(fiatToBaseUnits('0.01', 3, fiatDecimals: 2, coinDecimals: 2), BigInt.zero);
      expect(fiatToBaseUnits('0.05', 3, fiatDecimals: 2, coinDecimals: 2), BigInt.two);
    });

    test('stays exact beyond double precision', () {
      // 1,000,000 XMR worth at 1.0: every piconero digit survives.
      final units = fiatToBaseUnits('1000000.01', 1.0, fiatDecimals: 2, coinDecimals: 12);
      expect(units, BigInt.parse('1000000010000000000'));
    });

    test('drops fiat digits finer than the currency has', () {
      final yen = fiatToBaseUnits('1500.9', 150000, fiatDecimals: 0, coinDecimals: 8);
      expect(yen, fiatToBaseUnits('1500', 150000, fiatDecimals: 0, coinDecimals: 8));
    });

    test('empty text is zero', () {
      expect(fiatToBaseUnits('', 356.03, fiatDecimals: 2, coinDecimals: 12), BigInt.zero);
    });

    test('rejects text that is not an amount', () {
      expect(
        () => fiatToBaseUnits('12a', 356.03, fiatDecimals: 2, coinDecimals: 12),
        throwsFormatException,
      );
    });

    test('rejects a rate that cannot price anything', () {
      for (final rate in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
          () => fiatToBaseUnits('1', rate, fiatDecimals: 2, coinDecimals: 12),
          throwsArgumentError,
          reason: '$rate',
        );
      }
    });

    test('accepts a rate that prints in exponent notation', () {
      // 1e-7 fiat per coin: $1 buys ten million coins.
      final units = fiatToBaseUnits('1', 1e-7, fiatDecimals: 2, coinDecimals: 0);
      expect(units, BigInt.from(10000000));
    });
  });

  group('baseUnitsToFiatMinor', () {
    test('prices an amount in cents, rounded', () {
      final units = BigInt.parse('421312810718'); // 0.421312810718 XMR
      expect(
        baseUnitsToFiatMinor(units, 356.03, coinDecimals: 12, fiatDecimals: 2),
        BigInt.from(15000),
      );
    });

    test('prices yen in whole yen', () {
      final units = BigInt.from(100000000); // 1 BTC
      expect(
        baseUnitsToFiatMinor(units, 15000000.4, coinDecimals: 8, fiatDecimals: 0),
        BigInt.from(15000000),
      );
    });

    test('a round trip lands on the typed figure', () {
      for (final typed in ['0.01', '1.00', '150.00', '99999.99']) {
        final units = fiatToBaseUnits(typed, 356.03, fiatDecimals: 2, coinDecimals: 12);
        final back = baseUnitsToFiatMinor(units, 356.03, coinDecimals: 12, fiatDecimals: 2);
        expect(
          baseUnitsToDecimalString(back, 2),
          baseUnitsToDecimalString(BigInt.parse(typed.replaceAll('.', '')), 2),
          reason: typed,
        );
      }
    });
  });

  group('FiatCurrency', () {
    test('every picker currency resolves to itself', () {
      for (final currency in FiatCurrency.all) {
        expect(FiatCurrency.of(currency.code), same(currency));
      }
    });

    test('an unknown code falls back to USD', () {
      expect(FiatCurrency.of('XYZ'), same(FiatCurrency.usd));
    });

    test('yen has no minor unit; the others have cents', () {
      for (final currency in FiatCurrency.all) {
        expect(currency.decimals, currency == FiatCurrency.jpy ? 0 : 2, reason: currency.code);
      }
    });

    test('USD and EUR are quoted directly; the rest bridge through USD', () {
      final bridged = FiatCurrency.all.where((c) => c.bridgedViaUsd).map((c) => c.code);
      expect(bridged, ['CAD', 'AUD', 'GBP', 'CHF', 'JPY']);
    });
  });
}
