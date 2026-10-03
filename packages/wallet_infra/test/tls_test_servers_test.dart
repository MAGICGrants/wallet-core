import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';

/// The servers the native TLS checks judge the library by. Those checks need a
/// monero_c build; these make sure that, when one fails, it is the library and
/// not the harness.
void main() {
  final trustTestRoot = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(utf8.encode(TestPki.rootCa));

  /// Sends one request on [socket] and returns the raw response.
  Future<String> exchange(Socket socket, String request) async {
    socket.write(request);
    return utf8.decode(
      await socket.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
      allowMalformed: true,
    );
  }

  test('TlsTestServer records a handshake and the request, and closes after answering', () async {
    final server = await TlsTestServer.start(
      chainPem: TestPki.serverChain,
      keyPem: TestPki.serverKey,
      respond: (r) => (status: 200, body: '{"ok":true}', close: true),
    );
    addTearDown(server.close);

    final socket = await SecureSocket.connect('localhost', server.port, context: trustTestRoot);
    final response = await exchange(
      socket,
      'POST /login HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}',
    );

    expect(response, startsWith('HTTP/1.1 200'));
    expect(response, endsWith('{"ok":true}'));
    expect(server.handshakes, 1);
    expect(server.requests.single, (method: 'POST', target: '/login', body: '{}'));
  });

  test('TlsTestServer serves several requests on a kept-alive connection', () async {
    final server = await TlsTestServer.start(
      chainPem: TestPki.serverChain,
      keyPem: TestPki.serverKey,
      respond: (r) => (status: 200, body: r.target, close: r.target == '/last'),
    );
    addTearDown(server.close);

    final socket = await SecureSocket.connect('127.0.0.1', server.port, context: trustTestRoot);
    final response = await exchange(
      socket,
      'GET /first HTTP/1.1\r\nHost: x\r\n\r\nGET /last HTTP/1.1\r\nHost: x\r\n\r\n',
    );

    expect(server.handshakes, 1);
    expect(server.requests.map((r) => r.target), ['/first', '/last']);
    expect(response, contains('/first'));
    expect(response, endsWith('/last'));
  });

  test('TlsTestServer counts a handshake the client abandons, and records nothing', () async {
    final server = await TlsTestServer.start(
      chainPem: TestPki.wrongHostChain,
      keyPem: TestPki.wrongHostKey,
    );
    addTearDown(server.close);

    await expectLater(
      SecureSocket.connect('localhost', server.port, context: trustTestRoot),
      throwsA(isA<HandshakeException>()),
    );
    // The server learns of the abandoned handshake after the client does.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (server.failedHandshakes == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(server.handshakes, 0);
    expect(server.failedHandshakes, 1);
    expect(server.requests, isEmpty);
  });

  test('PlainHttpTestServer tells a TLS attempt from a plaintext request', () async {
    final server = await PlainHttpTestServer.start();
    addTearDown(server.close);

    await expectLater(
      SecureSocket.connect('127.0.0.1', server.port, context: trustTestRoot),
      throwsA(anyOf(isA<HandshakeException>(), isA<SocketException>())),
    );
    expect(server.tlsAttempts, 1);
    expect(server.requests, isEmpty);

    final socket = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    final response = await exchange(socket, 'GET /get_info HTTP/1.1\r\nHost: x\r\n\r\n');

    expect(response, startsWith('HTTP/1.1 404'));
    expect(server.requests.single.target, '/get_info');
  });

  test(
    'SocksTestProxy carries a SOCKS4a CONNECT by name, as the native library sends it',
    () async {
      final server = await TlsTestServer.start(
        chainPem: TestPki.serverChain,
        keyPem: TestPki.serverKey,
        respond: (r) => (status: 200, body: 'through', close: true),
      );
      final proxy = await SocksTestProxy.start({TestPki.routableHost: server.port});
      addTearDown(() async {
        await proxy.close();
        await server.close();
      });

      final raw = await Socket.connect(InternetAddress.loopbackIPv4, proxy.port);
      // Left active: SecureSocket.secure takes over the socket's live
      // subscription, and cancelling it would close the socket instead.
      final replies = StreamController<List<int>>();
      raw.listen(replies.add);
      // VN=4, CD=1 (connect), port 443, DSTIP 0.0.0.1 (a name follows), no user id.
      raw.add([4, 1, 1, 187, 0, 0, 0, 1, 0, ...ascii.encode(TestPki.routableHost), 0]);
      final reply = await replies.stream.first;
      expect(reply.sublist(0, 2), [0, 0x5a], reason: 'request granted');

      final tls = await SecureSocket.secure(
        raw,
        host: TestPki.routableHost,
        context: trustTestRoot,
      );
      final response = await exchange(tls, 'GET / HTTP/1.1\r\nHost: x\r\n\r\n');

      expect(proxy.requested, [TestPki.routableHost]);
      expect(response, endsWith('through'));
    },
  );

  test('SocksTestProxy refuses a name it has no route for', () async {
    final proxy = await SocksTestProxy.start({});
    addTearDown(proxy.close);

    final raw = await Socket.connect(InternetAddress.loopbackIPv4, proxy.port);
    raw.add([4, 1, 1, 187, 0, 0, 0, 1, 0, ...ascii.encode('elsewhere.test'), 0]);
    final reply = await raw.first;

    expect(reply.sublist(0, 2), [0, 0x5b], reason: 'request rejected');
    expect(proxy.requested, ['elsewhere.test']);
    raw.destroy();
  });
}
