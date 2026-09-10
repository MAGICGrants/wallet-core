import 'dart:async';

import 'bitcoin_txid.dart';
import 'electrum_api.dart';

/// A scriptable [ElectrumApi] with no socket behind it.
///
/// Exported rather than hidden in `test/`, for the same reason as
/// `FakeMoneroBackend`: the paths worth testing misbehave
/// against real servers, and the consuming apps should be able to test them too.
///
/// The wallet talks to Electrum almost entirely through batched RPC, so the
/// core of this fake is a **method-name → handler** map rather than a set of
/// typed stubs. Register what a test needs; anything unregistered comes back as
/// an error entry, which is what a real server does for an unsupported method
/// and is the more useful default for a wallet that must not assume success.
class FakeElectrumClient implements ElectrumApi {
  FakeElectrumClient();

  // ----- Script -----

  /// Handlers by RPC method name. Params are passed through.
  final Map<String, dynamic Function(List<Object?> params)> handlers = {};

  /// Methods that should fail. Takes precedence over [handlers].
  final Map<String, Object> failing = {};

  bool connectedValue = false;
  List<String> serverVersionValue = const ['ElectrumX 1.16', '1.4'];
  Map<String, dynamic> headerSubscription = const {'height': 800000, 'hex': ''};
  List<List<num>> feeHistogramValue = const [];
  double? estimateFeeValue;

  /// Overrides the txid [broadcastTransaction] reports.
  ///
  /// Null, the default, makes the fake behave like a working server and return
  /// the transaction's *actual* id. It used to return a hardcoded `'a' * 64`,
  /// which no real server would ever say, and which meant nothing could observe
  /// that `commitTx` never compared the two. Set this to drive the disagreement
  /// case deliberately.
  String? broadcastTxid;

  /// When set, [broadcastTransaction] throws it.
  Object? broadcastError;

  /// When true, [connect] throws instead of connecting, the offline server case.
  Object? connectError;

  /// Batches larger than this are rejected wholesale, mimicking the public
  /// servers that silently cap frame size. The real client chunks to avoid it.
  int? maxBatchSize;

  // ----- Recording -----

  final List<String> calls = [];
  final List<List<String>> batches = [];
  final List<String> broadcasts = [];
  final List<({String host, int port, bool useSsl, String? socksHost, int? socksPort})>
  connections = [];

  void Function(bool)? _onConnectionChanged;
  void Function(String, String?)? _scripthashHandler;
  void Function(Map<String, dynamic>)? _headerHandler;

  int countOf(String method) => calls.where((c) => c == method).length;

  /// Simulates a server push for a scripthash whose history changed.
  void pushScripthashStatus(String scripthash, String? status) =>
      _scripthashHandler?.call(scripthash, status);

  /// Simulates a new block.
  void pushHeader(Map<String, dynamic> header) => _headerHandler?.call(header);

  /// Simulates the connection dropping underneath the wallet.
  void dropConnection() {
    connectedValue = false;
    _onConnectionChanged?.call(false);
  }

  void reset() {
    handlers.clear();
    failing.clear();
    calls.clear();
    batches.clear();
    broadcasts.clear();
    connections.clear();
    connectedValue = false;
  }

  // ----- ElectrumApi -----

  @override
  bool get isConnected => connectedValue;

  @override
  set onConnectionChanged(void Function(bool connected)? handler) => _onConnectionChanged = handler;

  @override
  void setScripthashStatusHandler(void Function(String scripthash, String? status) handler) =>
      _scripthashHandler = handler;

  @override
  Future<void> connect({
    required String host,
    required int port,
    bool useSsl = false,
    String? socksHost,
    int? socksPort,
  }) async {
    calls.add('connect');
    connections.add((
      host: host,
      port: port,
      useSsl: useSsl,
      socksHost: socksHost,
      socksPort: socksPort,
    ));

    final error = connectError;
    if (error != null) {
      connectedValue = false;
      throw error;
    }

    connectedValue = true;
    _onConnectionChanged?.call(true);
  }

  @override
  Future<void> close() async {
    calls.add('close');
    connectedValue = false;
  }

  @override
  Future<List<String>> serverVersion({String client = '', String protocol = '1.4'}) async {
    calls.add('server.version');
    _requireConnected();
    return serverVersionValue;
  }

  @override
  Future<Map<String, dynamic>> subscribeHeaders(
    void Function(Map<String, dynamic>) onHeader,
  ) async {
    calls.add('blockchain.headers.subscribe');
    _requireConnected();
    _headerHandler = onHeader;
    return headerSubscription;
  }

  @override
  Future<List<dynamic>> callBatch(List<BatchRpc> requests, {Duration? timeout}) async {
    final results = await callBatchTolerant(requests, timeout: timeout);
    // callBatch is the strict variant: the first failure propagates.
    for (final r in results) {
      if (r.error != null) throw r.error!;
    }
    return [for (final r in results) r.result];
  }

  @override
  Future<List<BatchRpcResult>> callBatchTolerant(
    List<BatchRpc> requests, {
    Duration? timeout,
  }) async {
    _requireConnected();
    if (requests.isEmpty) return const [];

    batches.add([for (final r in requests) r.method]);
    for (final r in requests) {
      calls.add(r.method);
    }

    final cap = maxBatchSize;
    if (cap != null && requests.length > cap) {
      // What an over-capped public server does: the whole frame fails.
      return [
        for (final _ in requests)
          BatchRpcResult(error: const ElectrumDisconnectException('frame too large')),
      ];
    }

    return [
      for (final request in requests)
        if (failing.containsKey(request.method))
          BatchRpcResult(error: failing[request.method])
        else if (handlers.containsKey(request.method))
          BatchRpcResult(result: handlers[request.method]!(request.params))
        else
          BatchRpcResult(error: StateError('FakeElectrumClient: no handler for ${request.method}')),
    ];
  }

  @override
  Future<List<List<num>>> getFeeHistogram({Duration? timeout}) async {
    calls.add('mempool.get_fee_histogram');
    _requireConnected();
    return feeHistogramValue;
  }

  @override
  Future<double?> estimateFee(int blocks, {Duration? timeout}) async {
    calls.add('blockchain.estimatefee');
    _requireConnected();
    return estimateFeeValue;
  }

  @override
  Future<String> broadcastTransaction(String rawHex) async {
    calls.add('blockchain.transaction.broadcast');
    _requireConnected();
    broadcasts.add(rawHex);

    final error = broadcastError;
    if (error != null) throw error;
    return broadcastTxid ?? computeTxid(rawHex);
  }

  void _requireConnected() {
    if (!connectedValue) throw const ElectrumDisconnectException();
  }
}

/// Convenience builders for the RPC shapes the wallet consumes.
///
/// Electrum's responses are untyped maps, and hand-writing them in every test
/// is where transcription mistakes creep in; a wrong key here silently
/// produces an empty balance rather than a failure.
abstract final class ElectrumFixtures {
  /// `blockchain.scripthash.get_balance`
  static Map<String, dynamic> balance({int confirmed = 0, int unconfirmed = 0}) => {
    'confirmed': confirmed,
    'unconfirmed': unconfirmed,
  };

  /// One entry of `blockchain.scripthash.get_history`. Height 0 means mempool.
  static Map<String, dynamic> historyEntry({required String txHash, int height = 0, int? fee}) => {
    'tx_hash': txHash,
    'height': height,
    // A real server omits `fee` entirely for confirmed entries rather than
    // sending null, so the key must be absent, not present-and-null.
    // ignore: use_null_aware_elements
    if (fee != null) 'fee': fee,
  };

  /// One entry of `blockchain.scripthash.listunspent`.
  static Map<String, dynamic> utxo({
    required String txHash,
    required int vout,
    required int valueSats,
    int height = 0,
  }) => {'tx_hash': txHash, 'tx_pos': vout, 'value': valueSats, 'height': height};
}
