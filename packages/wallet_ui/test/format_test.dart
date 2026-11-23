import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fiat/wallet_fiat.dart';
import 'package:wallet_ui/wallet_ui.dart';

void main() {
  group('formatFiat', () {
    test('groups thousands and keeps the currency\'s minor digits', () {
      expect(formatFiat(1234.5, FiatCurrency.usd), '\$1,234.50');
      expect(formatFiat(0, FiatCurrency.usd), '\$0.00');
      expect(formatFiat(9.999, FiatCurrency.eur), '€10.00');
    });

    test('uses the symbol from the shared table', () {
      expect(formatFiat(12, FiatCurrency.gbp), '£12.00');
      expect(formatFiat(12, FiatCurrency.cad), 'C\$12.00');
      expect(formatFiat(12, FiatCurrency.chf), 'Fr12.00');
    });

    test('yen has no minor unit', () {
      expect(formatFiat(53412.4, FiatCurrency.jpy), '¥53,412');
    });
  });

  group('formatExactAmount', () {
    test('writes every base unit, without trailing zeros', () {
      expect(formatExactAmount(BigInt.from(250000000000), 12), '0.25');
      expect(formatExactAmount(BigInt.parse('3141592653589'), 12), '3.141592653589');
      expect(
        formatExactAmount(BigInt.parse('523456789012345678'), 18, symbol: 'ETH'),
        '0.523456789012345678 ETH',
      );
    });

    test('stays exact past what a double holds', () {
      // 9,007.199254740993 XMR is 2^53 + 1 piconero, one more than a double
      // can tell apart from its neighbour.
      expect(formatExactAmount(BigInt.parse('9007199254740993'), 12), '9007.199254740993');
    });
  });

  group('formatTrimmedAmount', () {
    final xmr = BigInt.parse('1234567891234'); // 1.234567891234 XMR

    test('cuts to the decimals asked for, padding with zeros', () {
      expect(formatTrimmedAmount(xmr, 12, 5), '1.23456');
      expect(formatTrimmedAmount(BigInt.from(250000000000), 12, 5, symbol: 'XMR'), '0.25000 XMR');
      expect(formatTrimmedAmount(xmr, 12, 0), '1');
    });

    test('never rounds up', () {
      // 1.2345678... would round to 1.23457 and read higher than the amount.
      expect(formatTrimmedAmount(BigInt.parse('1234569999999'), 12, 5), '1.23456');
      expect(formatTrimmedAmount(BigInt.parse('12499999999999999999'), 18, 2), '12.49');
    });

    test('null decimals is every digit', () {
      expect(formatTrimmedAmount(xmr, 12, null), '1.234567891234');
      expect(formatTrimmedAmount(BigInt.from(250000000000), 12, null), '0.25');
    });

    test('a non-zero amount that would read as zero shows the smallest step', () {
      expect(formatTrimmedAmount(BigInt.from(4200000), 12, 5), '<0.00001');
      expect(formatTrimmedAmount(BigInt.one, 18, 2, symbol: 'DAI'), '<0.01 DAI');
      expect(formatTrimmedAmount(BigInt.from(5), 2, 0), '<1');
    });

    test('zero stays zero', () {
      expect(formatTrimmedAmount(BigInt.zero, 12, 5), '0.00000');
    });

    test('decimals past the coin precision stop at the base unit', () {
      expect(formatTrimmedAmount(BigInt.from(1234567), 8, 12), '0.01234567');
    });

    test('a negative amount keeps its sign', () {
      expect(formatTrimmedAmount(-xmr, 12, 3), '-1.234');
    });
  });
}
