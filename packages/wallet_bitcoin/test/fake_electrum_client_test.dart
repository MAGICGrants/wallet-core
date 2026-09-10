import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_bitcoin/wallet_bitcoin.dart';

/// The fake is scaffolding the `BitcoinChainWallet` port will be tested
/// against, so its own behaviour has to be pinned first. An unverified test
/// double is worse than none: it makes wrong code look correct.
void main() {
  late FakeElectrumClient client;

  setUp(() => client = FakeElectrumClient());

  group('connection', () {
    test('starts disconnected and connects on demand', () async {
      expect(client.isConnected, isFalse);
      await client.connect(host: 'electrum.example.com', port: 50002, useSsl: true);
      expect(client.isConnected, isTrue);
    });

    test('records what it was asked to connect to, including the proxy', () async {
      await client.connect(
        host: 'e.example.com',
        port: 50002,
        useSsl: true,
        socksHost: '127.0.0.1',
        socksPort: 9050,
      );
      final c = client.connections.single;
      expect(c.host, 'e.example.com');
      expect(c.port, 50002);
      expect(c.useSsl, isTrue);
      expect(c.socksPort, 9050);
    });

    test('fires onConnectionChanged on connect and on a drop', () async {
      final events = <bool>[];
      client.onConnectionChanged = events.add;

      await client.connect(host: 'h', port: 1);
      client.dropConnection();

      expect(events, [true, false]);
      expect(client.isConnected, isFalse);
    });

    test('connectError leaves it disconnected', () async {
      client.connectError = StateError('refused');
      await expectLater(client.connect(host: 'h', port: 1), throwsStateError);
      expect(client.isConnected, isFalse);
    });

    test('every RPC throws while disconnected', () async {
      // The real client does the same, and the wallet must handle it rather
      // than assume a live socket.
      expect(client.serverVersion(), throwsA(isA<ElectrumDisconnectException>()));
      expect(client.getFeeHistogram(), throwsA(isA<ElectrumDisconnectException>()));
      expect(client.estimateFee(2), throwsA(isA<ElectrumDisconnectException>()));
      expect(client.broadcastTransaction('00'), throwsA(isA<ElectrumDisconnectException>()));
      expect(
        client.callBatchTolerant([const BatchRpc('server.ping', [])]),
        throwsA(isA<ElectrumDisconnectException>()),
      );
    });
  });

  group('batched RPC', () {
    setUp(() => client.connect(host: 'h', port: 1));

    test('dispatches by method name and passes params through', () async {
      final seen = <List<Object?>>[];
      client.handlers['blockchain.scripthash.get_balance'] = (params) {
        seen.add(params);
        return ElectrumFixtures.balance(confirmed: 1500, unconfirmed: 250);
      };

      final results = await client.callBatchTolerant([
        const BatchRpc('blockchain.scripthash.get_balance', ['abc']),
      ]);

      expect(seen, [
        ['abc'],
      ]);
      expect(results.single.error, isNull);
      expect((results.single.result as Map)['confirmed'], 1500);
    });

    test('an unregistered method is an error entry, not a silent success', () async {
      // The dangerous default would be returning null: a wallet reading a
      // balance would see zero and report an empty wallet.
      final results = await client.callBatchTolerant([
        const BatchRpc('blockchain.scripthash.get_balance', ['abc']),
      ]);
      expect(results.single.error, isNotNull);
      expect(results.single.result, isNull);
    });

    test('failing takes precedence over a registered handler', () async {
      client.handlers['server.ping'] = (_) => 'pong';
      client.failing['server.ping'] = StateError('boom');

      final results = await client.callBatchTolerant([const BatchRpc('server.ping', [])]);
      expect(results.single.error, isA<StateError>());
    });

    test('tolerant batching keeps good entries alongside bad ones', () async {
      client.handlers['a'] = (_) => 1;
      client.failing['b'] = StateError('nope');
      client.handlers['c'] = (_) => 3;

      final results = await client.callBatchTolerant([
        const BatchRpc('a', []),
        const BatchRpc('b', []),
        const BatchRpc('c', []),
      ]);

      expect(results.map((r) => r.result).toList(), [1, null, 3]);
      expect(results[1].error, isNotNull);
    });

    test('callBatch is strict — the first failure propagates', () async {
      client.handlers['a'] = (_) => 1;
      client.failing['b'] = StateError('nope');

      expect(
        client.callBatch([const BatchRpc('a', []), const BatchRpc('b', [])]),
        throwsStateError,
      );
    });

    test('an over-cap batch fails wholesale, as a capped server does', () async {
      // Public servers silently drop the socket on an oversized frame; the real
      // client chunks to avoid it, and that chunking is worth testing.
      client.maxBatchSize = 2;
      client.handlers['a'] = (_) => 1;

      final results = await client.callBatchTolerant([
        const BatchRpc('a', []),
        const BatchRpc('a', []),
        const BatchRpc('a', []),
      ]);

      expect(results, hasLength(3));
      expect(results.every((r) => r.error != null), isTrue);
    });

    test('an empty batch is empty, not an error', () async {
      expect(await client.callBatchTolerant([]), isEmpty);
    });

    test('records the batch shape for assertions about pipelining', () async {
      client.handlers['a'] = (_) => 1;
      await client.callBatchTolerant([const BatchRpc('a', []), const BatchRpc('a', [])]);
      await client.callBatchTolerant([const BatchRpc('a', [])]);

      expect(client.batches, [
        ['a', 'a'],
        ['a'],
      ]);
      expect(client.countOf('a'), 3);
    });
  });

  group('server pushes', () {
    setUp(() => client.connect(host: 'h', port: 1));

    test('a scripthash status push reaches the registered handler', () async {
      final seen = <({String sh, String? status})>[];
      client.setScripthashStatusHandler((sh, status) => seen.add((sh: sh, status: status)));

      client.pushScripthashStatus('deadbeef', 'status1');
      client.pushScripthashStatus('deadbeef', null);

      expect(seen, [(sh: 'deadbeef', status: 'status1'), (sh: 'deadbeef', status: null)]);
    });

    test('header subscription returns the tip and later pushes arrive', () async {
      client.headerSubscription = {'height': 800123, 'hex': 'aa'};
      final pushed = <int>[];

      final initial = await client.subscribeHeaders((h) => pushed.add(h['height'] as int));
      expect(initial['height'], 800123);

      client.pushHeader({'height': 800124, 'hex': 'bb'});
      expect(pushed, [800124]);
    });
  });

  group('broadcast', () {
    setUp(() => client.connect(host: 'h', port: 1));

    test('returns the txid and records the raw hex', () async {
      client.broadcastTxid = 'f' * 64;
      expect(await client.broadcastTransaction('0200000001'), 'f' * 64);
      expect(client.broadcasts, ['0200000001']);
    });

    test('broadcastError surfaces — a failed send must never look sent', () async {
      client.broadcastError = StateError('mempool rejected');
      expect(client.broadcastTransaction('00'), throwsStateError);
    });
  });

  group('ElectrumFixtures', () {
    test('balance uses the keys the protocol uses', () {
      expect(ElectrumFixtures.balance(confirmed: 10, unconfirmed: 2), {
        'confirmed': 10,
        'unconfirmed': 2,
      });
    });

    test('a confirmed history entry omits fee entirely rather than nulling it', () {
      // A real server omits the key; present-and-null would be a different
      // shape and could mask a parsing bug.
      expect(
        ElectrumFixtures.historyEntry(txHash: 'ab', height: 800000).containsKey('fee'),
        isFalse,
      );
      expect(ElectrumFixtures.historyEntry(txHash: 'ab', fee: 500)['fee'], 500);
    });

    test('utxo uses tx_pos, not vout', () {
      // Electrum names it tx_pos; getting this wrong silently yields no UTXOs.
      final utxo = ElectrumFixtures.utxo(txHash: 'ab', vout: 1, valueSats: 5000, height: 800000);
      expect(utxo['tx_pos'], 1);
      expect(utxo['value'], 5000);
      expect(utxo.containsKey('vout'), isFalse);
    });
  });
}
