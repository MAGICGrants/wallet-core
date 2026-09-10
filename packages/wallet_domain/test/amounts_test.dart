import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';

const _xmr = 12;
const _eth = 18;
const _btc = 8;

void main() {
  group('decimalToBaseUnits', () {
    test('whole and fractional values', () {
      expect(decimalToBaseUnits('1', _xmr), BigInt.parse('1000000000000'));
      expect(decimalToBaseUnits('0.5', _xmr), BigInt.parse('500000000000'));
      expect(decimalToBaseUnits('0.000000000001', _xmr), BigInt.one);
      expect(decimalToBaseUnits('123.456', _btc), BigInt.parse('12345600000'));
    });

    test('leading-dot and trailing-dot forms', () {
      expect(decimalToBaseUnits('.5', _xmr), BigInt.parse('500000000000'));
      expect(decimalToBaseUnits('5.', _xmr), BigInt.parse('5000000000000'));
    });

    test('empty and whitespace are zero', () {
      expect(decimalToBaseUnits('', _xmr), BigInt.zero);
      expect(decimalToBaseUnits('   ', _xmr), BigInt.zero);
    });

    test('truncates beyond decimals rather than rounding', () {
      // 0.9999999999999 has 13 fractional digits; the 13th is dropped, not
      // rounded up. Rounding here would credit money that does not exist.
      expect(decimalToBaseUnits('0.9999999999999', _xmr), BigInt.parse('999999999999'));
      expect(decimalToBaseUnits('1.999999999', _btc), BigInt.parse('199999999'));
    });

    test('rejects malformed input', () {
      expect(() => decimalToBaseUnits('1.2.3', _xmr), throwsFormatException);
      expect(() => decimalToBaseUnits('abc', _xmr), throwsFormatException);
    });
  });

  group('precision beyond double', () {
    test('values above 2^53 base units survive exactly', () {
      // 2^53 piconero is ~9007 XMR; comfortably inside a real balance, and
      // exactly where double starts silently losing whole units. 9007.199254740993
      // XMR is 2^53 + 1 piconero: representable as a BigInt, not as a double.
      // The no-double rule in one assertion.
      const s = '9007.199254740993';
      final units = decimalToBaseUnits(s, _xmr);
      expect(units, BigInt.parse('9007199254740993'));
      expect(units, BigInt.two.pow(53) + BigInt.one);
      expect(units.toDouble().toInt(), 9007199254740992); // the lost piconero
      expect(baseUnitsToDecimalString(units, _xmr), s);
    });

    test('a full 18-decimal ETH value round-trips', () {
      const s = '1234567.123456789012345678';
      expect(baseUnitsToDecimalString(decimalToBaseUnits(s, _eth), _eth), s);
    });

    test('one wei is not lost', () {
      expect(decimalToBaseUnits('0.000000000000000001', _eth), BigInt.one);
      expect(baseUnitsToDecimalString(BigInt.one, _eth), '0.000000000000000001');
    });
  });

  group('baseUnitsToDecimalString', () {
    test('trims trailing fractional zeros', () {
      expect(baseUnitsToDecimalString(BigInt.parse('1000000000000'), _xmr), '1');
      expect(baseUnitsToDecimalString(BigInt.parse('1500000000000'), _xmr), '1.5');
    });

    test('zero and sub-unit values', () {
      expect(baseUnitsToDecimalString(BigInt.zero, _xmr), '0');
      expect(baseUnitsToDecimalString(BigInt.one, _xmr), '0.000000000001');
    });

    test('negative values keep their sign', () {
      expect(baseUnitsToDecimalString(BigInt.parse('-1500000000000'), _xmr), '-1.5');
      expect(baseUnitsToDecimalString(BigInt.from(-1), _xmr), '-0.000000000001');
    });

    test('decimals <= 0 renders the raw integer', () {
      expect(baseUnitsToDecimalString(BigInt.from(42), 0), '42');
    });
  });

  group('round trip', () {
    test('inverse across a range of magnitudes and decimals', () {
      const cases = ['0', '1', '0.5', '0.000000000001', '18446744.073709551615', '999999999.1'];
      for (final decimals in [_btc, _xmr, _eth]) {
        for (final s in cases) {
          final units = decimalToBaseUnits(s, decimals);
          final back = baseUnitsToDecimalString(units, decimals);
          expect(
            decimalToBaseUnits(back, decimals),
            units,
            reason: 'round trip failed for "$s" at $decimals decimals (got "$back")',
          );
        }
      }
    });
  });
}
