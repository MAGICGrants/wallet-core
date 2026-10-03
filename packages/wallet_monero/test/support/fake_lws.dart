import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:blockchain_utils/blockchain_utils.dart';

import 'monero_test_crypto.dart';

/// An output a [FakeLws] reports its wallet as having received.
final class FakeLwsOutput {
  FakeLwsOutput._({
    required this.amount,
    required this.globalIndex,
    required this.major,
    required this.minor,
    required this.publicKey,
    required this.txPublicKey,
    required this.commitment,
  }) : txHash = _randomBytes(32),
       txPrefixHash = _randomBytes(32);

  /// An output paying [amount] to the wallet's subaddress ([major], [minor]),
  /// whose public spend key is [spendPublicKey], as the first output of its
  /// transaction.
  ///
  /// Built as a sender builds it: the transaction public key is r·G for the
  /// primary address and r·D for a subaddress with spend key D, and the
  /// wallet, holding [viewSecret], derives the output's key and RingCT mask
  /// from it. A wallet that tried to spend an output it did not own would
  /// fail inside Monero's transaction construction, so these must be right.
  factory FakeLwsOutput.paying({
    required BigInt amount,
    required BigInt viewSecret,
    required List<int> spendPublicKey,
    required int major,
    required int minor,
    required int globalIndex,
  }) {
    const index = 0;
    final txSecret = MoneroTestCrypto.randomScalar();
    final txPublicKey = major == 0 && minor == 0
        ? MoneroTestCrypto.publicKey(txSecret)
        : MoneroTestCrypto.encode(MoneroTestCrypto.point(spendPublicKey) * txSecret);
    final derivation = MoneroTestCrypto.keyDerivation(txPublicKey, viewSecret);
    final mask = MoneroTestCrypto.commitmentMask(
      MoneroTestCrypto.derivationToScalar(derivation, index),
    );
    return FakeLwsOutput._(
      amount: amount,
      globalIndex: globalIndex,
      major: major,
      minor: minor,
      publicKey: MoneroTestCrypto.derivePublicKey(derivation, index, spendPublicKey),
      txPublicKey: txPublicKey,
      commitment: MoneroTestCrypto.commit(amount, mask),
    );
  }

  final BigInt amount;
  final int globalIndex;
  final int major;
  final int minor;
  final List<int> publicKey;
  final List<int> txPublicKey;
  final List<int> commitment;
  final List<int> txHash;
  final List<int> txPrefixHash;
}

/// A light-wallet server on loopback that answers for one wallet: it logs the
/// wallet in, reports [outputs] as received and unlocked, quotes a fee, hands
/// out decoys, and accepts the transactions the wallet submits.
///
/// It speaks the MyMonero-compatible REST API that monero-lws serves, with the
/// fields LWSF reads. LWSF must choose the outputs to spend, build the rings,
/// and sign; nothing here checks a transaction, so whoever reads [submitted]
/// does.
final class FakeLws {
  FakeLws._(this._server, this.outputs, this.chainHeight) {
    _server.listen(_handle);
  }

  /// Starts the server with [outputs] confirmed 100 blocks below
  /// [chainHeight].
  static Future<FakeLws> start({
    required List<FakeLwsOutput> outputs,
    int chainHeight = 3500000,
  }) async =>
      FakeLws._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), outputs, chainHeight);

  final HttpServer _server;
  final List<FakeLwsOutput> outputs;
  final int chainHeight;

  /// Per-byte fees for each priority, and the multiple a fee is rounded up to.
  static const perByteFees = [20000, 80000, 320000, 4000000];
  static const feeMask = 10000;

  /// Where decoy global indices start, well clear of the real outputs'.
  static const _firstDecoyIndex = 50000000;
  var _nextDecoyIndex = _firstDecoyIndex;

  /// The lookahead the wallet asked for at login, echoed back so it never
  /// needs to ask the server to scan further.
  Map<String, Object?> _lookahead = const {'maj_i': 50, 'min_i': 200};

  /// Every request, in order: its path and decoded JSON body.
  final List<({String path, Object? body})> requests = [];

  /// The raw transactions the wallet submitted, in order.
  final List<List<int>> submitted = [];

  /// The URL to give the wallet.
  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  int get _outputHeight => chainHeight - 100;

  Future<void> _handle(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    final body = raw.isEmpty ? null : jsonDecode(raw);
    final path = request.uri.path;
    requests.add((path: path, body: body));

    final answer = _answer(path, body);
    final bytes = answer == null ? const <int>[] : utf8.encode(jsonEncode(answer));
    request.response
      ..statusCode = answer == null ? HttpStatus.notFound : HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..contentLength = bytes.length
      ..add(bytes);
    await request.response.close();
  }

  /// The JSON for [path], or null for a 404.
  Object? _answer(String path, Object? body) {
    final fields = body is Map<String, Object?> ? body : const <String, Object?>{};
    switch (path) {
      case '/login':
        if (fields['lookahead'] case final Map<String, Object?> lookahead) _lookahead = lookahead;
        return {'new_address': false, 'start_height': 0, 'lookahead': _lookahead};
      case '/upsert_subaddrs':
        return <String, Object?>{};
      case '/get_version':
        return {'max_subaddresses': 10000};
      case '/get_subaddrs':
        return {'all_subaddrs': <Object?>[]};
      case '/provision_subaddrs':
        return {'new_subaddrs': <Object?>[], 'all_subaddrs': <Object?>[]};
      case '/import_wallet_request':
        return {
          'lookahead': _lookahead,
          'status': 'OK',
          'new_request': false,
          'request_fulfilled': true,
        };
      case '/daemon_status':
        return {
          'outgoing_connections_count': 8,
          'incoming_connections_count': 0,
          'height': chainHeight,
          'target_height': chainHeight,
        };
      case '/get_address_txs':
        return {
          'total_received': '${_total()}',
          'scanned_height': chainHeight,
          'scanned_block_height': chainHeight,
          'start_height': 0,
          'blockchain_height': chainHeight,
          'lookahead': _lookahead,
          'transactions': [
            for (final (i, output) in outputs.indexed)
              {
                'id': i + 1,
                'hash': _hex(output.txHash),
                'total_received': '${output.amount}',
                'total_sent': '0',
                'unlock_time': 0,
                'height': _outputHeight,
                'spent_outputs': <Object?>[],
                'coinbase': false,
                'mempool': false,
                'mixin': 15,
              },
          ],
        };
      case '/get_unspent_outs':
        return {
          'per_byte_fee': perByteFees.first,
          'fee_mask': feeMask,
          'fees': perByteFees,
          'amount': '${_total()}',
          'outputs': [
            for (final output in outputs)
              {
                'amount': '${output.amount}',
                'index': 0,
                'global_index': '${output.globalIndex}',
                // A bare commitment, as monero-lws sends it: the wallet
                // recomputes the mask from its view key.
                'rct': _hex(output.commitment),
                'tx_hash': _hex(output.txHash),
                'tx_prefix_hash': _hex(output.txPrefixHash),
                'public_key': _hex(output.publicKey),
                'tx_pub_key': _hex(output.txPublicKey),
                'spend_key_images': <Object?>[],
                'height': _outputHeight,
                'recipient': {'maj_i': output.major, 'min_i': output.minor},
              },
          ],
        };
      case '/get_random_outs':
        final amounts = (fields['amounts'] as List<Object?>?) ?? const [];
        final count = (fields['count'] as int?) ?? 0;
        return {
          'amount_outs': [
            for (final amount in amounts)
              {
                'amount': amount,
                'outputs': [
                  for (var i = 0; i < count; i++)
                    {
                      'global_index': '${_nextDecoyIndex++}',
                      'public_key': _hex(MoneroTestCrypto.randomPoint()),
                      'rct': _hex(MoneroTestCrypto.randomPoint()),
                    },
                ],
              },
          ],
        };
      case '/submit_raw_tx':
        submitted.add(BytesUtils.fromHexString(fields['tx']! as String));
        return {'status': 'OK'};
      default:
        // Including `/feed`: a 404 there tells LWSF to poll instead.
        return null;
    }
  }

  BigInt _total() => outputs.fold(BigInt.zero, (sum, o) => sum + o.amount);
}

String _hex(List<int> bytes) => BytesUtils.toHexString(bytes);

final _random = Random.secure();

List<int> _randomBytes(int n) => List<int>.generate(n, (_) => _random.nextInt(256));
