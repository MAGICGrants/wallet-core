import 'package:web3dart/crypto.dart';

import 'ethereum_rpc_api.dart';

/// A scriptable [EthereumRpcApi] with no network behind it.
///
/// Exported rather than hidden in `test/`, for the same reason as
/// `FakeElectrumClient`: the paths worth testing misbehave
/// against real nodes; a chain-id mismatch, a reverting `estimateGas`, a
/// broadcast the mempool rejects, and the consuming apps should be able to test
/// them too.
///
/// Every value defaults to something a healthy mainnet node would return, so a
/// test only sets what it is about.
class FakeEthereumRpc implements EthereumRpcApi {
  FakeEthereumRpc({this.chainIdValue = 1});

  // ----- Script -----

  int chainIdValue;
  int blockNumberValue = 21000000;
  BigInt balanceValue = BigInt.zero;
  int nonceValue = 0;
  BigInt baseFeeValue = BigInt.from(20000000000); // 20 gwei
  BigInt tipValue = BigInt.from(1000000000); // 1 gwei
  BigInt? estimateGasValue;
  String ethCallValue = '0x0';

  /// Overrides the transaction hash [sendRawTransaction] reports.
  ///
  /// Null, the default, makes the fake behave like a working node and hash the
  /// bytes it was actually given. It used to return a fixed `0xabab…`, which no
  /// node would ever say for a real transaction, so nothing could observe that
  /// `commitTx` never compared the node's answer with the hash it had signed.
  /// Set this to drive the disagreement case deliberately.
  String? broadcastHash;

  /// Receipts by transaction hash. An absent hash reads as "still pending",
  /// which is what a node returns before the transaction is mined.
  final Map<String, EthReceipt> receipts = {};

  /// Errors by member name (`chainId`, `estimateGas`, `sendRawTransaction`, …).
  /// Takes precedence over the scripted value.
  final Map<String, Object> failing = {};

  // ----- Recording -----

  final List<String> calls = [];
  final List<String> broadcasts = [];
  final List<({String url, int? socksPort})> configurations = [];

  int countOf(String member) => calls.where((c) => c == member).length;

  // ----- EthereumRpcApi -----

  String? _url;

  @override
  void configure({required String url, int? socksPort}) {
    configurations.add((url: url, socksPort: socksPort));
    _url = url.startsWith('http') ? url : 'https://$url';
  }

  @override
  bool get isConfigured => _url != null && _url!.isNotEmpty;

  @override
  String? get url => _url;

  @override
  Future<int> chainId() async => _guard('chainId', chainIdValue);

  @override
  Future<int> blockNumber() async => _guard('blockNumber', blockNumberValue);

  @override
  Future<BigInt> getBalance(String address) async => _guard('getBalance', balanceValue);

  @override
  Future<int> getTransactionCount(String address) async =>
      _guard('getTransactionCount', nonceValue);

  @override
  Future<BigInt> baseFeePerGas() async => _guard('baseFeePerGas', baseFeeValue);

  @override
  Future<BigInt> maxPriorityFeePerGas() async => _guard('maxPriorityFeePerGas', tipValue);

  @override
  Future<BigInt> estimateGas({
    required String from,
    required String to,
    required BigInt value,
    String? data,
  }) async => _guard('estimateGas', estimateGasValue ?? BigInt.from(21000));

  @override
  Future<String> ethCall(String to, String data) async => _guard('ethCall', ethCallValue);

  @override
  Future<String> sendRawTransaction(String rawHex) async {
    broadcasts.add(rawHex);
    final hash = broadcastHash ?? '0x${bytesToHex(keccak256(hexToBytes(rawHex)))}';
    return _guard('sendRawTransaction', hash);
  }

  @override
  Future<EthReceipt?> getTransactionReceipt(String hash) async =>
      _guard('getTransactionReceipt', receipts[hash]);

  T _guard<T>(String member, T value) {
    calls.add(member);
    final error = failing[member];
    if (error != null) throw error;
    return value;
  }
}
