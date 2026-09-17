import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wallet_infra/wallet_infra.dart';

/// One transaction or token transfer from a Blockscout v2 response.
class ExplorerTx {
  ExplorerTx({
    required this.hash,
    required this.from,
    required this.to,
    required this.valueWei,
    required this.feeWei,
    required this.blockNumber,
    required this.status,
    required this.timestamp,
  });

  final String hash;
  final String from;
  final String to;

  /// Base units. Wei for a native transfer, raw token units for an ERC-20 one.
  final BigInt valueWei;
  final BigInt feeWei;

  final int blockNumber;

  /// 1 success, 0 failed.
  final int status;

  /// Unix seconds.
  final int timestamp;

  /// Redacted; this type names two addresses and an amount.
  @override
  String toString() =>
      'ExplorerTx(${Redact.id(hash)}, ${Redact.amount(valueWei)}, '
      'block $blockNumber, status $status)';
}

/// The explorer surface `EthereumChainWallet` uses.
///
/// Separate from the node because an Ethereum RPC cannot list an address's
/// transaction history, which is why `supportsExplorerUrl` exists on
/// `CryptoWallet`. An interface rather than a concrete class so the wallet's
/// history path stays testable without a live Blockscout instance.
abstract class EthereumExplorerApi {
  /// Native transfers involving [address]. Most recent page only.
  Future<List<ExplorerTx>> fetchTxList(String baseUrl, String address, {int? socksPort});

  /// ERC-20 transfers involving [address] for the token at [contractAddress].
  Future<List<ExplorerTx>> fetchTokenTransfers(
    String baseUrl,
    String address,
    String contractAddress, {
    int? socksPort,
  });

  /// Throws unless [baseUrl] answers as a Blockscout v2 instance.
  Future<void> probe(String baseUrl, {int? socksPort});
}

/// Fetches address history from a user-supplied Blockscout instance via its
/// native v2 API. Routes through Tor (SOCKS) when a port is given; using the
/// Content-Length-aware [SOCKSSocket.sendHttpRequest] since history can be
/// large, otherwise a direct [HttpClient].
class EthereumExplorerClient implements EthereumExplorerApi {
  @override
  Future<List<ExplorerTx>> fetchTxList(String baseUrl, String address, {int? socksPort}) async {
    final normalizedBase = _normalizeBase(baseUrl);
    final url = '$normalizedBase/api/v2/addresses/$address/transactions';

    final json = await _getJson(url, socksPort);
    final items = json is Map<dynamic, dynamic> ? json['items'] : null;
    if (items is! List<dynamic>) return const [];

    final out = <ExplorerTx>[];
    for (final t in items) {
      if (t is! Map<dynamic, dynamic>) continue;
      final hash = t['hash'] as String?;
      if (hash == null) continue;
      final fee = t['fee'];
      out.add(
        ExplorerTx(
          hash: hash,
          from: _nestedHash(t['from']),
          to: _nestedHash(t['to']),
          valueWei: BigInt.tryParse('${t['value']}') ?? BigInt.zero,
          feeWei: fee is Map<dynamic, dynamic>
              ? (BigInt.tryParse('${fee['value']}') ?? BigInt.zero)
              : BigInt.zero,
          blockNumber: (t['block_number'] as num?)?.toInt() ?? 0,
          // Only an explicit failure is a failure. `t['status'] == 'ok' ? 1 : 0`
          // turned every *pending* entry, which carries no status at all, into
          // a reverted one, which was invisible while nothing read this field and
          // becomes a wrong badge in the UI the moment something does.
          status: switch (t['status']) {
            'ok' => 1,
            'error' => 0,
            _ => -1,
          },
          timestamp: _parseTimestamp(t['timestamp']),
        ),
      );
    }
    return out;
  }

  @override
  Future<List<ExplorerTx>> fetchTokenTransfers(
    String baseUrl,
    String address,
    String contractAddress, {
    int? socksPort,
  }) async {
    final normalizedBase = _normalizeBase(baseUrl);
    final url = '$normalizedBase/api/v2/addresses/$address/token-transfers?type=ERC-20';
    final contract = contractAddress.toLowerCase();

    final json = await _getJson(url, socksPort);
    final items = json is Map<dynamic, dynamic> ? json['items'] : null;
    if (items is! List<dynamic>) return const [];

    final out = <ExplorerTx>[];
    for (final t in items) {
      if (t is! Map<dynamic, dynamic>) continue;
      final token = t['token'];
      final tokenAddr = token is Map<dynamic, dynamic>
          ? '${token['address'] ?? token['address_hash'] ?? ''}'.toLowerCase()
          : '';
      // Blockscout answers for every ERC-20 the address has touched, so a
      // wallet for one token must drop the rest or it credits other tokens'
      // amounts to itself.
      if (tokenAddr != contract) continue;
      final hash = (t['transaction_hash'] ?? t['tx_hash']) as String?;
      if (hash == null) continue;
      final total = t['total'];
      out.add(
        ExplorerTx(
          hash: hash,
          from: _nestedHash(t['from']),
          to: _nestedHash(t['to']),
          valueWei: total is Map<dynamic, dynamic>
              ? (BigInt.tryParse('${total['value']}') ?? BigInt.zero)
              : BigInt.zero,
          // Gas belongs to the parent transaction, which is known locally only
          // for our own outgoing transfers.
          feeWei: BigInt.zero,
          blockNumber: (t['block_number'] as num?)?.toInt() ?? 0,
          // A token-transfer record only exists because the transfer event was
          // emitted, and a reverted transaction emits nothing.
          status: 1,
          timestamp: _parseTimestamp(t['timestamp']),
        ),
      );
    }
    return out;
  }

  @override
  Future<void> probe(String baseUrl, {int? socksPort}) async {
    final normalizedBase = _normalizeBase(baseUrl);
    final json = await _getJson('$normalizedBase/api/v2/stats', socksPort);
    if (json is! Map<dynamic, dynamic> || json['total_blocks'] == null) {
      throw Exception('Not a Blockscout v2 explorer (unexpected response).');
    }
  }

  /// Blockscout nests addresses as `{"hash": "0x…", …}`.
  static String _nestedHash(Object? node) =>
      node is Map<dynamic, dynamic> ? (node['hash'] as String? ?? '') : '';

  /// Normalizes a user-entered base to the host root: adds https if missing,
  /// strips a trailing slash and any `/api` or `/api/v2` they may have pasted.
  String _normalizeBase(String baseUrl) {
    final raw = baseUrl.trim();
    var b = (raw.startsWith('http://') || raw.startsWith('https://')) ? raw : 'https://$raw';
    b = b.replaceAll(RegExp(r'/+$'), '');
    b = b.replaceAll(RegExp(r'/api(/v2)?$'), '');
    return b;
  }

  int _parseTimestamp(dynamic iso) {
    if (iso is! String) return 0;
    final dt = DateTime.tryParse(iso);
    return dt != null ? dt.millisecondsSinceEpoch ~/ 1000 : 0;
  }

  static const Duration _timeout = Duration(seconds: 30);

  Future<dynamic> _getJson(String url, int? socksPort) async {
    // Every explorer request puts the user's own address in the URL path, so
    // refuse to send it over a channel that does not protect it; plaintext to a
    // routable host, which over Tor is an arbitrary exit node. Checked before any
    // socket is opened, and independent of [socksPort]: routing a plaintext
    // `http://` request through Tor hides the IP but still hands the address to
    // the exit. Mirrors the Monero view-key upload (monero_wallet.dart); `probe`
    // reaches it too, so an insecure explorer is refused at setup rather than
    // saved and silently failing every fetch afterwards.
    // See [EthereumRpcClient]: a configured SOCKS port is Tor whenever the
    // connection uses Tor, and a non-Tor proxy cannot reach `.onion` anyway.
    final viaProxy = socksPort != null && socksPort > 0;

    if (isUnroutedOnion(Uri.parse(url).host, viaProxy: viaProxy)) {
      throw InsecureChannelException(
        endpoint: Uri.parse(url).host,
        carrying: 'a request for your wallet address',
      );
    }

    requireConfidentialChannel(Uri.parse(url), carrying: 'your wallet address', viaTor: viaProxy);
    if (viaProxy) {
      final uri = Uri.parse(url);
      final socket = await SOCKSSocket.create(
        proxyHost: InternetAddress.loopbackIPv4.address,
        proxyPort: socksPort,
        sslEnabled: uri.scheme == 'https',
      );
      try {
        await socket.connect().timeout(_timeout);
        await socket.connectTo(uri.host, uri.port).timeout(_timeout);
        final raw = await socket.sendHttpRequest(
          getRawHttpRequestString('GET', url),
          maxBytes: kDefaultMaxResponseBytes,
          timeout: _timeout,
        );
        return parseHttpResponse(raw).jsonBody;
      } finally {
        // Fire-and-forget: close() can block on flush/cancel and must not stall
        // the result.
        unawaited(socket.close().catchError((Object _) {}));
      }
    }
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(_timeout);
      final resp = await req.close().timeout(_timeout);
      // An address history is the largest thing this package legitimately asks
      // for, so it takes the shared default rather than a tighter cap, but it
      // takes one.
      final text = await readBoundedBody(resp, timeout: _timeout);
      return jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  }
}

/// A scriptable [EthereumExplorerApi] with no network behind it.
///
/// Exported rather than hidden in `test/`, like `FakeElectrumClient`: the paths
/// worth testing misbehave against a real instance, and the
/// consuming apps should be able to test them too.
class FakeEthereumExplorer implements EthereumExplorerApi {
  /// Native transfers returned by [fetchTxList].
  List<ExplorerTx> transfers = const [];

  /// Token transfers returned by [fetchTokenTransfers], keyed by lowercased
  /// contract address.
  Map<String, List<ExplorerTx>> tokenTransfers = const {};

  /// When set, every method throws it.
  Object? error;

  final List<({String baseUrl, String address, int? socksPort})> calls = [];
  final List<String> probes = [];

  @override
  Future<List<ExplorerTx>> fetchTxList(String baseUrl, String address, {int? socksPort}) async {
    calls.add((baseUrl: baseUrl, address: address, socksPort: socksPort));
    final e = error;
    if (e != null) throw e;
    return transfers;
  }

  @override
  Future<List<ExplorerTx>> fetchTokenTransfers(
    String baseUrl,
    String address,
    String contractAddress, {
    int? socksPort,
  }) async {
    calls.add((baseUrl: baseUrl, address: address, socksPort: socksPort));
    final e = error;
    if (e != null) throw e;
    return tokenTransfers[contractAddress.toLowerCase()] ?? const [];
  }

  @override
  Future<void> probe(String baseUrl, {int? socksPort}) async {
    probes.add(baseUrl);
    final e = error;
    if (e != null) throw e;
  }
}
