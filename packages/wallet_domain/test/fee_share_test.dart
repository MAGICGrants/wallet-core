import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';

import 'fake_wallet.dart';

/// The percentage an application shows next to a fee, and, more importantly,
/// the third state it has to handle when the comparison cannot be made.
///
/// This computes the number and asserts nothing about which values are "too
/// high". No threshold lives in this repository.

class _Tx implements PendingTransaction {
  _Tx(this.amountBaseUnits, this.feeBaseUnits);

  @override
  final BigInt amountBaseUnits;
  @override
  final BigInt feeBaseUnits;
}

/// A native 18-decimal coin: fee paid in itself, amounts past a double's exact
/// integer range.
class _EthWallet extends FakeWallet {
  _EthWallet() : super('ETH');

  @override
  int get decimals => 18;
}

/// An ERC-20-shaped wallet: amount in the token, fee in the chain's native coin.
class _TokenWallet extends FakeWallet {
  _TokenWallet() : super('DAI');

  @override
  String get feeCoinSymbol => 'ETH';
  @override
  int get decimals => 18;
}

BigInt _units(String whole, int decimals) => decimalToBaseUnits(whole, decimals);

/// Rates for the foreign-fee path: DAI at $1, ETH at $4000.
double? _rates(String symbol) => switch (symbol) {
  'DAI' => 1.0,
  'ETH' => 4000.0,
  _ => null,
};

void main() {
  // FakeWallet is 8 decimals and pays its fee in itself.
  late FakeWallet native;
  setUp(() {
    native = FakeWallet('BTC');
  });
  tearDown(() {
    native.dispose();
  });

  group('same coin — no fiat rate needed, ever', () {
    test('a tenth of the amount is 10%', () {
      final share = feeShareOfAmount(native, _Tx(_units('1', 8), _units('0.1', 8)));

      expect(share.isKnown, isTrue);
      expect(share.fraction, closeTo(0.1, 1e-12));
      expect(share.percent, closeTo(10, 1e-9));
      expect(share.needsManualCheck, isFalse);
    });

    test('works with no fiat callback at all', () {
      // The property that matters when fiat is switched off, or when Tor has
      // failed it closed: a native send still gets its percentage.
      final share = feeShareOfAmount(native, _Tx(_units('2', 8), _units('0.5', 8)));
      expect(share.percent, closeTo(25, 1e-9));
    });

    test('works when the fiat callback exists but answers null', () {
      final share = feeShareOfAmount(
        native,
        _Tx(_units('2', 8), _units('0.5', 8)),
        fiatRateFor: (_) => null,
      );
      expect(share.percent, closeTo(25, 1e-9));
    });

    test('a fee larger than the amount is over 100%, not clamped', () {
      // A sweep whose fee ate most of the balance: 0.5 fee on a 0.01 amount.
      // Reporting 100% here would hide exactly the case worth seeing.
      final share = feeShareOfAmount(native, _Tx(_units('0.01', 8), _units('0.5', 8)));
      expect(share.percent, closeTo(5000, 1e-6));
    });

    test('a dust fee keeps its precision instead of truncating to zero', () {
      // 546 sat on 1 BTC is 5.46 parts per million, or 0.000546%. A coarser
      // internal scale would round this to 0.0005% or to nothing.
      final share = feeShareOfAmount(native, _Tx(_units('1', 8), BigInt.from(546)));
      expect(share.fraction, closeTo(5.46e-6, 1e-15));
      expect(share.percent, closeTo(0.000546, 1e-12));
    });

    test('an 18-decimal amount past 2^53 keeps its ratio exact', () {
      // 1000 ETH in wei is 1e21, far outside a double's exact
      // integer range, and the ratio must survive getting there.
      final wallet = _EthWallet();
      addTearDown(wallet.dispose);
      expect(wallet.feeIsForeign, isFalse, reason: 'this must exercise the native path');

      final share = feeShareOfAmount(wallet, _Tx(_units('1000', 18), _units('250', 18)));
      expect(share.percent, closeTo(25, 1e-9));
    });
  });

  group('foreign fee — fiat is the only common unit', () {
    late _TokenWallet token;
    setUp(() {
      token = _TokenWallet();
    });
    tearDown(() {
      token.dispose();
    });

    test('converts both sides and compares', () {
      // 100 DAI at $1, with a 0.01 ETH fee at $4000 → $40 of fee on $100 sent.
      final share = feeShareOfAmount(
        token,
        _Tx(_units('100', 18), _units('0.01', 18)),
        fiatRateFor: _rates,
      );
      expect(share.isKnown, isTrue);
      expect(share.percent, closeTo(40, 1e-9));
    });

    test('a small fee on a large transfer is a small percentage', () {
      // $8 of gas on $50,000 of DAI. The reason a flat fee cap makes no sense
      // for tokens: the same fee is fine here and outrageous above.
      final share = feeShareOfAmount(
        token,
        _Tx(_units('50000', 18), _units('0.002', 18)),
        fiatRateFor: _rates,
      );
      expect(share.percent, closeTo(0.016, 1e-9));
    });

    test('no fiat callback → unknown, with a reason, and nothing thrown', () {
      // The case the user is most likely to be in: fiat lookups disabled, or on
      // Tor where they fail closed. This must be a warning, not a refusal.
      final share = feeShareOfAmount(token, _Tx(_units('100', 18), _units('0.01', 18)));

      expect(share.isKnown, isFalse);
      expect(share.unknownBecause, FeeShareUnknown.noFiatRate);
      expect(share.needsManualCheck, isTrue, reason: 'the UI must ask the user to check the fee');
      expect(share.fraction, isNull);
      expect(share.percent, isNull);
    });

    test('one missing rate is enough to make it unknown', () {
      for (final priced in ['DAI', 'ETH']) {
        final share = feeShareOfAmount(
          token,
          _Tx(_units('100', 18), _units('0.01', 18)),
          fiatRateFor: (s) => s == priced ? 1.0 : null,
        );
        expect(share.needsManualCheck, isTrue, reason: 'only $priced priced');
        expect(share.unknownBecause, FeeShareUnknown.noFiatRate);
      }
    });

    test('an unknown share is never an exception', () {
      // Stated as its own case because the requirement is behavioural: a missing
      // fiat rate must not stop a user sending a transaction.
      expect(() => feeShareOfAmount(token, _Tx(_units('1', 18), _units('1', 18))), returnsNormally);
    });
  });

  group('degenerate amounts', () {
    test('a zero amount has no ratio, and says which reason', () {
      final share = feeShareOfAmount(native, _Tx(BigInt.zero, _units('0.1', 8)));
      expect(share.unknownBecause, FeeShareUnknown.noAmount);
      expect(share.needsManualCheck, isTrue);
    });

    test('a negative amount has no ratio', () {
      final share = feeShareOfAmount(native, _Tx(-_units('1', 8), _units('0.1', 8)));
      expect(share.unknownBecause, FeeShareUnknown.noAmount);
    });

    test('a zero fee is a known 0%, not unknown', () {
      // The distinction: we did compare, and the answer was nothing.
      final share = feeShareOfAmount(native, _Tx(_units('1', 8), BigInt.zero));
      expect(share.isKnown, isTrue);
      expect(share.percent, 0);
      expect(share.needsManualCheck, isFalse);
    });
  });

  test('toString names the state either way', () {
    expect(const FeeShare.known(0.125).toString(), contains('12.50%'));
    expect(const FeeShare.unknown(FeeShareUnknown.noFiatRate).toString(), contains('noFiatRate'));
  });
}
