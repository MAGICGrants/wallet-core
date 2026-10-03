import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Setting up a SOCKS5 tunnel is bounded, and fails in words.
///
/// The read after the tunnel was always bounded; the setup was not. A custom
/// proxy port that pointed at something other than a SOCKS5 proxy (an HTTP
/// proxy, Tor's ControlPort) left `makeSocksHttpRequest` pending until the user
/// gave up, or, over plaintext, failed with "Bad state: No element".

/// Short enough to keep the suite quick, long enough that loopback never misses
/// it by accident.
const _deadline = Duration(milliseconds: 300);

/// What "at once" means for a failure that must not wait for any deadline:
/// far inside the 20s default, so a hang-up that waited it out instead shows.
const _prompt = Duration(seconds: 5);

final _trustTestRoot = SecurityContext(withTrustedRoots: false)
  ..setTrustedCertificatesBytes(utf8.encode(TestPki.rootCa));

({InternetAddress host, int port}) _via(int port) =>
    (host: InternetAddress.loopbackIPv4, port: port);

Matcher _socksError(String message) =>
    isA<SocksProxyException>().having((e) => e.message, 'message', message);

/// A loopback listener that is not a working SOCKS5 proxy. [onData] decides
/// what it does with each chunk a client sends; it never answers unless told
/// to.
///
/// With `tls` it first completes the TLS handshake with the test certificate:
/// a server at the far end of the tunnel, rather than the proxy.
class _Listener {
  _Listener._(this.port, this._close);

  final int port;
  final Future<void> Function() _close;
  final Set<Socket> _clients = {};
  final Completer<void> _hungUp = Completer<void>();

  ({InternetAddress host, int port}) get proxyInfo => _via(port);

  /// Completes when a client's connection closes. For a listener that never
  /// hangs up itself, that is the client tearing the socket down rather than
  /// abandoning it.
  Future<void> get hungUp => _hungUp.future;

  static Future<_Listener> start(
    void Function(Socket client, List<int> data) onData, {
    bool tls = false,
  }) async {
    late final _Listener listener;

    void accept(Socket client) {
      listener._clients.add(client);
      void ended() {
        if (!listener._hungUp.isCompleted) listener._hungUp.complete();
      }

      client.listen((data) => onData(client, data), onDone: ended, onError: (Object _) => ended());
    }

    if (tls) {
      final context = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(TestPki.serverChain))
        ..usePrivateKeyBytes(utf8.encode(TestPki.serverKey));
      final socket = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
      listener = _Listener._(socket.port, socket.close);
      socket.listen(accept, onError: (Object _) {});
    } else {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      listener = _Listener._(socket.port, socket.close);
      socket.listen(accept);
    }
    return listener;
  }

  Future<void> close() async {
    for (final client in _clients) {
      client.destroy();
    }
    await _close();
  }
}

/// Holds each connection for [delay] before relaying it to a local port: a
/// server that does answer the TLS handshake, but only after the client has
/// stopped waiting.
class _SlowRelay {
  _SlowRelay._(this._server);

  final ServerSocket _server;
  final Set<Socket> _sockets = {};
  final Completer<void> _clientHungUp = Completer<void>();

  int get port => _server.port;

  /// Completes when the client's end of a relayed connection closes.
  Future<void> get clientHungUp => _clientHungUp.future;

  static Future<_SlowRelay> start({required int target, required Duration delay}) async {
    final relay = _SlowRelay._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    relay._server.listen((client) async {
      relay._sockets.add(client);
      final early = <int>[];
      Socket? upstream;
      client.listen(
        (data) {
          final up = upstream;
          if (up == null) {
            early.addAll(data);
          } else {
            up.add(data);
          }
        },
        onDone: () {
          if (!relay._clientHungUp.isCompleted) relay._clientHungUp.complete();
        },
        onError: (Object _) {},
      );
      await Future<void>.delayed(delay);
      final up = await Socket.connect(InternetAddress.loopbackIPv4, target);
      relay._sockets.add(up);
      up.add(early);
      upstream = up;
      up.listen(client.add, onDone: client.destroy, onError: (Object _) => client.destroy());
    });
    return relay;
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}

/// A loopback listener that resets connections rather than closing them.
///
/// It never reads what it resets on: data from a client that arrives while it
/// is armed is left waiting, and the connection is closed on it. Closing a
/// socket with unread data aborts the connection (RST, "connection reset by
/// peer") instead of ending it in order (FIN), and the client hears of it only
/// after it has written.
///
/// Without an `upstream` port it is armed from the start, a port that resets
/// the connection on the SOCKS greeting. With one it is a plain pipe to that
/// port until [arm]; in front of a [SocksTestProxy], a working proxy.
class _Resetter {
  _Resetter._(this._server, this._upstream) : _armed = _upstream == null;

  final RawServerSocket _server;
  final int? _upstream;
  final Set<RawSocket> _clients = {};
  final Set<Socket> _upstreams = {};
  bool _armed;

  int get port => _server.port;

  /// Resets each connection at the next data its client sends.
  void arm() => _armed = true;

  static Future<_Resetter> start({int? upstream}) async {
    final resetter = _Resetter._(
      await RawServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      upstream,
    );
    resetter._server.listen(resetter._accept);
    return resetter;
  }

  Future<void> _accept(RawSocket client) async {
    _clients.add(client);
    final target = _upstream;
    final upstream = target == null
        ? null
        : await Socket.connect(InternetAddress.loopbackIPv4, target);
    if (upstream != null) _upstreams.add(upstream);

    // What upstream sent that the client's socket has not taken yet.
    final toClient = <int>[];
    void flush() {
      if (toClient.isEmpty) return;
      toClient.removeRange(0, client.write(toClient));
      client.writeEventsEnabled = toClient.isNotEmpty;
    }

    upstream?.listen(
      (data) {
        toClient.addAll(data);
        flush();
      },
      onDone: () => unawaited(client.close()),
      onError: (Object _) => unawaited(client.close()),
    );
    client.listen((event) {
      switch (event) {
        case RawSocketEvent.read when _armed:
          // Closed with the data still unread: a reset.
          unawaited(client.close());
          upstream?.destroy();
        case RawSocketEvent.read:
          final data = client.read();
          if (data != null) upstream?.add(data);
        case RawSocketEvent.write:
          flush();
        case RawSocketEvent.readClosed:
        case RawSocketEvent.closed:
          upstream?.destroy();
      }
    }, onError: (Object _) => upstream?.destroy());
  }

  Future<void> close() async {
    for (final client in _clients) {
      unawaited(client.close());
    }
    for (final upstream in _upstreams) {
      upstream.destroy();
    }
    await _server.close();
  }
}

/// A SOCKS5 proxy that is also the destination: it grants any CONNECT, answers
/// the tunnel's TLS handshake itself when started with `tls`, and counts what
/// comes through the tunnel until the client hangs up. It answers the first
/// bytes with a line of its own, the way a server's notification, or a TLS
/// server's session tickets, reach a client that is still writing.
///
/// For writes larger than the socket buffers. [SocksTestProxy] destroys the
/// destination's side when the client hangs up, dropping whatever it has not
/// passed on yet, so such a write could be cut short there rather than by the
/// client.
class _CountingProxy {
  _CountingProxy._(this._server, this._context);

  final ServerSocket _server;

  /// The test certificate the tunnel's TLS is answered with; null for a
  /// plaintext tunnel.
  final SecurityContext? _context;

  final Set<Socket> _sockets = {};
  final Completer<int> _received = Completer<int>();

  int get port => _server.port;

  /// How many bytes came through the tunnel, once the client has hung up.
  Future<int> get received => _received.future;

  static Future<_CountingProxy> start({required bool tls}) async {
    final proxy = _CountingProxy._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      tls
          ? (SecurityContext(withTrustedRoots: false)
              ..useCertificateChainBytes(utf8.encode(TestPki.serverChain))
              ..usePrivateKeyBytes(utf8.encode(TestPki.serverKey)))
          : null,
    );
    proxy._server.listen(proxy._accept);
    return proxy;
  }

  void _accept(Socket client) {
    _sockets.add(client);
    var count = 0;
    void ended() {
      if (!_received.isCompleted) _received.complete(count);
    }

    void counted(Socket tunnel, List<int> data) {
      if (count == 0 && data.isNotEmpty) {
        tunnel.add(utf8.encode('ok\n'));
        // Should the client reset the connection, `done` fails as well; the
        // count is what reports it.
        unawaited(tunnel.done.then<void>((_) {}, onError: (Object _) {}));
      }
      count += data.length;
    }

    final pending = <int>[];
    var greeted = false;
    var tunnelled = false;
    client.listen(
      (data) {
        if (tunnelled) {
          counted(client, data);
          return;
        }
        pending.addAll(data);
        if (!greeted) {
          // Version 5, one method, no authentication.
          if (pending.length < 3) return;
          pending.removeRange(0, 3);
          greeted = true;
          client.add(const [5, 0]);
        }
        // The CONNECT: version 5, the command, a reserved byte, the address
        // type (a domain name), the name's length, the name, the port.
        if (pending.length < 5 || pending.length < 7 + pending[4]) return;
        pending.removeRange(0, 7 + pending[4]);
        tunnelled = true;
        client.add(const [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);

        final context = _context;
        if (context == null) {
          counted(client, pending);
          return;
        }
        // The client sends its ClientHello only once it has read the reply
        // above, so the TLS layer has the socket before any of it is read.
        unawaited(
          SecureSocket.secureServer(client, context, bufferedData: pending).then((secure) {
            _sockets.add(secure);
            secure.listen(
              (data) => counted(secure, data),
              onDone: ended,
              onError: (Object _) => ended(),
            );
          }, onError: (Object _) => ended()),
        );
      },
      // Once the TLS socket has the connection, the hang-up reaches it instead.
      onDone: () {
        if (_context == null || !tunnelled) ended();
      },
      onError: (Object _) => ended(),
    );
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}

/// A server that takes [delay] to answer each request, with `{"height":1}`.
class _SlowServer {
  _SlowServer._(this.port, this._close);

  final int port;
  final Future<void> Function() _close;
  final Set<Socket> _clients = {};

  static Future<_SlowServer> start({required bool tls, required Duration delay}) async {
    late final _SlowServer server;

    void serve(Socket client) {
      server._clients.add(client);
      final request = <int>[];
      var answered = false;
      client.listen((data) async {
        request.addAll(data);
        if (answered || !latin1.decode(request).contains('\r\n\r\n')) return;
        answered = true;
        await Future<void>.delayed(delay);
        const body = '{"height":1}';
        client.add(
          utf8.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: ${body.length}\r\n'
            '\r\n'
            '$body',
          ),
        );
        await client.flush();
      }, onError: (Object _) {});
    }

    if (tls) {
      final context = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(utf8.encode(TestPki.serverChain))
        ..usePrivateKeyBytes(utf8.encode(TestPki.serverKey));
      final socket = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
      server = _SlowServer._(socket.port, socket.close);
      socket.listen(serve, onError: (Object _) {});
    } else {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server = _SlowServer._(socket.port, socket.close);
      socket.listen(serve);
    }
    return server;
  }

  Future<void> close() async {
    for (final client in _clients) {
      client.destroy();
    }
    await _close();
  }
}

void main() {
  group('a port that is not a SOCKS5 proxy', () {
    for (final scheme in ['https', 'http']) {
      test('$scheme: one that never answers fails at the deadline, and is hung up on', () async {
        final listener = await _Listener.start((_, _) {});
        addTearDown(listener.close);

        final clock = Stopwatch()..start();
        await expectLater(
          makeSocksHttpRequest(
            'GET',
            '$scheme://${TestPki.routableHost}/get_height',
            listener.proxyInfo,
            handshakeTimeout: _deadline,
          ),
          throwsA(
            _socksError(
              'the proxy at 127.0.0.1:${listener.port} did not answer as a SOCKS5 proxy '
              'within 300ms',
            ),
          ),
        );
        expect(clock.elapsed, lessThan(_prompt));

        // Torn down, not abandoned: the listener sees the client hang up.
        await listener.hungUp.timeout(const Duration(seconds: 2));
      });

      test('$scheme: one that hangs up after reading the greeting fails at once', () async {
        // The case that hung for good under SSL, and over plaintext threw
        // "Bad state: No element". The default deadline is left in place, so
        // only seeing the hang-up can make this prompt.
        final listener = await _Listener.start((client, _) => client.destroy());
        addTearDown(listener.close);

        final clock = Stopwatch()..start();
        await expectLater(
          makeSocksHttpRequest(
            'GET',
            '$scheme://${TestPki.routableHost}/get_height',
            listener.proxyInfo,
          ),
          throwsA(
            _socksError(
              'the proxy at 127.0.0.1:${listener.port} did not answer as a SOCKS5 proxy: '
              'it closed the connection',
            ),
          ),
        );
        expect(clock.elapsed, lessThan(_prompt));
      });
    }

    test('one that answers in another protocol is named as not a SOCKS5 proxy', () async {
      // An HTTP proxy that rejects the greeting as a malformed request.
      final listener = await _Listener.start(
        (client, _) => client.add(utf8.encode('HTTP/1.1 400 Bad Request\r\n\r\n')),
      );
      addTearDown(listener.close);

      await expectLater(
        makeSocksHttpRequest(
          'GET',
          'https://${TestPki.routableHost}/get_height',
          listener.proxyInfo,
        ),
        throwsA(
          _socksError('the proxy at 127.0.0.1:${listener.port} did not answer as a SOCKS5 proxy'),
        ),
      );
      await listener.hungUp.timeout(const Duration(seconds: 2));
    });

    test('nothing listening still fails at once, with the socket error', () async {
      final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = unused.port;
      await unused.close();

      await expectLater(
        makeSocksHttpRequest('GET', 'https://${TestPki.routableHost}/get_height', _via(port)),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('a SOCKS5 proxy that refuses or stalls', () {
    test('one that wants a password says so', () async {
      final listener = await _Listener.start((client, _) => client.add(const [0x05, 0xFF]));
      addTearDown(listener.close);

      await expectLater(
        makeSocksHttpRequest(
          'GET',
          'https://${TestPki.routableHost}/get_height',
          listener.proxyInfo,
        ),
        throwsA(
          _socksError(
            'the proxy at 127.0.0.1:${listener.port} requires authentication, '
            'which is not supported',
          ),
        ),
      );
      await listener.hungUp.timeout(const Duration(seconds: 2));
    });

    test('a refused CONNECT names the destination and the reason', () async {
      final proxy = await SocksTestProxy.start({});
      addTearDown(proxy.close);

      await expectLater(
        makeSocksHttpRequest('GET', 'https://elsewhere.test/get_height', _via(proxy.port)),
        throwsA(
          _socksError(
            'the proxy at 127.0.0.1:${proxy.port} could not connect to elsewhere.test:443: '
            'SOCKS5 error 4: Host unreachable',
          ),
        ),
      );
      expect(proxy.requested, ['elsewhere.test']);
    });

    test('one that answers the greeting but not the CONNECT fails at the deadline', () async {
      var greeted = false;
      final listener = await _Listener.start((client, _) {
        if (greeted) return;
        greeted = true;
        client.add(const [0x05, 0x00]);
      });
      addTearDown(listener.close);

      await expectLater(
        makeSocksHttpRequest(
          'GET',
          'https://${TestPki.routableHost}/get_height',
          listener.proxyInfo,
          handshakeTimeout: _deadline,
        ),
        throwsA(
          _socksError(
            'the proxy at 127.0.0.1:${listener.port} did not answer the CONNECT to '
            '${TestPki.routableHost}:443 within 300ms',
          ),
        ),
      );
      await listener.hungUp.timeout(const Duration(seconds: 2));
    });

    test('a TLS handshake nobody answers fails at the deadline', () async {
      final server = await _Listener.start((_, _) {});
      final proxy = await SocksTestProxy.start({TestPki.routableHost: server.port});
      addTearDown(() async {
        await proxy.close();
        await server.close();
      });

      final clock = Stopwatch()..start();
      await expectLater(
        makeSocksHttpRequest(
          'GET',
          'https://${TestPki.routableHost}:${server.port}/get_height',
          _via(proxy.port),
          handshakeTimeout: _deadline,
          securityContext: _trustTestRoot,
        ),
        throwsA(
          isA<TimeoutException>()
              .having((e) => e.duration, 'duration', _deadline)
              .having(
                (e) => e.message,
                'message',
                'TLS handshake with ${TestPki.routableHost}:${server.port} through the proxy at '
                    '127.0.0.1:${proxy.port} did not complete',
              ),
        ),
      );
      expect(clock.elapsed, lessThan(_prompt));

      // The handshake still holds the connection; the far end hanging up
      // settles it, and that must not surface as an unhandled error.
      await proxy.close();
      await server.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    test('a TLS handshake that completes after the deadline is torn down, not kept', () async {
      final server = await TlsTestServer.start(
        chainPem: TestPki.serverChain,
        keyPem: TestPki.serverKey,
      );
      final relay = await _SlowRelay.start(target: server.port, delay: _deadline * 3);
      final proxy = await SocksTestProxy.start({TestPki.routableHost: relay.port});
      addTearDown(() async {
        await proxy.close();
        await relay.close();
        await server.close();
      });

      final clock = Stopwatch()..start();
      await expectLater(
        makeSocksHttpRequest(
          'GET',
          'https://${TestPki.routableHost}:${relay.port}/get_height',
          _via(proxy.port),
          handshakeTimeout: _deadline,
          securityContext: _trustTestRoot,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(clock.elapsed, lessThan(_deadline * 3), reason: 'failed without waiting it out');

      // The handshake finishes once the relay lets it through, and the socket
      // it yields is destroyed rather than left open.
      await relay.clientHungUp.timeout(const Duration(seconds: 5));
      final until = DateTime.now().add(const Duration(seconds: 5));
      while (server.handshakes == 0 && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(server.handshakes, 1, reason: 'the late handshake completed');
      expect(server.requests, isEmpty, reason: 'and nothing was sent over it');
    });
  });

  group('a working proxy is unaffected', () {
    test('https through SocksTestProxy succeeds under the default deadline', () async {
      final server = await TlsTestServer.start(
        chainPem: TestPki.serverChain,
        keyPem: TestPki.serverKey,
        respond: (_) => (status: 200, body: '{"height":1}', close: true),
      );
      final proxy = await SocksTestProxy.start({TestPki.routableHost: server.port});
      addTearDown(() async {
        await proxy.close();
        await server.close();
      });

      final response = await makeSocksHttpRequest(
        'GET',
        'https://${TestPki.routableHost}:${server.port}/get_height',
        _via(proxy.port),
        timeout: const Duration(seconds: 5),
        securityContext: _trustTestRoot,
      );

      expect(response.statusCode, 200);
      expect(response.jsonBody, {'height': 1});
      expect(server.requests.single.target, '/get_height');
      expect(proxy.requested, [TestPki.routableHost]);
    });

    test('http through SocksTestProxy succeeds under the default deadline', () async {
      final server = await PlainHttpTestServer.start();
      final proxy = await SocksTestProxy.start({TestPki.routableHost: server.port});
      addTearDown(() async {
        await proxy.close();
        await server.close();
      });

      final response = await makeSocksHttpRequest(
        'GET',
        'http://${TestPki.routableHost}:${server.port}/get_height',
        _via(proxy.port),
        timeout: const Duration(seconds: 5),
      );

      expect(response.statusCode, 404);
      expect(server.requests.single.target, '/get_height');
    });

    for (final tls in [true, false]) {
      final scheme = tls ? 'https' : 'http';
      test('$scheme: the deadline ends with the handshake; a slower reply still arrives', () async {
        final server = await _SlowServer.start(tls: tls, delay: _deadline * 3);
        final proxy = await SocksTestProxy.start({TestPki.routableHost: server.port});
        addTearDown(() async {
          await proxy.close();
          await server.close();
        });

        final response = await makeSocksHttpRequest(
          'GET',
          '$scheme://${TestPki.routableHost}:${server.port}/get_height',
          _via(proxy.port),
          timeout: const Duration(seconds: 5),
          handshakeTimeout: _deadline,
          securityContext: tls ? _trustTestRoot : null,
        );

        expect(response.statusCode, 200);
        expect(response.jsonBody, {'height': 1});
      });
    }
  });

  group('SOCKSSocket used directly', () {
    test('a failed step destroys the socket, and a close after it returns', () async {
      // How the Electrum client and the explorer client use it: create, then
      // connect and connectTo, and the explorer closes in a `finally`.
      final listener = await _Listener.start((_, _) {});
      addTearDown(listener.close);

      final socket = await SOCKSSocket.create(
        proxyHost: InternetAddress.loopbackIPv4.address,
        proxyPort: listener.port,
        sslEnabled: true,
        handshakeTimeout: _deadline,
      );
      await expectLater(socket.connect(), throwsA(isA<SocksProxyException>()));

      await listener.hungUp.timeout(const Duration(seconds: 2));
      await socket.close().timeout(const Duration(seconds: 2));
    });

    for (final tls in [true, false]) {
      final scheme = tls ? 'TLS' : 'plaintext';
      test('$scheme: close delivers what was written, hangs up, and returns', () async {
        // Under TLS this never returned. It flushed the plaintext socket too,
        // whose sink dart:io closes when the TLS layer takes the connection,
        // and a flush on a closed sink never completes. The server getting the
        // bytes and then the hang-up shows that the socket carrying them (under
        // TLS, the TLS one) was the one flushed and closed.
        final received = <int>[];
        final server = await _Listener.start((_, data) => received.addAll(data), tls: tls);
        final proxy = await SocksTestProxy.start({TestPki.routableHost: server.port});
        addTearDown(() async {
          await proxy.close();
          await server.close();
        });

        final socket = await SOCKSSocket.create(
          proxyHost: InternetAddress.loopbackIPv4.address,
          proxyPort: proxy.port,
          sslEnabled: tls,
          securityContext: tls ? _trustTestRoot : null,
        );
        addTearDown(socket.destroy);
        await socket.connect();
        await socket.connectTo(TestPki.routableHost, server.port);
        socket.write('ping\n');

        await socket.close().timeout(const Duration(seconds: 2));
        await server.hungUp.timeout(const Duration(seconds: 2));
        expect(utf8.decode(received), 'ping\n');
      });

      test('$scheme: close delivers a write larger than the socket buffers', () async {
        // Most of this is still buffered in dart:io when close is called, and
        // has to go out before the hang-up. Over plaintext, a write as small
        // as the one above is in the kernel's hands as soon as it is made, and
        // would arrive even if close dropped what was buffered. This one is
        // several times what loopback's socket buffers hold, so the proxy
        // reads, and answers, while it is still going out.
        //
        // That answer has to be read: once the socket's read side is shut,
        // anything from the peer gets the connection reset, and the end of the
        // write is lost.
        final proxy = await _CountingProxy.start(tls: tls);
        addTearDown(proxy.close);

        final socket = await SOCKSSocket.create(
          proxyHost: InternetAddress.loopbackIPv4.address,
          proxyPort: proxy.port,
          sslEnabled: tls,
          securityContext: tls ? _trustTestRoot : null,
        );
        addTearDown(socket.destroy);
        await socket.connect();
        await socket.connectTo(TestPki.routableHost, 443);
        final heard = <int>[];
        socket.inputStream.listen(heard.addAll);
        const size = 32 << 20;
        socket.write('x' * size);

        await socket.close().timeout(const Duration(seconds: 20));
        expect(await proxy.received.timeout(const Duration(seconds: 20)), size);
        expect(utf8.decode(heard), 'ok\n', reason: 'read while the write went out');
      });
    }

    test('TLS: a close before connectTo tears the socket down', () async {
      // Only the SOCKS handshake has been written, and there is no TLS socket
      // yet to flush or close; reaching for one threw LateInitializationError.
      final listener = await _Listener.start((client, _) => client.add(const [0x05, 0x00]));
      addTearDown(listener.close);

      final socket = await SOCKSSocket.create(
        proxyHost: InternetAddress.loopbackIPv4.address,
        proxyPort: listener.port,
        sslEnabled: true,
      );
      await socket.connect();

      await socket.close().timeout(const Duration(seconds: 2));
      await listener.hungUp.timeout(const Duration(seconds: 2));
    });
  });

  group('a connection reset after the client has written', () {
    // dart:io reports such a reset twice: on the socket's stream, and through
    // `Socket.done` as the outcome of the writes. The stream's copy is logged
    // and handed to the reader. Left unobserved, the other is an uncaught error
    // in the zone that opened the socket, which fails whichever test is running
    // when it lands.
    late MemoryLogSink logs;

    setUp(() {
      logs = MemoryLogSink();
      WalletLog.sink = logs;
    });
    tearDown(WalletLog.resetForTesting);

    List<String> socketErrorsLogged() => [
      for (final record in logs.records)
        if (record.level == LogLevel.error && record.line.contains('SocketException')) record.line,
    ];

    /// `done` completes a few microtasks behind the stream's error. Waiting
    /// this long lets an unobserved copy land while the test that caused it is
    /// still running, rather than "after it had already completed".
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 100));

    test('on the greeting, fails the step and is logged once', () async {
      final resetter = await _Resetter.start();
      addTearDown(resetter.close);

      final socket = await SOCKSSocket.create(
        proxyHost: InternetAddress.loopbackIPv4.address,
        proxyPort: resetter.port,
      );
      await expectLater(socket.connect(), throwsA(isA<SocketException>()));

      await settle();
      expect(socketErrorsLogged(), [contains('SOCKSSocket error: SocketException')]);
    });

    test('through the TLS tunnel, fails the read and is logged once', () async {
      final server = await TlsTestServer.start(
        chainPem: TestPki.serverChain,
        keyPem: TestPki.serverKey,
      );
      final proxy = await SocksTestProxy.start({TestPki.routableHost: server.port});
      final resetter = await _Resetter.start(upstream: proxy.port);
      addTearDown(() async {
        await resetter.close();
        await proxy.close();
        await server.close();
      });

      final socket = await SOCKSSocket.create(
        proxyHost: InternetAddress.loopbackIPv4.address,
        proxyPort: resetter.port,
        sslEnabled: true,
        securityContext: _trustTestRoot,
      );
      addTearDown(socket.destroy);
      await socket.connect();
      await socket.connectTo(TestPki.routableHost, server.port);

      resetter.arm();
      await expectLater(
        socket.sendHttpRequest(
          getRawHttpRequestString(
            'GET',
            'https://${TestPki.routableHost}:${server.port}/get_height',
          ),
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<SocketException>()),
      );

      await settle();
      expect(socketErrorsLogged(), [contains('SOCKSSocket (secure) error: SocketException')]);
    });

    for (final tls in [true, false]) {
      final scheme = tls ? 'TLS' : 'plaintext';
      test('$scheme: close afterwards returns, failing with the reset', () async {
        // How the Electrum client meets a reset: the read fails and its error
        // handler closes the socket. That close flushed first and never
        // returned, so the client went on counting itself connected, holding
        // the dead socket; the next connect's close threw StateError instead.
        final server = await _Listener.start((_, _) {}, tls: tls);
        final proxy = await SocksTestProxy.start({TestPki.routableHost: server.port});
        final resetter = await _Resetter.start(upstream: proxy.port);
        addTearDown(() async {
          await resetter.close();
          await proxy.close();
          await server.close();
        });

        final socket = await SOCKSSocket.create(
          proxyHost: InternetAddress.loopbackIPv4.address,
          proxyPort: resetter.port,
          sslEnabled: tls,
          securityContext: tls ? _trustTestRoot : null,
        );
        addTearDown(socket.destroy);
        await socket.connect();
        await socket.connectTo(TestPki.routableHost, server.port);

        resetter.arm();
        await expectLater(
          socket.sendHttpRequest(
            getRawHttpRequestString(
              'GET',
              '${tls ? 'https' : 'http'}://${TestPki.routableHost}:${server.port}/get_height',
            ),
            timeout: const Duration(seconds: 5),
          ),
          throwsA(isA<SocketException>()),
        );
        // Close only once dart:io has failed the writes as well, as it has by
        // the time the Electrum client's error handler gets there. That is
        // when a flush never completes.
        await settle();

        await expectLater(
          socket.close().timeout(const Duration(seconds: 2)),
          throwsA(isA<SocketException>()),
        );
        // And again, as the next connect does: the same error, not "StreamSink
        // is bound to a stream".
        await expectLater(
          socket.close().timeout(const Duration(seconds: 2)),
          throwsA(isA<SocketException>()),
        );
      });
    }
  });
}
