import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_bitcoin/wallet_bitcoin.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Line framing for [ElectrumClient], over a real loopback socket.
///
/// `_onData` is private and only reachable through `connect`, so this stands up
/// an actual server rather than poking at internals, which also means the test
/// exercises the socket path the app uses.
///
/// The buffer this covers was `_buffer += utf8.decode(chunk)` with a
/// `substring` per line: two full copies of everything pending, per chunk and
/// per line. Three of the audit's reviewers found it independently.
class _FakeElectrumServer {
  _FakeElectrumServer._(this._server);

  final ServerSocket _server;
  final List<Socket> _clients = [];
  final _connected = Completer<Socket>();

  int get port => _server.port;

  /// The first client socket, once something connects.
  Future<Socket> get client => _connected.future;

  static Future<_FakeElectrumServer> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeElectrumServer._(server);
    server.listen((socket) {
      fake._clients.add(socket);
      // Drain requests; this server answers on the test's schedule, not the
      // client's.
      socket.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
      if (!fake._connected.isCompleted) fake._connected.complete(socket);
    });
    return fake;
  }

  Future<void> stop() async {
    for (final c in _clients) {
      try {
        await c.close();
      } catch (_) {}
    }
    await _server.close();
  }
}

void main() {
  late _FakeElectrumServer server;
  late ElectrumClient client;

  setUp(() async {
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletLog.sink = MemoryLogSink();
    WalletLog.isVerbose = () async => true;
    server = await _FakeElectrumServer.start();
    client = ElectrumClient(coinSymbol: 'BTC');
  });

  tearDown(() async {
    await client.close();
    await server.stop();
    SharedPreferencesService.resetForTesting();
    WalletLog.resetForTesting();
  });

  Future<void> connect() =>
      client.connect(host: InternetAddress.loopbackIPv4.address, port: server.port);

  group('framing', () {
    test('a reply split across TCP segments is assembled', () async {
      await connect();
      final pending = client.ping();

      final socket = await server.client;
      // The id is the client's first, so 0. Split mid-JSON, which is exactly
      // what a segment boundary does.
      socket.add(utf8.encode('{"jsonrpc":"2.0","id":0,'));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      socket.add(utf8.encode('"result":null}\n'));
      await socket.flush();

      await expectLater(pending, completes);
    });

    test('two replies in one segment are both dispatched', () async {
      await connect();
      final first = client.serverVersion();
      final second = client.ping();

      final socket = await server.client;
      socket.add(
        utf8.encode(
          '{"jsonrpc":"2.0","id":0,"result":["ElectrumX 1.16","1.4"]}\n'
          '{"jsonrpc":"2.0","id":1,"result":null}\n',
        ),
      );
      await socket.flush();

      expect(await first, ['ElectrumX 1.16', '1.4']);
      await expectLater(second, completes);
    });

    test('blank lines between frames are ignored', () async {
      await connect();
      final pending = client.ping();

      final socket = await server.client;
      socket.add(utf8.encode('\n\n{"jsonrpc":"2.0","id":0,"result":null}\n\n'));
      await socket.flush();

      await expectLater(pending, completes);
    });

    test('a frame after a malformed one is still dispatched', () async {
      // A parse failure must drop that line and keep the connection usable.
      await connect();
      final pending = client.ping();

      final socket = await server.client;
      socket.add(utf8.encode('not json at all\n{"jsonrpc":"2.0","id":0,"result":null}\n'));
      await socket.flush();

      await expectLater(pending, completes);
    });
  });

  group('the buffer is bounded and linear', () {
    test('a large frame arriving in small segments is fast', () async {
      // 2 MiB in 1400-byte segments. Under the old quadratic buffer this is
      // ~1500 copies of an ever-growing string; the point is that it now costs
      // roughly what appending 2 MiB costs.
      await connect();
      final pending = client.serverVersion();

      final socket = await server.client;
      final filler = 'a' * 1400;
      final watch = Stopwatch()..start();

      socket.add(utf8.encode('{"jsonrpc":"2.0","id":0,"result":["'));
      for (var sent = 0; sent < 2 * 1024 * 1024; sent += filler.length) {
        socket.add(utf8.encode(filler));
      }
      socket.add(utf8.encode('","1.4"]}\n'));
      await socket.flush();

      final version = await pending;
      watch.stop();

      expect(version.first.length, greaterThan(2 * 1024 * 1024 - 4096));
      expect(
        watch.elapsedMilliseconds,
        lessThan(5000),
        reason: 'a quadratic line buffer does not finish this in seconds',
      );
    });

    test('a server that never sends a newline drops the connection', () async {
      // Otherwise this is an unbounded allocation driven by whoever the user
      // configured as their server.
      await connect();
      expect(client.isConnected, isTrue);

      final socket = await server.client;
      final filler = List<int>.filled(64 * 1024, 0x61); // 'a', no newline ever
      for (var sent = 0; sent <= maxElectrumFrameBytes; sent += filler.length) {
        socket.add(filler);
      }
      await socket.flush();

      // The client closes itself rather than growing; give it a moment to act.
      for (var i = 0; i < 100 && client.isConnected; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(client.isConnected, isFalse, reason: 'the flood must end the connection');
    });

    test('a pending call fails rather than hanging when the flood ends it', () async {
      await connect();
      final pending = client.ping();

      final socket = await server.client;
      final filler = List<int>.filled(64 * 1024, 0x61);
      for (var sent = 0; sent <= maxElectrumFrameBytes; sent += filler.length) {
        socket.add(filler);
      }
      await socket.flush();

      await expectLater(pending, throwsA(isA<ElectrumDisconnectException>()));
    });
  });
}
