/// A mined transaction's receipt, reduced to the four fields the wallet reads.
class EthReceipt {
  EthReceipt({
    required this.blockNumber,
    required this.gasUsed,
    required this.effectiveGasPrice,
    required this.status,
  });

  final int blockNumber;
  final BigInt gasUsed;
  final BigInt effectiveGasPrice;

  /// 1 success, 0 failed, -1 unknown.
  final int status;
}

class EthereumRpcException implements Exception {
  EthereumRpcException(this.message);

  final String message;

  @override
  String toString() => 'EthereumRpcException: $message';
}

/// The JSON-RPC surface `EthereumChainWallet` actually uses.
///
/// Same discipline as `ElectrumApi`: the seam is shaped by what the caller
/// needs, not by everything `eth_*` can do, so a fake has a small surface to be
/// honest about. Notably absent is the untyped `call(method, params)`; the
/// wallet never reaches past these helpers, and exposing it would let a test
/// stub a method the wallet does not use.
abstract class EthereumRpcApi {
  /// Points the client at [url]. Called on every connect, so it must be
  /// idempotent and must replace any previous endpoint.
  void configure({required String url, int? socksPort});

  bool get isConfigured;

  /// The configured endpoint. Needed because `web3dart`'s `Web3Client` demands
  /// one even when it is only used to sign offline.
  String? get url;

  Future<int> chainId();

  Future<int> blockNumber();

  Future<BigInt> getBalance(String address);

  /// Nonce including pending transactions, so two sends in a row don't collide.
  Future<int> getTransactionCount(String address);

  /// Base fee of the latest block (EIP-1559). Zero on a pre-1559 chain.
  Future<BigInt> baseFeePerGas();

  Future<BigInt> maxPriorityFeePerGas();

  Future<BigInt> estimateGas({
    required String from,
    required String to,
    required BigInt value,
    String? data,
  });

  /// Read-only contract call. Returns the raw hex result.
  Future<String> ethCall(String to, String data);

  Future<String> sendRawTransaction(String rawHex);

  /// Null while the transaction is still pending.
  Future<EthReceipt?> getTransactionReceipt(String hash);
}
