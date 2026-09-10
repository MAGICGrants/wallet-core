import 'electrum_client.dart' show BatchRpc, BatchRpcResult;

export 'electrum_client.dart' show BatchRpc, BatchRpcResult, ElectrumDisconnectException;

/// The Electrum surface `BitcoinChainWallet` actually uses.
///
/// Deliberately narrower than [ElectrumClient]'s full API; it is the twelve
/// members the wallet calls, nothing more. Same discipline as `MoneroBackend`:
/// the seam is shaped by what the caller needs, not by everything the
/// implementation can do, so a fake has a small surface to be honest about.
///
/// Note what is *not* here: `getBalance`, `getHistory`, `listUnspent`,
/// `getTransaction`. The wallet never calls those individually; it issues
/// everything through [callBatch] / [callBatchTolerant], because one framed
/// batch is a single round trip instead of N. So a fake mostly needs to answer
/// RPC methods by name, which is simpler than stubbing a dozen typed helpers.
abstract class ElectrumApi {
  bool get isConnected;

  /// Fired whenever the connection flips.
  set onConnectionChanged(void Function(bool connected)? handler);

  /// Registers the handler for `blockchain.scripthash.subscribe` pushes.
  void setScripthashStatusHandler(void Function(String scripthash, String? status) handler);

  Future<void> connect({
    required String host,
    required int port,
    bool useSsl,
    String? socksHost,
    int? socksPort,
  });

  Future<void> close();

  Future<List<String>> serverVersion({String client, String protocol});

  /// Subscribes to new block headers. Returns the initial response, which
  /// carries `height` and `hex`; later pushes arrive via [onHeader].
  Future<Map<String, dynamic>> subscribeHeaders(void Function(Map<String, dynamic>) onHeader);

  /// Throws on the first failure.
  Future<List<dynamic>> callBatch(List<BatchRpc> requests, {Duration? timeout});

  /// Per-entry results, so one bad response does not lose the whole batch.
  Future<List<BatchRpcResult>> callBatchTolerant(List<BatchRpc> requests, {Duration? timeout});

  /// Mempool fee histogram, `[[feerateSatVb, vsize], ...]` descending by rate.
  Future<List<List<num>>> getFeeHistogram({Duration? timeout});

  /// BTC/kB, or null when the server cannot estimate. Convert to sat/vB with
  /// `value * 1e8 / 1000`.
  Future<double?> estimateFee(int blocks, {Duration? timeout});

  Future<String> broadcastTransaction(String rawHex);
}
