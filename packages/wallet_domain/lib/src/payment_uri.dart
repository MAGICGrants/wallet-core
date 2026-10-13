import 'crypto_wallet.dart';

/// A payment request parsed from a URI (`monero:`, `bitcoin:`, `ethereum:`).
///
/// [amount] is exact decimal text in the coin's own units, never a double, and
/// null when the URI carried no amount. It feeds the send form the same way a
/// scanned QR or a contact does.
class PaymentRequest {
  final String coinSymbol;
  final String address;
  final String? amount;

  const PaymentRequest({required this.coinSymbol, required this.address, this.amount});
}

/// Resolves a payment URI against [wallets], returning the first coin that
/// claims it, or null when none do (unknown scheme, bad address, malformed).
///
/// Each coin decides for itself via [CryptoWallet.parsePaymentUri], so the set
/// of supported schemes is exactly the registered coins — no central switch.
PaymentRequest? parsePaymentUri(String raw, Iterable<CryptoWallet> wallets) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme.isEmpty) return null;
  for (final wallet in wallets) {
    final request = wallet.parsePaymentUri(uri);
    if (request != null) return request;
  }
  return null;
}
