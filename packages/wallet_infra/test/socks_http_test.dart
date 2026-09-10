import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// A loopback SOCKS5 proxy that serves one canned HTTP response.
///
/// [makeSocksHttpRequest] frames a response, and the framing is only exercised
/// against a socket; `readHttpResponse`'s own tests feed it a stream, which
/// cannot show *which* reader the request path actually calls. So this speaks
/// enough of RFC 1928 to get the request through, then answers in deliberate
/// pieces: headers alone in the first write, body afterwards. That is the shape
/// a real server produces for a body of any size, and the shape that came back
/// truncated while this path used `send`.
class _FakeSocksProxy {
  _FakeSocksProxy._(this._server);

  /// Serves [responseHeaders] followed by [bodyPieces], each in its own write.
  ///
  /// Closes the connection afterwards unless [keepOpen], which stands in for a
  /// server that ignores our `Connection: close` and leaves the socket up; then
  /// only `Content-Length` can end the read.
  static Future<_FakeSocksProxy> serve({
    required String responseHeaders,
    required List<String> bodyPieces,
    bool keepOpen = false,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _FakeSocksProxy._(server);

    server.listen((Socket socket) async {
      final buffer = <int>[];
      var phase = 0;
      // `await for` rather than `listen`: it pauses the subscription across the
      // awaits below, so the phases cannot interleave.
      await for (final chunk in socket) {
        buffer.addAll(chunk);

        if (phase == 0) {
          // Greeting: version, nMethods, methods. Accept "no auth".
          if (buffer.length < 2 || buffer.length < 2 + buffer[1]) continue;
          buffer.clear();
          phase = 1;
          socket.add([0x05, 0x00]);
          await socket.flush();
          continue;
        }

        if (phase == 1) {
          // CONNECT to a domain name; the client ignores the bound address in
          // the reply, so any well-formed one will do.
          if (buffer.length < 5 || buffer.length < 7 + buffer[4]) continue;
          buffer.clear();
          phase = 2;
          socket.add([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 80]);
          await socket.flush();
          continue;
        }

        // The tunnelled HTTP request. Answer once its headers are in, then stay
        // in this phase and ignore anything further.
        if (phase != 2) continue;
        if (!utf8.decode(buffer, allowMalformed: true).contains('\r\n\r\n')) continue;
        phase = 3;
        socket.add(utf8.encode(responseHeaders));
        await socket.flush();
        for (final piece in bodyPieces) {
          // A pause between writes so the pieces cannot coalesce into the
          // segment that carried the headers; otherwise a reader that stops at
          // the header terminator would pass by luck.
          await Future<void>.delayed(const Duration(milliseconds: 20));
          socket.add(utf8.encode(piece));
          await socket.flush();
        }
        // Not `break`: cancelling the subscription would take the socket with
        // it, and the keep-alive case needs it left open.
        if (!keepOpen) await socket.close();
      }
    });

    return proxy;
  }

  final ServerSocket _server;

  ({InternetAddress host, int port}) get proxyInfo =>
      (host: InternetAddress.loopbackIPv4, port: _server.port);

  Future<void> close() => _server.close();
}

/// A response the size of a real `eth_getBlockByNumber` answer: the block's txid
/// array, which is what makes that call tens of kilobytes rather than hundreds
/// of bytes.
({String body, int txCount}) _blockResponseBody() {
  const txCount = 400;
  final hashes = [for (var i = 0; i < txCount; i++) '"0x${i.toRadixString(16).padLeft(64, '0')}"'];
  return (
    body:
        '{"jsonrpc":"2.0","id":0,"result":{"baseFeePerGas":"0x7","transactions":'
        '[${hashes.join(',')}]}}',
    txCount: txCount,
  );
}

/// Splits [text] into [count] pieces, so the body spans several writes.
List<String> _split(String text, int count) {
  final size = (text.length / count).ceil();
  return [
    for (var i = 0; i < text.length; i += size)
      text.substring(i, i + size > text.length ? text.length : i + size),
  ];
}

void main() {
  group('getRawHttpRequestString', () {
    test('builds a GET with an absolute path and no body headers', () {
      final raw = getRawHttpRequestString('get', 'https://lws.example.com/get_address_info');
      expect(raw, startsWith('GET /get_address_info HTTP/1.1\r\n'));
      expect(raw, contains('Host: lws.example.com\r\n'));
      expect(raw, contains('Connection: close\r\n'));
      expect(raw, isNot(contains('Content-Length')));
      expect(raw, endsWith('\r\n\r\n'));
    });

    test('uses / when the URL has no path', () {
      expect(getRawHttpRequestString('GET', 'http://example.com'), startsWith('GET / HTTP/1.1'));
    });

    test('preserves the query string', () {
      final raw = getRawHttpRequestString('GET', 'http://example.com/a?b=c&d=e');
      expect(raw, startsWith('GET /a?b=c&d=e HTTP/1.1'));
    });

    test('adds JSON headers and the body when one is supplied', () {
      final raw = getRawHttpRequestString('POST', 'http://example.com/x', jsonBody: '{"a":1}');
      expect(raw, contains('Content-Type: application/json; charset=UTF-8\r\n'));
      expect(raw, contains('Content-Length: 7\r\n'));
      expect(raw, endsWith('\r\n\r\n{"a":1}'));
    });

    test('measures Content-Length in bytes, not characters', () {
      // A body with multi-byte characters would under-declare its length if
      // measured by String.length, and the server would truncate it.
      const body = '{"memo":"é€"}';
      final raw = getRawHttpRequestString('POST', 'http://example.com/x', jsonBody: body);
      expect(body.length, lessThan(16));
      expect(raw, contains('Content-Length: 16\r\n'));
    });

    test('upper-cases the method', () {
      expect(getRawHttpRequestString('post', 'http://e.com/'), startsWith('POST '));
    });
  });

  group('parseHttpResponse', () {
    test('splits status line, headers and body', () {
      final r = parseHttpResponse(
        'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Thing: 1\r\n\r\nhello',
      );
      expect(r.httpVersion, 'HTTP/1.1');
      expect(r.statusCode, 200);
      expect(r.reasonPhrase, 'OK');
      expect(r.headers, {'content-type': 'text/plain', 'x-thing': '1'});
      expect(r.body, 'hello');
    });

    test('lower-cases header names and keeps value case', () {
      final r = parseHttpResponse('HTTP/1.1 200 OK\r\nX-MiXeD: VaLuE\r\n\r\n');
      expect(r.headers['x-mixed'], 'VaLuE');
    });

    test('handles a multi-word reason phrase', () {
      final r = parseHttpResponse('HTTP/1.1 500 Internal Server Error\r\n\r\n');
      expect(r.statusCode, 500);
      expect(r.reasonPhrase, 'Internal Server Error');
    });

    test('handles an absent reason phrase', () {
      final r = parseHttpResponse('HTTP/1.1 204\r\n\r\n');
      expect(r.statusCode, 204);
      expect(r.reasonPhrase, isEmpty);
    });

    test('decodes JSON only when the content type says so', () {
      final json = parseHttpResponse(
        'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"a":1}',
      );
      expect(json.jsonBody, {'a': 1});

      final text = parseHttpResponse('HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n{"a":1}');
      expect(text.jsonBody, isNull);
    });

    test('malformed JSON yields null rather than throwing', () {
      final r = parseHttpResponse(
        'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\nnot json',
      );
      expect(r.jsonBody, isNull);
      expect(r.body, 'not json');
    });

    test('rejects a response with no header/body separator', () {
      expect(() => parseHttpResponse('HTTP/1.1 200 OK'), throwsFormatException);
    });

    test('rejects a malformed status line instead of throwing RangeError', () {
      expect(() => parseHttpResponse('garbage\r\n\r\n'), throwsFormatException);
    });
  });

  group('makeSocksHttpRequest reads the whole body', () {
    // The regression: this path called `send`, which stops at the header
    // terminator. `readHttpResponse` was written, tested and wired to the
    // explorer client only; so every Ethereum JSON-RPC call over Tor, and both
    // Monero probes, parsed whatever body happened to share a segment with the
    // headers. Nothing failed loudly; `jsonBody` came back null and the caller
    // reported "Non-JSON response".
    late _FakeSocksProxy proxy;

    tearDown(() => proxy.close());

    test('a body split across writes arrives complete and parses', () async {
      final block = _blockResponseBody();
      final bodyBytes = utf8.encode(block.body).length;
      proxy = await _FakeSocksProxy.serve(
        responseHeaders:
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/json\r\n'
            'Connection: close\r\n'
            'Content-Length: $bodyBytes\r\n\r\n',
        bodyPieces: _split(block.body, 8),
      );

      final response = await makeSocksHttpRequest(
        'POST',
        'http://rpc.example.com/',
        proxy.proxyInfo,
        body:
            '{"jsonrpc":"2.0","id":0,"method":"eth_getBlockByNumber",'
            '"params":["latest",false]}',
      ).timeout(const Duration(seconds: 10));

      expect(response.statusCode, 200);
      expect(response.body.length, block.body.length);
      expect(bodyBytes, greaterThan(20000), reason: 'a realistic block, not a token payload');

      // What the caller actually needs: the txid array, whole.
      final json = response.jsonBody as Map<dynamic, dynamic>;
      final result = json['result'] as Map<dynamic, dynamic>;
      expect(result['transactions'], hasLength(block.txCount));
      expect(result['baseFeePerGas'], '0x7');
    });

    test('a body with no Content-Length is read to EOF', () async {
      // `Connection: close` framing. Requests here always ask for it, so this is
      // the common case rather than an exotic one, and it only terminates
      // because the plaintext socket now closes its response controller at EOF.
      proxy = await _FakeSocksProxy.serve(
        responseHeaders:
            'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n',
        bodyPieces: ['{"result":', '"0x', 'abc"}'],
      );

      final response = await makeSocksHttpRequest(
        'GET',
        'http://lws.example.com/get_height',
        proxy.proxyInfo,
      ).timeout(const Duration(seconds: 10));

      expect(response.jsonBody, {'result': '0xabc'});
    });

    test('Content-Length ends the read without waiting for EOF', () async {
      // A server that ignores `Connection: close` and keeps the socket open.
      // Anything that waited for EOF here would hang until the caller's timeout.
      const body = '{"result":"0x1"}';
      proxy = await _FakeSocksProxy.serve(
        responseHeaders:
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: ${body.length}\r\n\r\n',
        bodyPieces: _split(body, 4),
        keepOpen: true,
      );

      final response = await makeSocksHttpRequest(
        'GET',
        'http://lws.example.com/get_height',
        proxy.proxyInfo,
      ).timeout(const Duration(seconds: 10));

      expect(response.jsonBody, {'result': '0x1'});
    });
  });

  group('toString is safe to log', () {
    // A response body must never be logged. An earlier version printed it and
    // the decoded JSON, so `log(..., '$response')` disclosed every address and
    // amount in an LWS reply.
    test('never contains the body or the decoded JSON', () {
      const secretish = '44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98';
      final r = parseHttpResponse(
        'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n'
        '{"address":"$secretish","amount":123456789}',
      );

      final s = r.toString();
      expect(s, isNot(contains(secretish)));
      expect(s, isNot(contains('123456789')));
      expect(s, isNot(contains('address')));
    });

    test('still carries what a diagnosis needs', () {
      final r = parseHttpResponse('HTTP/1.1 500 Internal Server Error\r\nX-A: 1\r\n\r\nbody');
      final s = r.toString();
      expect(s, contains('500'));
      expect(s, contains('Internal Server Error'));
      expect(s, contains('1 headers'));
      expect(s, contains('4 bytes'));
    });
  });
}
