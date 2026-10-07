import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';

import 'fake_wallet.dart';

/// A coin that answers a scheme and accepts a fixed set of addresses, so the
/// BIP-21 default parse and the resolver can be tested without a chain.
class _UriWallet extends FakeWallet {
  _UriWallet(super.symbol, {required this.scheme, this.amountParam = 'amount', required this.valid});

  final String scheme;
  final String amountParam;
  final Set<String> valid;

  @override
  String? get uriScheme => scheme;
  @override
  String get uriAmountParam => amountParam;
  @override
  bool isAddressValid(String address) => valid.contains(address);
}

void main() {
  final xmr = _UriWallet('XMR', scheme: 'monero', amountParam: 'tx_amount', valid: {'4AddrXmr'});
  final btc = _UriWallet('BTC', scheme: 'bitcoin', valid: {'bc1qmain'});
  final tbtc = _UriWallet('TBTC', scheme: 'bitcoin', valid: {'tb1qtest'});
  final wallets = [xmr, btc, tbtc];

  group('parsePaymentUri', () {
    test('monero link reads the address and tx_amount', () {
      final r = parsePaymentUri('monero:4AddrXmr?tx_amount=1.5', wallets)!;
      expect(r.coinSymbol, 'XMR');
      expect(r.address, '4AddrXmr');
      expect(r.amount, '1.5');
    });

    test('bitcoin BIP-21 link reads amount and ignores other params', () {
      final r = parsePaymentUri('bitcoin:bc1qmain?amount=0.01&label=Coffee', wallets)!;
      expect(r.coinSymbol, 'BTC');
      expect(r.address, 'bc1qmain');
      expect(r.amount, '0.01');
    });

    test('a shared scheme self-selects the coin by address validity', () {
      final r = parsePaymentUri('bitcoin:tb1qtest?amount=2', wallets)!;
      expect(r.coinSymbol, 'TBTC');
    });

    test('an amountless link yields a null amount', () {
      expect(parsePaymentUri('monero:4AddrXmr', wallets)!.amount, isNull);
    });

    test('an unknown scheme returns null', () {
      expect(parsePaymentUri('dogecoin:whatever?amount=1', wallets), isNull);
    });

    test('an invalid address returns null', () {
      expect(parsePaymentUri('monero:not-an-address?tx_amount=1', wallets), isNull);
    });

    test('a bare address with no scheme returns null', () {
      expect(parsePaymentUri('4AddrXmr', wallets), isNull);
    });

    test('whitespace is trimmed before parsing', () {
      expect(parsePaymentUri('  monero:4AddrXmr  ', wallets)?.coinSymbol, 'XMR');
    });
  });
}
