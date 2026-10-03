import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging.dart';
import 'bounded_reader.dart';

/// How long each step of setting up a SOCKS5 tunnel may take: the TCP connect
/// to the proxy, the proxy's reply to the greeting, its reply to the CONNECT,
/// and the TLS handshake through the tunnel.
///
/// Twenty seconds, the same as callers give the response read. The proxy is
/// local and answers the greeting at once; the step this has to be generous
/// for is the CONNECT, which Tor answers only once a circuit has reached the
/// destination (for an onion service, after the rendezvous). Bitcoin Core
/// allows the same 20s for each SOCKS5 reply, for the same reason.
const Duration kSocksHandshakeTimeout = Duration(seconds: 20);

/// The proxy did not complete its side of the SOCKS5 handshake: it is not a
/// SOCKS5 proxy, hung up, refused, or did not answer in time.
///
/// The message names the proxy and, for the CONNECT, the destination. Both are
/// the user's own configuration, and the proxy port is usually the setting to
/// fix: an HTTP proxy's port or Tor's ControlPort entered where a SOCKS port
/// belongs.
class SocksProxyException implements Exception {
  const SocksProxyException(this.message);

  final String message;

  @override
  String toString() => 'SocksProxyException: $message';
}

/// A Dart socket that speaks SOCKS5, with optional SSL on top.
///
/// ```dart
/// final socket = await SOCKSSocket.create(
///   proxyHost: InternetAddress.loopbackIPv4.address,
///   proxyPort: tor.port,
///   // sslEnabled: true,
/// );
/// await socket.connect();
/// await socket.connectTo('example.com', 50001);
/// await socket.close();
/// ```
///
/// Every step of that setup is bounded by [handshakeTimeout], and a step that
/// fails destroys the socket; see [connect] and [connectTo].
///
/// See RFC 1928 for the protocol: https://www.ietf.org/rfc/rfc1928.txt
class SOCKSSocket {
  /// Host of the SOCKS5 proxy.
  final String proxyHost;

  /// Port of the SOCKS5 proxy.
  final int proxyPort;

  late final Socket _socksSocket;
  late final Socket _secureSocksSocket;

  /// Whichever socket is carrying data: SSL if enabled, plaintext otherwise.
  Socket get socket => sslEnabled ? _secureSocksSocket : _socksSocket;

  late final StreamController<List<int>> _responseController;
  late final StreamController<List<int>> _secureResponseController;

  /// Broadcasts data from whichever socket is carrying it.
  StreamController<List<int>> get responseController =>
      sslEnabled ? _secureResponseController : _responseController;

  StreamSubscription<List<int>>? _subscription;

  /// Subscription on whichever socket is carrying data.
  StreamSubscription<List<int>>? get subscription => _subscription;

  /// Whether the tunnel is wrapped in SSL.
  final bool sslEnabled;

  /// Trust store for the SSL layer; Dart's default (the OS roots) when null.
  final SecurityContext? securityContext;

  /// Deadline for each step of the handshake; see [kSocksHandshakeTimeout].
  final Duration handshakeTimeout;

  /// Set by [destroy], after which [close] has nothing left to do.
  bool _destroyed = false;

  /// Set once [connectTo] has wrapped the tunnel in TLS, from when
  /// [_secureSocksSocket] carries the data.
  bool _secured = false;

  /// The error a socket's stream last delivered to its `onError`, which logged
  /// it. A socket's `done` can complete with that same error; see
  /// [_observeDone].
  Object? _streamError;

  SOCKSSocket._(
    this.proxyHost,
    this.proxyPort,
    this.sslEnabled, [
    this.securityContext,
    this.handshakeTimeout = kSocksHandshakeTimeout,
  ]) {
    _responseController = StreamController.broadcast(onListen: null, onCancel: null);
    _secureResponseController = StreamController.broadcast(onListen: null, onCancel: null);
  }

  /// Provides a stream of data as `List<int>`.
  Stream<List<int>> get inputStream =>
      sslEnabled ? _secureResponseController.stream : _responseController.stream;

  /// Provides a StreamSink compatible with `List<int>` for sending data.
  StreamSink<List<int>> get outputStream {
    // Create a simple StreamSink wrapper for _socksSocket and
    // _secureSocksSocket that accepts List<int> and forwards it to write method.
    final sink = StreamController<List<int>>();
    sink.stream.listen((data) {
      if (sslEnabled) {
        _secureSocksSocket.add(data);
      } else {
        _socksSocket.add(data);
      }
    });
    return sink.sink;
  }

  /// Creates and initializes a socket to the SOCKS5 proxy at [proxyHost]:[proxyPort].
  ///
  /// [handshakeTimeout] bounds the connect to the proxy here, and each step of
  /// [connect] and [connectTo].
  static Future<SOCKSSocket> create({
    required String proxyHost,
    required int proxyPort,
    bool sslEnabled = false,
    SecurityContext? securityContext,
    Duration handshakeTimeout = kSocksHandshakeTimeout,
  }) async {
    final instance = SOCKSSocket._(
      proxyHost,
      proxyPort,
      sslEnabled,
      securityContext,
      handshakeTimeout,
    );

    await instance._init();

    return instance;
  }

  SOCKSSocket({
    required this.proxyHost,
    required this.proxyPort,
    required this.sslEnabled,
    this.securityContext,
    this.handshakeTimeout = kSocksHandshakeTimeout,
  }) {
    _responseController = StreamController.broadcast();
    _secureResponseController = StreamController.broadcast();
    _init();
  }

  /// Opens the proxy connection and starts forwarding its data.
  Future<void> _init() async {
    _socksSocket = await Socket.connect(proxyHost, proxyPort, timeout: handshakeTimeout);
    _observeDone(_socksSocket, 'SOCKSSocket');

    _subscription = _socksSocket.listen(
      (data) {
        if (!_responseController.isClosed) {
          _responseController.add(data);
        }
      },
      onError: (Object e, StackTrace stackTrace) {
        _streamError = e;
        log(LogLevel.error, 'SOCKSSocket error: $e');
        // Only forward error if controller is open and has listeners
        if (!_responseController.isClosed && _responseController.hasListener) {
          _responseController.addError(e, stackTrace);
        }
      },
      onDone: () {
        log(LogLevel.info, 'SOCKSSocket: connection closed');
        // EOF has to reach the reader. On a plaintext connection this
        // controller *is* [inputStream], and two of the three framing rules in
        // [readHttpResponse] end at EOF; `connection: close` and a body with
        // no length at all. Leaving it open meant those never completed: the
        // socket was finished and the `await for` sat there until the caller's
        // timeout. (Requests here always send `Connection: close`, so that was
        // every plaintext request, not an edge case.) It also left
        // [ElectrumClient] unable to see a dropped Tor connection, since its
        // `onDone` hangs off this stream.
        //
        // Under SSL as well. There this controller carries only the SOCKS
        // handshake, and a peer that hangs up partway through it (something
        // that is not a SOCKS5 proxy, reading the greeting and closing) has to
        // fail the step waiting for its reply; closing only for plaintext left
        // that step pending forever. Once TLS has the socket the caller reads
        // `_secureResponseController` instead, so closing this one then
        // changes nothing.
        if (!_responseController.isClosed) {
          _responseController.close();
        }
      },
    );
  }

  /// Handles the error [socket]'s `done` completes with, so that a failed
  /// connection is not also an uncaught error in the zone that opened it.
  ///
  /// Once anything has been written to a socket, dart:io reports a failure of
  /// the connection (the peer resetting it, say) twice: on the socket's stream,
  /// whose `onError` logs it and passes it to the reader, and through `done`,
  /// as the outcome of the writes, which nothing else listens to before
  /// [close]. Unobserved, that second report reached the zone as an uncaught
  /// error: in a test, a failure, or "failed after it had already completed"
  /// once the test was over.
  ///
  /// Both reports carry the same error object, which is logged once. dart:io
  /// skips the stream when it has already ended, as when the peer resets a
  /// write sent after its EOF; then `done` alone has the error, and it is
  /// logged here, under [label].
  void _observeDone(Socket socket, String label) {
    unawaited(
      socket.done.then<void>(
        (_) {},
        onError: (Object e) {
          if (!identical(e, _streamError)) log(LogLevel.error, '$label error: $e');
        },
      ),
    );
  }

  /// Performs the SOCKS5 greeting and method selection.
  ///
  /// Fails with [SocksProxyException] if the reply is not a SOCKS5 one or does
  /// not come within [handshakeTimeout]; the socket is destroyed either way.
  Future<void> connect() => _handshakeStep(_greet);

  Future<void> _greet() async {
    // Greeting and method selection: version 5, one method, no authentication.
    _socksSocket.add([0x05, 0x01, 0x00]);

    final response = await _reply('did not answer as a SOCKS5 proxy');

    // Whatever else is on the port (an HTTP proxy, Tor's ControlPort) does not
    // open its reply with the SOCKS version, if it replies at all.
    if (response.length < 2 || response[0] != 0x05) {
      throw SocksProxyException('$_proxy did not answer as a SOCKS5 proxy');
    }
    if (response[1] != 0x00) {
      throw SocksProxyException('$_proxy requires authentication, which is not supported');
    }

    return;
  }

  /// SOCKS5 reply codes for better error messages.
  static const Map<int, String> _socks5ReplyCodes = {
    0x00: 'Succeeded',
    0x01: 'General SOCKS server failure',
    0x02: 'Connection not allowed by ruleset',
    0x03: 'Network unreachable',
    0x04: 'Host unreachable',
    0x05: 'Connection refused',
    0x06: 'TTL expired',
    0x07: 'Command not supported',
    0x08: 'Address type not supported',
  };

  /// Opens a tunnel to [domain]:[port] through the proxy, upgrading to SSL when
  /// [sslEnabled].
  ///
  /// The proxy's reply and the TLS handshake each get [handshakeTimeout]. A
  /// failure in either destroys the socket.
  Future<void> connectTo(String domain, int port) =>
      _handshakeStep(() => _openTunnel(domain, port));

  Future<void> _openTunnel(String domain, int port) async {
    // Connect command.
    final request = [
      0x05, // SOCKS version.
      0x01, // Connect command.
      0x00, // Reserved.
      0x03, // Domain name.
      domain.length,
      ...domain.codeUnits,
      (port >> 8) & 0xFF,
      port & 0xFF,
    ];

    _socksSocket.add(request);

    final response = await _reply('did not answer the CONNECT to $domain:$port');

    if (response.length < 2) {
      throw SocksProxyException('$_proxy sent a malformed reply to the CONNECT to $domain:$port');
    }
    if (response[1] != 0x00) {
      final replyCode = response[1];
      final replyMessage = _socks5ReplyCodes[replyCode] ?? 'Unknown error';
      throw SocksProxyException(
        '$_proxy could not connect to $domain:$port: SOCKS5 error $replyCode: $replyMessage',
      );
    }

    // Upgrade to SSL if needed.
    if (sslEnabled) {
      // Do NOT pause `_subscription` here. `SecureSocket.secure(Socket)` detaches
      // the socket's *active* subscription internally to drive the TLS handshake;
      // a paused subscription still owns the socket, so the handshake reads
      // nothing and every HTTPS-over-Tor request hangs to the caller's timeout.
      // Skylight shipped this without the pause and it works; leaving the
      // subscription active is correct.
      _secureSocksSocket = await _secure(domain, port);
      _secured = true;
      _observeDone(_secureSocksSocket, 'SOCKSSocket (secure)');

      _subscription = _secureSocksSocket.listen(
        (data) {
          if (!_secureResponseController.isClosed) {
            _secureResponseController.add(data);
          }
        },
        onError: (Object e, StackTrace stackTrace) {
          _streamError = e;
          log(LogLevel.error, 'SOCKSSocket (secure) error: $e');
          // Only forward error if controller is open and has listeners
          if (!_secureResponseController.isClosed && _secureResponseController.hasListener) {
            _secureResponseController.addError(e, stackTrace);
          }
        },
        onDone: () {
          if (!_secureResponseController.isClosed) {
            _secureResponseController.close();
          }
        },
      );
    }

    return;
  }

  /// The TLS handshake through the tunnel, given [handshakeTimeout].
  ///
  /// The SOCKS steps tear the socket down at their deadline; this one cannot.
  /// `SecureSocket.secure` detaches the raw socket from [_socksSocket], after
  /// which destroying that wrapper does nothing, and the pending handshake holds
  /// the only handle to it. So the deadline fails the call, and the connection
  /// is closed when the handshake settles: destroyed here if it completes after
  /// all, closed by the TLS layer if it fails. A peer that never answers keeps
  /// it open until the peer or the proxy hangs up.
  Future<SecureSocket> _secure(String domain, int port) async {
    final handshake = SecureSocket.secure(
      _socksSocket,
      host: domain,
      context: securityContext,
      // onBadCertificate: (_) => true, // Uncomment this to bypass certificate validation (NOT recommended for production).
    );
    try {
      return await handshake.timeout(handshakeTimeout);
    } on TimeoutException {
      unawaited(handshake.then((socket) => socket.destroy(), onError: (Object _) {}));
      throw TimeoutException(
        'TLS handshake with $domain:$port through $_proxy did not complete',
        handshakeTimeout,
      );
    }
  }

  /// Runs one step of the handshake, destroying the socket if it fails.
  ///
  /// A socket whose handshake failed is of no further use, and not every caller
  /// would close it: the Electrum client keeps hold of its socket only once both
  /// steps have succeeded.
  Future<void> _handshakeStep(Future<void> Function() step) async {
    try {
      await step();
    } catch (_) {
      destroy();
      rethrow;
    }
  }

  /// The proxy's reply to the request just written, waited for at most
  /// [handshakeTimeout].
  ///
  /// [unanswered] completes "the proxy at host:port ..." in the error raised
  /// when no reply comes, because the deadline passed or the proxy hung up.
  /// `stream.first` had neither ending: a port where nothing answers (an HTTP
  /// proxy waiting for a request line) left the step pending for good, as did
  /// one that hung up under SSL, since EOF closed this controller only for
  /// plaintext. Over plaintext the hang-up surfaced as a bare "Bad state: No
  /// element".
  Future<List<int>> _reply(String unanswered) {
    final reply = Completer<List<int>>();
    Timer? deadline;
    StreamSubscription<List<int>>? subscription;

    void stop() {
      deadline?.cancel();
      unawaited(subscription?.cancel());
    }

    void fail(Object error, [StackTrace? stackTrace]) {
      if (reply.isCompleted) return;
      stop();
      reply.completeError(error, stackTrace);
    }

    subscription = _responseController.stream.listen(
      (data) {
        if (reply.isCompleted) return;
        stop();
        reply.complete(data);
      },
      onError: fail,
      onDone: () => fail(SocksProxyException('$_proxy $unanswered: it closed the connection')),
    );
    deadline = Timer(handshakeTimeout, () {
      fail(SocksProxyException('$_proxy $unanswered within ${_describe(handshakeTimeout)}'));
    });

    return reply.future;
  }

  String get _proxy => 'the proxy at $proxyHost:$proxyPort';

  static String _describe(Duration d) =>
      d.inMilliseconds % 1000 == 0 ? '${d.inSeconds}s' : '${d.inMilliseconds}ms';

  /// Writes [object]'s string form to the socket.
  void write(Object? object) {
    if (object == null) return;

    final List<int> data = utf8.encode(object.toString());
    if (sslEnabled) {
      _secureSocksSocket.add(data);
    } else {
      _socksSocket.add(data);
    }
  }

  /// Immediate, non-graceful teardown for one-shot request/response callers.
  ///
  /// [close] writes out what is buffered and awaits the TLS/TCP shutdown, which
  /// can hang for seconds over Tor after the reply is already in hand. The HTTP
  /// path sends `Connection: close` and reads the whole body, so there is
  /// nothing to flush; destroy the sockets outright rather than wait on a
  /// handshake nobody needs.
  void destroy() {
    _destroyed = true;
    unawaited(_subscription?.cancel());
    if (sslEnabled) {
      try {
        _secureSocksSocket.destroy();
      } catch (_) {}
    }
    try {
      _socksSocket.destroy();
    } catch (_) {}
    if (!_responseController.isClosed) _responseController.close();
    if (sslEnabled && !_secureResponseController.isClosed) _secureResponseController.close();
  }

  /// Writes out what is buffered and closes the connection.
  ///
  /// If the connection has failed, completes with its error, as `Socket.close`
  /// does, rather than waiting on writes that can no longer go out.
  Future<void> close() async {
    // A failed handshake step has already destroyed the socket, and a caller
    // that closes in a `finally` (the Ethereum explorer client) still gets
    // here. There is nothing left to write out or shut down.
    if (_destroyed) return;
    // Under SSL, nothing but the SOCKS handshake is written before [connectTo]
    // wraps the tunnel in TLS, so there is nothing to flush, and the TLS
    // socket does not exist yet. [_socksSocket] may already be detached (see
    // below), its raw socket held by the pending handshake.
    if (sslEnabled && !_secured) {
      destroy();
      return;
    }
    // [socket] is the TLS socket under SSL, and only it is closed.
    // `SecureSocket.secure` detached the raw socket from [_socksSocket] to
    // build it, so closing that wrapper does not reach the connection.
    //
    // No flush first. The close writes out what is buffered before it shuts
    // the connection down, and returns the socket's `done`, which completes
    // with the error if the connection has failed. A flush can wait forever:
    // when the connection fails while no flush is pending, dart:io reports it
    // through `done` alone and never ends the writes a later flush waits on.
    // That flush also keeps the socket's sink bound, so every close after it
    // throws "StreamSink is bound to a stream". The Electrum client closes on
    // a read error, which is exactly then.
    final carrier = socket;
    try {
      await carrier.close();
    } finally {
      // Only after the close. Cancelling shuts the socket's read side, and
      // whatever the peer sends after that (a TLS server's session tickets,
      // say) gets the connection reset, cutting short a write still going
      // out. macOS resets it as the data arrives, failing the rest of the
      // write with "Broken pipe"; Linux resets it when the socket is closed
      // with that data unread.
      await _subscription?.cancel();
      if (!_responseController.isClosed) {
        _responseController.close();
      }
      if (sslEnabled && !_secureResponseController.isClosed) {
        _secureResponseController.close();
      }
    }
  }

  StreamSubscription<List<int>> listen(
    void Function(List<int> data)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return sslEnabled
        ? _secureResponseController.stream.listen(
            onData,
            onError: onError,
            onDone: onDone,
            cancelOnError: cancelOnError,
          )
        : _responseController.stream.listen(
            onData,
            onError: onError,
            onDone: onDone,
            cancelOnError: cancelOnError,
          );
  }

  /// Sends the Electrum `server.features` command. Useful as a template for
  /// sending others.
  Future<void> sendServerFeaturesCommand() async {
    // The server.features command.
    const String command = '{"jsonrpc":"2.0","id":"0","method":"server.features","params":[]}';

    if (!sslEnabled) {
      _socksSocket.writeln(command);

      final responseData = await _responseController.stream.first;
      // Never decode and log this body verbatim. A server
      // response carries addresses, amounts and output data; see
      // Size only; `kDebugMode` is not a safe guard, because
      // verbose logs from debug builds still end up in bug reports.
      log(LogLevel.info, 'server.features response ${Redact.body(responseData.length)}');
    } else {
      _secureSocksSocket.writeln(command);

      final responseData = await _secureResponseController.stream.first;
      log(LogLevel.info, 'server.features response (tls) ${Redact.body(responseData.length)}');
    }

    return;
  }

  /// Writes [rawRequest] and reads only as far as the header terminator.
  ///
  /// **Not an HTTP response reader.** It returns whatever arrived in the same
  /// chunks as the headers, so a body that crosses a TCP segment boundary comes
  /// back truncated; silently, since the headers make it look complete. Every
  /// caller that parses a body wants [sendHttpRequest], which frames the body
  /// by `Content-Length`, the chunked terminator or EOF.
  @Deprecated('Truncates bodies split across chunks; use sendHttpRequest')
  Future<String> send(String rawRequest) async {
    write(rawRequest);
    final buffer = StringBuffer();
    await for (final response in inputStream) {
      buffer.write(utf8.decode(response));
      if (buffer.toString().contains("\r\n\r\n")) {
        break;
      }
    }
    return buffer.toString();
  }

  /// Send an HTTP request and read the full response including body.
  ///
  /// Handles Content-Length, chunked and `Connection: close` framing, bounded by
  /// [maxBytes] and [timeout]; see [readHttpResponse]. Callers that know their
  /// replies are small should say so: the default is sized for the largest
  /// legitimate response any client here asks for, which is nobody's typical
  /// case.
  Future<String> sendHttpRequest(
    String rawRequest, {
    int maxBytes = kDefaultMaxResponseBytes,
    Duration? timeout,
  }) async {
    write(rawRequest);
    return readHttpResponse(inputStream, maxBytes: maxBytes, timeout: timeout);
  }
}
