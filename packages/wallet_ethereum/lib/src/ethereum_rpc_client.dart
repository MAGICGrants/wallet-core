import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wallet_infra/wallet_infra.dart';

import 'ethereum_rpc_api.dart';

export 'ethereum_rpc_api.dart' show EthReceipt, EthereumRpcException;

/// Minimal Ethereum JSON-RPC client over the shared Tor/clearnet HTTP path.
///
/// Stateless: every call is an HTTP POST. Routes through Tor when a SOCKS port
/// is configured (reusing [makeSocksHttpRequest]), otherwise a direct
/// [HttpClient]. Responses are **not** all small; `eth_getBlockByNumber`
/// returns the block's whole txid array, tens of kilobytes on a full block, and
/// `createTx` calls it; so [makeSocksHttpRequest] frames the body properly
/// rather than stopping at the headers.
/// Ceiling on a JSON-RPC reply.
///
/// Generous for what these calls actually return; a balance, a nonce, a gas
/// estimate, a receipt, and small enough that a node answering with megabytes
/// is refused immediately rather than read. See `kDefaultMaxResponseBytes` for
/// why the number is a policy choice and the existence of one is not.
const int maxRpcResponseBytes = 2 * 1024 * 1024;

class EthereumRpcClient implements EthereumRpcApi {
  EthereumRpcClient({this.coinSymbol});

  /// Coin tag for log lines (e.g. `ETH`).
  final String? coinSymbol;

  String? _url;
  int? _socksPort;
  int _nextId = 0;

  static const Duration _timeout = Duration(seconds: 30);

  @override
  void configure({required String url, int? socksPort}) {
    // The connection form strips the scheme (it's built for host:port); RPC
    // URLs need one, so default to https.
    final u = url.trim();
    _url = (u.startsWith('http://') || u.startsWith('https://')) ? u : 'https://$u';
    _socksPort = socksPort;
  }

  @override
  bool get isConfigured => _url != null && _url!.isNotEmpty;

  @override
  String? get url => _url;

  Future<dynamic> call(String method, List<dynamic> params, {Duration? timeout}) async {
    final url = _url;
    if (url == null || url.isEmpty) {
      throw EthereumRpcException('RPC URL not configured');
    }
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': method,
      'params': params,
    });
    final decoded = await _post(url, body, timeout ?? _timeout);
    if (decoded is! Map<dynamic, dynamic>) throw EthereumRpcException('Malformed RPC response');
    final error = decoded['error'];
    if (error != null) {
      // The message is the node's, and a node quotes the parameters it was sent
      //, which include an address. It is carried on the exception so a caller
      // can act on it, but see the `walletLog` calls in EthereumChainWallet:
      // none of them interpolate it.
      final msg = error is Map<dynamic, dynamic>
          ? (error['message']?.toString() ?? '$error')
          : '$error';
      throw EthereumRpcException(msg);
    }
    return decoded['result'];
  }

  Future<dynamic> _post(String url, String body, Duration timeout) async {
    // Most RPC calls carry the user's address in their params (balance, nonce,
    // gas), so refuse to send them over a plaintext channel to a routable host;
    // over Tor that is an arbitrary exit node. Checked before any socket is
    // opened; local and onion endpoints pass, plaintext-clearnet is refused. The
    // scheme is normally https already (configure defaults to it), so this
    // catches an explicit `http://` the user typed.
    //
    // `CryptoWallet` hands this layer Tor's own port whenever the connection
    // uses Tor, so a configured proxy is the only way an onion RPC has ever
    // reached anything here. A user-supplied non-Tor proxy cannot resolve
    // `.onion` at all, so it fails to connect rather than leaking: the hostname
    // reaches the user's own proxy and no further.
    final socksPort = _socksPort;
    requireConfidentialChannel(
      Uri.parse(url),
      carrying: 'your wallet address',
      viaTor: socksPort != null && socksPort > 0,
    );
    if (socksPort != null && socksPort > 0) {
      // Bounded inside the read rather than by a `.timeout()` around it: the
      // wrapper completed this future while the socket kept filling a buffer
      // nobody would read. A JSON-RPC reply is small: a receipt, a balance, a
      // block number; so the cap is far below the shared default.
      final resp = await makeSocksHttpRequest(
        'POST',
        url,
        (host: InternetAddress.loopbackIPv4, port: socksPort),
        body: body,
        maxBytes: maxRpcResponseBytes,
        timeout: timeout,
      );
      final json = resp.jsonBody;
      if (json == null) {
        throw EthereumRpcException('Non-JSON response (status ${resp.statusCode})');
      }
      return json;
    }
    return _postDirect(url, body, timeout);
  }

  Future<dynamic> _postDirect(String url, String body, Duration timeout) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse(url)).timeout(timeout);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.write(body);
      final resp = await req.close().timeout(timeout);
      // `transform(utf8.decoder).join()` was unbounded: it reads whatever the
      // node sends, for as long as it sends it.
      final text = await readBoundedBody(resp, maxBytes: maxRpcResponseBytes, timeout: timeout);
      return jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }

  // ----- Typed helpers -----

  @override
  Future<int> chainId() async => _hexToInt(await call('eth_chainId', []));

  @override
  Future<int> blockNumber() async => _hexToInt(await call('eth_blockNumber', []));

  @override
  Future<BigInt> getBalance(String address) async =>
      _hexToBigInt(await call('eth_getBalance', [address, 'latest']));

  @override
  Future<int> getTransactionCount(String address) async =>
      _hexToInt(await call('eth_getTransactionCount', [address, 'pending']));

  @override
  Future<BigInt> baseFeePerGas() async {
    final block = await call('eth_getBlockByNumber', ['latest', false]);
    if (block is Map<dynamic, dynamic> && block['baseFeePerGas'] != null) {
      return _hexToBigInt(block['baseFeePerGas']);
    }
    return BigInt.zero;
  }

  @override
  Future<BigInt> maxPriorityFeePerGas() async {
    try {
      return _hexToBigInt(await call('eth_maxPriorityFeePerGas', []));
    } catch (_) {
      return BigInt.from(1000000000);
    }
  }

  @override
  Future<BigInt> estimateGas({
    required String from,
    required String to,
    required BigInt value,
    String? data,
  }) async {
    final tx = {'from': from, 'to': to, 'value': '0x${value.toRadixString(16)}'};
    if (data != null && data.isNotEmpty) tx['data'] = data;
    return _hexToBigInt(await call('eth_estimateGas', [tx]));
  }

  @override
  Future<String> ethCall(String to, String data) async {
    final r = await call('eth_call', [
      {'to': to, 'data': data},
      'latest',
    ]);
    if (r is String) return r;
    throw EthereumRpcException('Unexpected eth_call response type: ${r.runtimeType}');
  }

  @override
  Future<String> sendRawTransaction(String rawHex) async {
    final r = await call('eth_sendRawTransaction', [rawHex]);
    if (r is String) return r;
    throw EthereumRpcException('Unexpected broadcast response type: ${r.runtimeType}');
  }

  @override
  Future<EthReceipt?> getTransactionReceipt(String hash) async {
    final r = await call('eth_getTransactionReceipt', [hash]);
    if (r is! Map<dynamic, dynamic>) return null;
    return EthReceipt(
      blockNumber: _hexToInt(r['blockNumber']),
      gasUsed: _hexToBigInt(r['gasUsed']),
      effectiveGasPrice: r['effectiveGasPrice'] != null
          ? _hexToBigInt(r['effectiveGasPrice'])
          : BigInt.zero,
      status: r['status'] != null ? _hexToInt(r['status']) : -1,
    );
  }

  static int _hexToInt(dynamic hex) => _hexToBigInt(hex).toInt();

  static BigInt _hexToBigInt(dynamic hex) {
    // The type, not the value: a malformed field here is server-controlled and
    // this message reaches a log.
    if (hex is! String) {
      throw EthereumRpcException('Expected a hex string, got ${hex.runtimeType}');
    }
    final clean = hex.startsWith('0x') ? hex.substring(2) : hex;
    if (clean.isEmpty) return BigInt.zero;
    return BigInt.parse(clean, radix: 16);
  }
}
