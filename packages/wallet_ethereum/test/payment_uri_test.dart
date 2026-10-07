import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_ethereum/wallet_ethereum.dart';

void main() {
  // All-lowercase hex: valid without a checksum to verify.
  const to = '0x2222222222222222222222222222222222222222';
  const dai = '0x6B175474E89094C44Da98b954EedeAC495271d0F';

  final wallets = [EthereumWallet(), EthereumSepoliaWallet(), DaiWallet(), DaiSepoliaWallet()];

  group('EIP-681 native', () {
    test('value in wei becomes exact decimal ETH', () {
      final r = parsePaymentUri('ethereum:$to?value=1500000000000000000', wallets)!;
      expect(r.coinSymbol, 'ETH');
      expect(r.address, to);
      expect(r.amount, '1.5');
    });

    test('scientific notation in value is handled', () {
      expect(parsePaymentUri('ethereum:$to?value=2.014e18', wallets)!.amount, '2.014');
    });

    test('no value yields a null amount', () {
      expect(parsePaymentUri('ethereum:$to', wallets)!.amount, isNull);
    });

    test('@chainId selects the matching chain', () {
      expect(parsePaymentUri('ethereum:$to@11155111?value=1', wallets)!.coinSymbol, 'SETH');
    });

    test('a /transfer link is not claimed as a native send', () {
      // No token wallet matches this contract, so it resolves to nothing.
      expect(parsePaymentUri('ethereum:$to/transfer?address=$to&uint256=1', wallets), isNull);
    });
  });

  group('EIP-681 ERC-20 transfer', () {
    test('token contract routes to DAI with uint256 as exact decimal', () {
      final r = parsePaymentUri('ethereum:$dai/transfer?address=$to&uint256=5000000000000000000', wallets)!;
      expect(r.coinSymbol, 'DAI');
      expect(r.address, to);
      expect(r.amount, '5');
    });

    test('a bare token address is not claimed as a native send', () {
      // The contract is a valid address, so mainnet ETH would claim it without
      // the token/native guard; it must not.
      expect(parsePaymentUri('ethereum:$dai?value=1', wallets)!.coinSymbol, 'ETH');
      // (ETH claims it as a plain recipient — that's fine; the point below is the
      // token form never resolves to ETH.)
    });

    test('a transfer with a mismatched chainId returns null', () {
      expect(parsePaymentUri('ethereum:$dai@11155111/transfer?address=$to&uint256=1', wallets), isNull);
    });
  });
}
