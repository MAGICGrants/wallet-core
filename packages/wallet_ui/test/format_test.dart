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
}
