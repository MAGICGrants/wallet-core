import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// An HTTP request a test server received.
typedef ReceivedRequest = ({String method, String target, String body});

/// A test server's answer to one request. With [close] the server ends the
/// connection after answering, so the client's next request needs a new TCP
/// connection and, over TLS, a new handshake.
typedef TestResponse = ({int status, String body, bool close});

TestResponse _notFound(ReceivedRequest _) => (status: 404, body: '', close: true);

/// A loopback HTTPS server with a fixed certificate chain.
///
/// It records how far each client got: a completed TLS handshake, then HTTP
/// requests. A client that rejects the certificate aborts the handshake and
/// appears in neither [handshakes] nor [requests], so the server's record is
/// the verdict whatever the client says about the failure.
///
/// Bound to 127.0.0.1 only; a test reaches it as `127.0.0.1`, or by name
/// through [SocksTestProxy].
class TlsTestServer {
  TlsTestServer._(this._socket, this._respond);

  final SecureServerSocket _socket;
  final TestResponse Function(ReceivedRequest request) _respond;
  final Set<Socket> _clients = {};

  /// TLS handshakes that completed.
  int handshakes = 0;

  /// TLS handshakes the server saw fail (the client hung up mid-handshake).
  int failedHandshakes = 0;

  /// Every request received over a completed handshake, in order.
  final List<ReceivedRequest> requests = [];

  int get port => _socket.port;

  /// Starts a server presenting [chainPem] (leaf first) with [keyPem].
  /// [respond] answers each request; by default a 404 that closes the
  /// connection.
  static Future<TlsTestServer> start({
    required String chainPem,
    required String keyPem,
    TestResponse Function(ReceivedRequest request)? respond,
  }) async {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(chainPem))
      ..usePrivateKeyBytes(utf8.encode(keyPem));
    final socket = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, context);
    final server = TlsTestServer._(socket, respond ?? _notFound);
    socket.listen(
      server._accept,
      // A handshake the client aborted arrives here, not as a socket.
      onError: (Object _) => server.failedHandshakes++,
    );
    return server;
  }

  void _accept(SecureSocket client) {
    handshakes++;
    _clients.add(client);
    _serveHttp(client, _respond, requests.add, onClose: () => _clients.remove(client));
  }

  Future<void> close() async {
    for (final client in _clients.toList()) {
      client.destroy();
    }
    await _socket.close();
  }
}

/// A loopback server that speaks plain HTTP, standing in for a server that
/// has no TLS at all.
///
/// A TLS ClientHello is counted in [tlsAttempts] and the connection dropped. A
/// plaintext HTTP request is recorded in [requests] and answered. A client told
/// to use TLS must only ever produce the first kind: anything in [requests]
/// means it fell back to plaintext.
class PlainHttpTestServer {
  PlainHttpTestServer._(this._socket);

  final ServerSocket _socket;
  final Set<Socket> _clients = {};

  int tlsAttempts = 0;
  final List<ReceivedRequest> requests = [];

  int get port => _socket.port;

  static Future<PlainHttpTestServer> start() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final server = PlainHttpTestServer._(socket);
    socket.listen(server._accept);
    return server;
  }

  void _accept(Socket client) {
    _clients.add(client);
    var first = true;
    _serveHttp(
      client,
      _notFound,
      requests.add,
      onClose: () => _clients.remove(client),
      // 0x16 is the TLS handshake record type: the first byte of a ClientHello.
      sniff: (data) {
        if (!first) return true;
        first = false;
        if (data.isNotEmpty && data.first == 0x16) {
          tlsAttempts++;
          client.destroy();
          return false;
        }
        return true;
      },
    );
  }

  Future<void> close() async {
    for (final client in _clients.toList()) {
      client.destroy();
    }
    await _socket.close();
  }
}

/// A minimal SOCKS proxy on loopback, speaking SOCKS4a (the native library's
/// client) and SOCKS5 without authentication (Dart's client), CONNECT only.
///
/// It carries a CONNECT for a hostname to whichever local port [routes] maps
/// that name to, the way Tor resolves a name inside its circuit. That lets a
/// test send the wallet to a routable-looking name, which the wallet insists on
/// reaching over TLS, without touching DNS or the hosts file. [requested]
/// records every destination asked for.
class SocksTestProxy {
  SocksTestProxy._(this._socket, this.routes);

  final ServerSocket _socket;
  final Set<Socket> _sockets = {};

  /// Hostname (or dotted IPv4) to local port.
  final Map<String, int> routes;
  final List<String> requested = [];

  int get port => _socket.port;

  /// The proxy address in the `host:port` form the wallet takes.
  String get address => '127.0.0.1:$port';

  static Future<SocksTestProxy> start(Map<String, int> routes) async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = SocksTestProxy._(socket, routes);
    socket.listen(proxy._accept);
    return proxy;
  }

  void _accept(Socket client) {
    _sockets.add(client);
    final pending = <int>[];
    Socket? upstream;
    var greeted = false; // SOCKS5 method selection done
    var routing = false; // destination parsed; connecting or connected

    void refuse(List<int> reply) {
      client.add(reply);
      client.flush().whenComplete(client.destroy);
    }

    Future<void> route(_SocksConnect request) async {
      routing = true;
      requested.add(request.host);
      final ok = request.version == 5
          ? const [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]
          : const [0, 0x5a, 0, 0, 0, 0, 0, 0];
      final failed = request.version == 5
          ? const [5, 4, 0, 1, 0, 0, 0, 0, 0, 0]
          : const [0, 0x5b, 0, 0, 0, 0, 0, 0];
      final target = routes[request.host];
      if (!request.connect || target == null) return refuse(failed);
      try {
        final connected = await Socket.connect(InternetAddress.loopbackIPv4, target);
        _sockets.add(connected);
        upstream = connected;
        client.add(ok);
        if (pending.length > request.length) connected.add(pending.sublist(request.length));
        connected.listen(
          client.add,
          onDone: client.destroy,
          onError: (Object _) => client.destroy(),
        );
      } catch (_) {
        refuse(failed);
      }
    }

    client.listen(
      (data) {
        final up = upstream;
        if (up != null) {
          up.add(data);
          return;
        }
        pending.addAll(data);
        if (routing || pending.isEmpty) return; // forwarded once connected

        if (pending[0] == 4) {
          final request = _parseSocks4a(pending);
          if (request != null) unawaited(route(request));
          return;
        }
        if (pending[0] != 5) return refuse(const [0, 0x5b, 0, 0, 0, 0, 0, 0]);

        if (!greeted) {
          if (pending.length < 2 || pending.length < 2 + pending[1]) return;
          final offersNoAuth = pending.sublist(2, 2 + pending[1]).contains(0);
          pending.removeRange(0, 2 + pending[1]);
          if (!offersNoAuth) return refuse(const [5, 0xff]);
          greeted = true;
          client.add(const [5, 0]);
          if (pending.isEmpty) return;
        }
        final request = _parseSocks5(pending);
        if (request != null) unawaited(route(request));
      },
      onDone: () => upstream?.destroy(),
      onError: (Object _) => upstream?.destroy(),
    );
  }

  Future<void> close() async {
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _socket.close();
  }
}

/// A parsed CONNECT request; [length] is how many bytes of the stream it took.
typedef _SocksConnect = ({int version, bool connect, String host, int length});

/// Parses `VN CD DSTPORT DSTIP USERID\0 [DOMAIN\0]`, or returns null while the
/// request is incomplete.
_SocksConnect? _parseSocks4a(List<int> b) {
  if (b.length < 9) return null;
  final userEnd = b.indexOf(0, 8);
  if (userEnd < 0) return null;
  // DSTIP 0.0.0.x with x != 0 marks a v4a request whose hostname follows.
  final isDomain = b[4] == 0 && b[5] == 0 && b[6] == 0 && b[7] != 0;
  if (!isDomain) {
    return (
      version: 4,
      connect: b[1] == 1,
      host: '${b[4]}.${b[5]}.${b[6]}.${b[7]}',
      length: userEnd + 1,
    );
  }
  final hostEnd = b.indexOf(0, userEnd + 1);
  if (hostEnd < 0) return null;
  return (
    version: 4,
    connect: b[1] == 1,
    host: latin1.decode(b.sublist(userEnd + 1, hostEnd)),
    length: hostEnd + 1,
  );
}

/// Parses `VER CMD RSV ATYP DST.ADDR DST.PORT`, or returns null while the
/// request is incomplete.
_SocksConnect? _parseSocks5(List<int> b) {
  if (b.length < 5) return null;
  final String host;
  final int addressEnd;
  switch (b[3]) {
    case 1: // IPv4
      addressEnd = 4 + 4;
      if (b.length < addressEnd + 2) return null;
      host = b.sublist(4, 8).join('.');
    case 3: // domain name, length-prefixed
      addressEnd = 5 + b[4];
      if (b.length < addressEnd + 2) return null;
      host = latin1.decode(b.sublist(5, addressEnd));
    case 4: // IPv6
      addressEnd = 4 + 16;
      if (b.length < addressEnd + 2) return null;
      host = InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(4, 20))).address;
    default:
      return (version: 5, connect: false, host: '', length: b.length);
  }
  return (version: 5, connect: b[1] == 1, host: host, length: addressEnd + 2);
}

/// Reads HTTP/1.1 requests from [socket] (Content-Length bodies only, which is
/// all the wallet's clients send), hands each to [record], and writes
/// [respond]'s answer. [sniff] sees each chunk first and can stop the read.
void _serveHttp(
  Socket socket,
  TestResponse Function(ReceivedRequest request) respond,
  void Function(ReceivedRequest request) record, {
  required void Function() onClose,
  bool Function(Uint8List data)? sniff,
}) {
  final buffer = <int>[];
  var closing = false;
  late final StreamSubscription<Uint8List> subscription;

  Future<void> finish() async {
    if (closing) return;
    closing = true;
    await subscription.cancel();
    try {
      await socket.flush();
    } catch (_) {}
    socket.destroy();
    onClose();
  }

  subscription = socket.listen(
    (data) {
      if (closing) return;
      if (sniff != null && !sniff(data)) {
        closing = true;
        onClose();
        return;
      }
      buffer.addAll(data);
      for (var request = _takeRequest(buffer); request != null; request = _takeRequest(buffer)) {
        record(request);
        final response = respond(request);
        final body = utf8.encode(response.body);
        socket.add(
          utf8.encode(
            'HTTP/1.1 ${response.status} ${response.status == 200 ? 'OK' : 'Test'}\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: ${body.length}\r\n'
            'Connection: ${response.close ? 'close' : 'keep-alive'}\r\n'
            '\r\n',
          ),
        );
        socket.add(body);
        if (response.close) {
          unawaited(finish());
          return;
        }
      }
    },
    onDone: () => unawaited(finish()),
    onError: (Object _) => unawaited(finish()),
    cancelOnError: true,
  );
}

/// Removes and returns the first complete request in [buffer], or null.
ReceivedRequest? _takeRequest(List<int> buffer) {
  const separator = [13, 10, 13, 10];
  var headerEnd = -1;
  for (var i = 0; i + 3 < buffer.length; i++) {
    if (buffer[i] == separator[0] &&
        buffer[i + 1] == separator[1] &&
        buffer[i + 2] == separator[2] &&
        buffer[i + 3] == separator[3]) {
      headerEnd = i;
      break;
    }
  }
  if (headerEnd < 0) return null;

  final lines = latin1.decode(buffer.sublist(0, headerEnd)).split('\r\n');
  var contentLength = 0;
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon > 0 && line.substring(0, colon).trim().toLowerCase() == 'content-length') {
      contentLength = int.tryParse(line.substring(colon + 1).trim()) ?? 0;
    }
  }
  final end = headerEnd + 4 + contentLength;
  if (buffer.length < end) return null;

  final requestLine = lines.first.split(' ');
  final body = utf8.decode(buffer.sublist(headerEnd + 4, end), allowMalformed: true);
  buffer.removeRange(0, end);
  return (
    method: requestLine.isNotEmpty ? requestLine[0] : '',
    target: requestLine.length > 1 ? requestLine[1] : '',
    body: body,
  );
}
