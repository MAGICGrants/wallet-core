import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_ethereum/wallet_ethereum.dart';

/// Address poisoning: a third party's `transferFrom(victim, lookalike, 0)` emits
/// `Transfer(victim, lookalike, 0)`, which Blockscout lists under the victim's
/// token transfers. Classified `from == me`, it used to read as the user's own
/// "Sent 0 DAI to 0x…" — bait for copying the lookalike from history. The wallet
/// never sends 0, so zero-value transfers are dropped.
void main() {
  const address = '0x1111111111111111111111111111111111111111';
  const contract = '0x6B175474E89094C44Da98b954EedeAC495271d0F';
  const lookalike = '0x7099797905330000000000000000000000000000';
  const realSender = '0x2222222222222222222222222222222222222222';

  late HttpServer server;
  late EthereumExplorerClient client;

  Map<String, dynamic> transfer(String hash, String from, String to, String value, int block) => {
    'token': {'address': contract},
    'transaction_hash': hash,
    'from': {'hash': from},
    'to': {'hash': to},
    'total': {'value': value},
    'block_number': block,
    'timestamp': '2024-01-0${block}T00:00:00.000000Z',
  };

  setUp(() async {
    client = EthereumExplorerClient();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'items': [
              transfer('0xpoison', address, lookalike, '0', 1),
              transfer('0xreal', realSender, address, '1000000000000000000', 2),
            ],
          }),
        );
      req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('a zero-value token transfer (address poisoning) is dropped', () async {
    final txs = await client.fetchTokenTransfers(
      'http://127.0.0.1:${server.port}',
      address,
      contract,
    );

    expect(txs.map((t) => t.hash), ['0xreal']);
    expect(txs.every((t) => t.valueWei > BigInt.zero), isTrue);
  });
}
