import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// A signed-but-not-yet-broadcast EVM transaction.
class EthereumPendingTx implements PendingTransaction {
  EthereumPendingTx({
    required this.amountBaseUnits,
    required this.feeBaseUnits,
    required this.rawHex,
    required this.txHash,
    required this.to,
  });

  /// Send value in base units; wei for a native transfer, raw token units for
  /// an ERC-20 one.
  ///
  /// Exact; formatting for display is the app's job.
  @override
  final BigInt amountBaseUnits;

  /// Maximum fee in **wei**, always; gas is paid in the chain's native coin
  /// even when [amountBaseUnits] is a token amount. See
  /// `CryptoWallet.feeBaseUnitDecimals`.
  @override
  final BigInt feeBaseUnits;

  /// Signed transaction, 0x-prefixed hex, ready for `eth_sendRawTransaction`.
  final String rawHex;

  /// Precomputed transaction hash (keccak256 of the signed payload).
  final String txHash;

  final String to;

  @override
  String toString() =>
      'EthereumPendingTx(${Redact.id(txHash)}, ${Redact.amount(amountBaseUnits)}, '
      'max fee ${Redact.amount(feeBaseUnits)}, to ${Redact.id(to)})';
}
