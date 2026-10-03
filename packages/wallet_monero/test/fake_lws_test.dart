import 'dart:convert';
import 'dart:io';

import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_lws.dart';
import 'support/monero_test_crypto.dart';

/// The light-wallet server the LWSF send test runs against. That test needs a
/// monero_c build; these make sure that, when it fails, it is the library and
/// not the server.
void main() {
  final wallet = Monero.fromPrivateSpendKey(
    MoneroTestCrypto.scalarBytes(MoneroTestCrypto.randomScalar()),
  );
  final viewSecret = MoneroTestCrypto.scalar(wallet.privateViewKey.raw);
  List<int> spendKey(int major, int minor) =>
      wallet.scubaddr.computeKeys(minor, major).item1.compressed;

  late FakeLws server;
  late HttpClient client;

  setUp(() async {
    server = await FakeLws.start(
      outputs: [
        FakeLwsOutput.paying(
          amount: BigInt.from(700000000000),
          viewSecret: viewSecret,
          spendPublicKey: spendKey(0, 0),
          major: 0,
          minor: 0,
          globalIndex: 1000000,
        ),
        FakeLwsOutput.paying(
          amount: BigInt.from(500000000000),
          viewSecret: viewSecret,
          spendPublicKey: spendKey(1, 1),
          major: 1,
          minor: 1,
          globalIndex: 1000001,
        ),
      ],
    );
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close();
  });

  Future<(int, Map<String, Object?>?)> call(String path, [Object? body]) async {
    final request = body == null
        ? await client.getUrl(Uri.parse('${server.url}$path'))
        : await client.postUrl(Uri.parse('${server.url}$path'));
    if (body != null) request.write(jsonEncode(body));
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return (response.statusCode, text.isEmpty ? null : jsonDecode(text) as Map<String, Object?>);
  }

  test('logs in, echoing the lookahead the wallet asked for', () async {
    final (status, login) = await call('/login', {
      'address': wallet.primaryAddress,
      'view_key': BytesUtils.toHexString(wallet.privateViewKey.raw),
      'lookahead': {'maj_i': 3, 'min_i': 40},
      'create_account': true,
      'generated_locally': true,
    });

    expect(status, 200);
    expect(login, {
      'new_address': false,
      'start_height': 0,
      'lookahead': {'maj_i': 3, 'min_i': 40},
    });
    final (_, txs) = await call('/get_address_txs', {});
    expect(txs!['lookahead'], {'maj_i': 3, 'min_i': 40});
  });

  test('answers /feed with a 404, so the wallet polls', () async {
    final (status, body) = await call('/feed');

    expect(status, 404);
    expect(body, isNull);
  });

  test('reports each output in a confirmed transaction, owned as the wallet derives it', () async {
    final (_, txs) = await call('/get_address_txs', {});
    final (_, unspent) = await call('/get_unspent_outs', {});

    final transactions = (txs!['transactions']! as List<Object?>).cast<Map<String, Object?>>();
    expect(txs['blockchain_height'], server.chainHeight);
    expect(transactions.map((t) => t['height']), everyElement(server.chainHeight - 100));
    expect(transactions.map((t) => t['unlock_time']), everyElement(0));

    final outputs = (unspent!['outputs']! as List<Object?>).cast<Map<String, Object?>>();
    expect(outputs.map((o) => o['tx_hash']), transactions.map((t) => t['hash']));
    expect(unspent['fees'], FakeLws.perByteFees);
    expect(unspent['fee_mask'], FakeLws.feeMask);

    for (final (o, expected) in [(outputs[0], (0, 0)), (outputs[1], (1, 1))]) {
      final (major, minor) = expected;
      expect(o['recipient'], {'maj_i': major, 'min_i': minor});

      // What LWSF computes: the output key from the view key and its
      // subaddress's spend key, and the mask from the view key alone.
      final derivation = MoneroTestCrypto.keyDerivation(
        BytesUtils.fromHexString(o['tx_pub_key']! as String),
        viewSecret,
      );
      final index = o['index']! as int;
      expect(
        o['public_key'],
        BytesUtils.toHexString(
          MoneroTestCrypto.derivePublicKey(derivation, index, spendKey(major, minor)),
        ),
      );
      final mask = MoneroTestCrypto.commitmentMask(
        MoneroTestCrypto.derivationToScalar(derivation, index),
      );
      expect(
        o['rct'],
        BytesUtils.toHexString(MoneroTestCrypto.commit(BigInt.parse(o['amount']! as String), mask)),
      );
    }
  });

  test('hands out exactly the decoys asked for, each a fresh index and a valid point', () async {
    final (_, body) = await call('/get_random_outs', {
      'amounts': ['0', '0'],
      'count': 15,
    });

    final rings = (body!['amount_outs']! as List<Object?>).cast<Map<String, Object?>>();
    expect(rings, hasLength(2));
    final indices = <String>{};
    for (final ring in rings) {
      expect(ring['amount'], '0');
      final decoys = (ring['outputs']! as List<Object?>).cast<Map<String, Object?>>();
      expect(decoys, hasLength(15));
      for (final decoy in decoys) {
        indices.add(decoy['global_index']! as String);
        for (final field in ['public_key', 'rct']) {
          expect(
            () => MoneroTestCrypto.point(BytesUtils.fromHexString(decoy[field]! as String)),
            returnsNormally,
          );
        }
      }
    }
    expect(indices, hasLength(30), reason: 'no index is handed out twice');
    expect(
      indices.map(int.parse).where((i) => i == 1000000 || i == 1000001),
      isEmpty,
      reason: "a decoy is never one of the wallet's outputs",
    );
  });

  test('records a submitted transaction and accepts it', () async {
    final (status, body) = await call('/submit_raw_tx', {'tx': '0211ff'});

    expect(status, 200);
    expect(body, {'status': 'OK'});
    expect(server.submitted, [
      [0x02, 0x11, 0xff],
    ]);
  });

  test('records every request, including the ones it does not know', () async {
    await call('/login', {});
    final (status, _) = await call('/no_such_endpoint', {'x': 1});

    expect(status, 404);
    expect(server.requests.map((r) => r.path), ['/login', '/no_such_endpoint']);
    expect(server.requests.last.body, {'x': 1});
  });
}
