import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// These assert the properties the redaction helpers are
/// relied on for, not their exact output.
const _address =
    '44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A';
const _otherAddress =
    '48jLWTgnMY4fL8ndomV6y2WT4WQvBPWCVHpQMkFVAY4FfSXWUJhGxs9SVoQ1sxDkYQBoJZ7Bof4wLLLPPGqvQxnLTGjX7wS';

void main() {
  group('Redact.secret', () {
    test('is a constant that discloses nothing', () {
      expect(Redact.secret, '<redacted>');
      // A guard against anyone "improving" this into a partial disclosure.
      expect(Redact.secret, isNot(contains('…')));
    });
  });

  group('Redact.id', () {
    test('never contains any part of the input', () {
      final fp = Redact.id(_address);
      // The whole point: no prefix or suffix leaks. Even 8 characters of a
      // Monero address is enough to find it on chain.
      for (var len = 4; len <= 12; len++) {
        expect(fp, isNot(contains(_address.substring(0, len))));
        expect(fp, isNot(contains(_address.substring(_address.length - len))));
      }
    });

    test('is stable within a process, so a value can be followed through a log', () {
      expect(Redact.id(_address), Redact.id(_address));
    });

    test('distinguishes different values', () {
      expect(Redact.id(_address), isNot(Redact.id(_otherAddress)));
    });

    test('is short enough to read and fixed width', () {
      final fp = Redact.id(_address);
      expect(fp, matches(RegExp(r'^#[0-9a-f]{8}$')));
      expect(Redact.id(_otherAddress).length, fp.length);
    });

    test('handles null and empty without leaking a distinct fingerprint', () {
      expect(Redact.id(null), '<empty>');
      expect(Redact.id(''), '<empty>');
    });

    test('a one-character difference changes the whole fingerprint', () {
      final a = Redact.id('4AAAA');
      final b = Redact.id('4AAAB');
      expect(a, isNot(b));
    });
  });

  group('Redact.amount', () {
    test('never contains the exact value', () {
      final units = BigInt.parse('123456789012');
      expect(Redact.amount(units), isNot(contains('123456789012')));
    });

    test('distinguishes zero, dust and large', () {
      expect(Redact.amount(BigInt.zero), '<amount:0>');
      expect(Redact.amount(BigInt.one), '<amount:~1e0>');
      // 1 XMR in piconero.
      expect(Redact.amount(BigInt.parse('1000000000000')), '<amount:~1e12>');
    });

    test('discloses only order of magnitude', () {
      // Every value with the same digit count collapses to one bucket.
      expect(
        Redact.amount(BigInt.parse('1000000000000')),
        Redact.amount(BigInt.parse('9999999999999')),
      );
    });

    test('keeps the sign', () {
      expect(Redact.amount(BigInt.from(-500)), startsWith('<amount:-'));
    });

    test('handles null', () => expect(Redact.amount(null), '<null>'));
  });

  group('Redact.body', () {
    test('reports size only', () {
      expect(Redact.body(4096), '<body:4096 bytes>');
      expect(Redact.body(0), '<body:0 bytes>');
    });
  });
}
