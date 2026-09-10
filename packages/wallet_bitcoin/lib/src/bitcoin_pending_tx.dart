import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// A signed-but-not-yet-broadcast Bitcoin transaction.
class BitcoinPendingTx implements PendingTransaction {
  BitcoinPendingTx({
    required this.amountBaseUnits,
    required this.feeBaseUnits,
    required this.rawHex,
    required this.spentOutpoints,
  });

  /// Satoshis, always exact.
  @override
  final BigInt amountBaseUnits;

  @override
  final BigInt feeBaseUnits;

  /// Hex-encoded raw transaction, ready for
  /// `blockchain.transaction.broadcast`.
  final String rawHex;

  /// Inputs this transaction consumes, recorded so the wallet can invalidate
  /// them from its UTXO cache once the broadcast succeeds.
  final List<({String txHash, int vout})> spentOutpoints;

  @override
  String toString() =>
      'BitcoinPendingTx(${Redact.amount(amountBaseUnits)}, '
      'fee ${Redact.amount(feeBaseUnits)}, ${spentOutpoints.length} inputs)';
}
