import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fiat/wallet_fiat.dart';

void main() {
  group('trimmedDecimals', () {
    // The proposal's sample prices, so its table and these tests agree.
    test('keeps what each level hides under its threshold', () {
      int? usd(double rate, TrimDecimals level) => trimmedDecimals(rate, FiatCurrency.usd, level);
      // XMR at $152.37: 1e-5 XMR is worth $0.0015; 1e-4 XMR, $0.015.
      expect(usd(152.37, TrimDecimals.belowOne), 5);
      expect(usd(152.37, TrimDecimals.belowTen), 4);
      expect(usd(152.37, TrimDecimals.belowHundred), 3);
      expect(usd(91240, TrimDecimals.belowOne), 7);
      expect(usd(91240, TrimDecimals.belowTen), 6);
      expect(usd(91240, TrimDecimals.belowHundred), 5);
      expect(usd(3084.1, TrimDecimals.belowOne), 6);
      expect(usd(1.0003, TrimDecimals.belowOne), 2);
      expect(usd(1.0003, TrimDecimals.belowTen), 1);
      expect(usd(1.0003, TrimDecimals.belowHundred), 0);
    });

    test('a stablecoin either side of a dollar keeps the same digits', () {
      expect(trimmedDecimals(0.9999, FiatCurrency.usd, TrimDecimals.belowOne), 2);
      expect(trimmedDecimals(1.0003, FiatCurrency.usd, TrimDecimals.belowOne), 2);
      expect(trimmedDecimals(1.05, FiatCurrency.usd, TrimDecimals.belowOne), 2);
      expect(trimmedDecimals(1.06, FiatCurrency.usd, TrimDecimals.belowOne), 3);
    });

    test('a level is in the currency\'s smallest unit', () {
      // XMR at ¥23,465: one yen is the threshold, not one hundredth of one.
      expect(trimmedDecimals(23465, FiatCurrency.jpy, TrimDecimals.belowOne), 5);
      expect(TrimDecimals.belowOne.thresholdIn(FiatCurrency.jpy), 1);
      expect(TrimDecimals.belowTen.thresholdIn(FiatCurrency.usd), 0.1);
    });

    test('a coin worth less than the threshold shows whole coins', () {
      expect(trimmedDecimals(0.004, FiatCurrency.usd, TrimDecimals.belowOne), 0);
    });

    test('off, or no usable rate, means every digit', () {
      expect(trimmedDecimals(152.37, FiatCurrency.usd, TrimDecimals.off), isNull);
      expect(trimmedDecimals(0, FiatCurrency.usd, TrimDecimals.belowOne), isNull);
      expect(trimmedDecimals(-1, FiatCurrency.usd, TrimDecimals.belowOne), isNull);
      expect(trimmedDecimals(double.nan, FiatCurrency.usd, TrimDecimals.belowOne), isNull);
      expect(trimmedDecimals(double.infinity, FiatCurrency.usd, TrimDecimals.belowOne), isNull);
    });
  });

  group('TrimDecimals storage', () {
    test('round-trips every level', () {
      for (final level in TrimDecimals.values) {
        expect(TrimDecimals.fromStorage(level.storageValue), level);
      }
      expect(TrimDecimals.off.storageValue, 'off');
      expect(TrimDecimals.belowTen.storageValue, '10');
    });

    test('nothing stored, or something unknown, is below one cent', () {
      expect(TrimDecimals.fromStorage(null), TrimDecimals.belowOne);
      expect(TrimDecimals.fromStorage('7'), TrimDecimals.belowOne);
      expect(TrimDecimals.initial, TrimDecimals.belowOne);
    });
  });

  group('SavedTrimDigits', () {
    test('saves what a rate gives every level, and reads it back', () {
      final saved = SavedTrimDigits.empty.withRate('XMR', 152.37, FiatCurrency.usd);
      expect(saved.digitsFor('XMR', TrimDecimals.belowOne), 5);
      expect(saved.digitsFor('xmr', TrimDecimals.belowTen), 4);
      expect(saved.digitsFor('XMR', TrimDecimals.belowHundred), 3);
      expect(saved.digitsFor('XMR', TrimDecimals.off), isNull);
      expect(saved.digitsFor('BTC', TrimDecimals.belowOne), isNull);

      final restored = SavedTrimDigits.decode(saved.encode());
      expect(restored.digitsFor('XMR', TrimDecimals.belowOne), 5);
      expect(restored.digitsFor('XMR', TrimDecimals.belowHundred), 3);
    });

    test('a newer rate replaces only its own coin', () {
      final saved = SavedTrimDigits.empty
          .withRate('XMR', 152.37, FiatCurrency.usd)
          .withRate('BTC', 91240, FiatCurrency.usd)
          .withRate('XMR', 1523.7, FiatCurrency.usd);
      expect(saved.digitsFor('XMR', TrimDecimals.belowOne), 6);
      expect(saved.digitsFor('BTC', TrimDecimals.belowOne), 7);
    });

    test('anything unreadable is skipped, not fatal', () {
      expect(SavedTrimDigits.decode(null).digitsFor('XMR', TrimDecimals.belowOne), isNull);
      expect(SavedTrimDigits.decode('not json').digitsFor('XMR', TrimDecimals.belowOne), isNull);
      expect(SavedTrimDigits.decode('[1, 2]').digitsFor('XMR', TrimDecimals.belowOne), isNull);
      final partly = SavedTrimDigits.decode(
        '{"XMR": {"fiat": "USD", "digits": {"1": 5, "10": "x", "100": -1}},'
        ' "BTC": {"digits": {"1": 7}}, "ETH": 3}',
      );
      expect(partly.digitsFor('XMR', TrimDecimals.belowOne), 5);
      expect(partly.digitsFor('XMR', TrimDecimals.belowTen), isNull);
      expect(partly.digitsFor('XMR', TrimDecimals.belowHundred), isNull);
      expect(partly.digitsFor('BTC', TrimDecimals.belowOne), isNull);
    });
  });
}
