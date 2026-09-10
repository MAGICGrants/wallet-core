import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging.dart';
import 'bounded_reader.dart';

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

  SOCKSSocket._(this.proxyHost, this.proxyPort, this.sslEnabled) {
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
  static Future<SOCKSSocket> create({
    required String proxyHost,
    required int proxyPort,
    bool sslEnabled = false,
  }) async {
    final instance = SOCKSSocket._(proxyHost, proxyPort, sslEnabled);

    await instance._init();

    return instance;
  }

  SOCKSSocket({required this.proxyHost, required this.proxyPort, required this.sslEnabled}) {
    _responseController = StreamController.broadcast();
    _secureResponseController = StreamController.broadcast();
    _init();
  }

  /// Opens the proxy connection and starts forwarding its data.
  Future<void> _init() async {
    _socksSocket = await Socket.connect(proxyHost, proxyPort);

    _subscription = _socksSocket.listen(
      (data) {
        if (!_responseController.isClosed) {
          _responseController.add(data);
        }
      },
      onError: (Object e, StackTrace stackTrace) {
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
        // Only for the plaintext socket: under SSL the caller reads
        // `_secureResponseController`, which closes in its own `onDone` below,
        // and this controller carried the SOCKS handshake that is long over.
        if (!sslEnabled && !_responseController.isClosed) {
          _responseController.close();
        }
      },
    );
  }

  /// Performs the SOCKS5 greeting and method selection.
  Future<void> connect() async {
    // Greeting and method selection.
    _socksSocket.add([0x05, 0x01, 0x00]);

    final response = await _responseController.stream.first;

    if (response[1] != 0x00) {
      throw Exception('socks_socket.connect(): Failed to connect to SOCKS5 proxy.');
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
  Future<void> connectTo(String domain, int port) async {
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

    final response = await _responseController.stream.first;

    if (response[1] != 0x00) {
      final replyCode = response[1];
      final replyMessage = _socks5ReplyCodes[replyCode] ?? 'Unknown error';
      throw Exception(
        'socks_socket.connectTo(): Failed to connect to $domain:$port - SOCKS5 error $replyCode: $replyMessage',
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
      _secureSocksSocket = await SecureSocket.secure(
        _socksSocket,
        host: domain,
        // onBadCertificate: (_) => true, // Uncomment this to bypass certificate validation (NOT recommended for production).
      );

      _subscription = _secureSocksSocket.listen(
        (data) {
          if (!_secureResponseController.isClosed) {
            _secureResponseController.add(data);
          }
        },
        onError: (Object e, StackTrace stackTrace) {
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

  /// Flushes pending data and closes the connection.
  Future<void> close() async {
    try {
      if (sslEnabled) {
        await _secureSocksSocket.flush();
      }
      await _socksSocket.flush();
    } finally {
      await _subscription?.cancel();
      await _socksSocket.close();
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
