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
      expect(() => decimalToBaseUnits('1e', _xmr), throwsFormatException);
      expect(() => decimalToBaseUnits('1e1.5', _xmr), throwsFormatException);
      expect(() => decimalToBaseUnits('.', _xmr), throwsFormatException);
      // Bounded so a nonsense exponent cannot ask for a 10^n the size of memory.
      expect(() => decimalToBaseUnits('1e999999999', _xmr), throwsFormatException);
    });
  });

  group('exponential notation', () {
    // It arrives whether or not anyone asked for it: `double.toString()`
    // switches to it below 1e-6, so any amount that has been through a double —
    // a scanned `tx_amount`, a Max button — shows up here as `1.5e-7`.

    test('converts exactly, in both signs and directions', () {
      expect(decimalToBaseUnits('1e-7', _xmr), BigInt.parse('100000'));
      expect(decimalToBaseUnits('1.5e-7', _xmr), BigInt.parse('150000'));
      expect(decimalToBaseUnits('5e-7', _xmr), BigInt.parse('500000'));
      expect(decimalToBaseUnits('1E-7', _xmr), BigInt.parse('100000'));
      expect(decimalToBaseUnits('1e3', _xmr), BigInt.parse('1000000000000000'));
      expect(decimalToBaseUnits('1e+3', _xmr), BigInt.parse('1000000000000000'));
      expect(decimalToBaseUnits('-1.5e-7', _xmr), BigInt.parse('-150000'));
    });

    test('agrees with the same amount written out in full', () {
      expect(decimalToBaseUnits('1.5e-7', _xmr), decimalToBaseUnits('0.00000015', _xmr));
      expect(decimalToBaseUnits('9.99999e-7', _xmr), decimalToBaseUnits('0.000000999999', _xmr));
    });

    test('every amount the network can express survives a double round-trip', () {
      // The guarantee in one assertion: an integer number of piconero below
      // 1e-6 XMR is the full set of real sub-microXMR amounts, and each one is
      // put through `double.toString()` exactly as a scanned amount is.
      //
      // Before the exponent was normalised, all 999,999 of these threw — the
      // fractional part was `substring`'d to 12 characters, which left a partial
      // exponent that `BigInt.parse` rejected, and the amount was silently
      // treated as invalid and refused.
      for (var n = 1; n < 1000000; n++) {
        final text = (n / 1e12).toString();
        expect(decimalToBaseUnits(text, _xmr), BigInt.from(n), reason: '$n piconero as "$text"');
      }
    });

    test('precision finer than one base unit truncates, never inflates', () {
      // The regression this group exists for. `substring(0, decimals)` used to
      // cut "2345678901234e-7" down to "234567890123" — twelve characters that
      // happen to all be digits — and parse the result, yielding 1.234567890123
      // XMR for an amount 10^7 smaller. Truncation is the only loss allowed;
      // inventing a larger number is not.
      expect(decimalToBaseUnits('1.234567890123e-7', _xmr), BigInt.parse('123456'));
      expect(decimalToBaseUnits('1.2345678901234e-7', _xmr), BigInt.parse('123456'));
      expect(decimalToBaseUnits('9.99999999999999e-7', _xmr), BigInt.parse('999999'));
    });

    test('a scanned amount finer than 12 decimals keeps its first 12', () {
      // 0.047474743737373111 XMR has 18 fractional digits; Monero can express
      // twelve. The six it cannot are dropped and nothing else changes, whether
      // the value reaches us as text or by way of a double.
      const scanned = '0.047474743737373111';
      const expected = '47474743737'; // 0.047474743737 XMR

      expect(decimalToBaseUnits(scanned, _xmr), BigInt.parse(expected));
      expect(decimalToBaseUnits(double.parse(scanned).toString(), _xmr), BigInt.parse(expected));
      expect(baseUnitsToDecimalString(BigInt.parse(expected), _xmr), '0.047474743737');
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

  group('a display double must never be compared against a parsed amount', () {
    // `CryptoWallet.unlockedBalance` is `units.toDouble() / 1e12` — two
    // roundings — while a field holding `baseUnitsToDecimalString(units)`
    // parses to the nearest double in one. Above 2^53 piconero (~9007 XMR) the
    // two disagree, and when the parse lands higher a Max button produces an
    // "insufficient balance" error against the balance it just filled in
    // The fix is to compare base units; this pins why.
    double displayBalance(BigInt units) => units.toDouble() / BigInt.from(10).pow(12).toDouble();

    test('the two agree below 2^53 piconero', () {
      for (final units in [BigInt.one, BigInt.from(1000000), BigInt.two.pow(52)]) {
        expect(
          double.parse(baseUnitsToDecimalString(units, 12)),
          displayBalance(units),
          reason: '$units',
        );
      }
    });

    test('and disagree above it, which is where balances live', () {
      // 2^53 + 1 piconero: representable exactly as a decimal string and as a
      // BigInt, not as a double.
      final units = BigInt.two.pow(53) + BigInt.one;
      expect(baseUnitsToDecimalString(units, 12), '9007.199254740993');
      expect(decimalToBaseUnits('9007.199254740993', 12), units);

      // The comparison the send screen used to make, and why it was unsafe.
      expect(
        double.parse(baseUnitsToDecimalString(units, 12)) == displayBalance(units),
        isFalse,
        reason: 'two roundings against one',
      );
    });

    test('base units compare exactly at the same magnitude', () {
      final units = BigInt.two.pow(53) + BigInt.one;
      final typed = decimalToBaseUnits(baseUnitsToDecimalString(units, 12), 12);
      expect(typed, units);
      expect(typed > units, isFalse, reason: 'Max must never read as over balance');
    });
  });
}
