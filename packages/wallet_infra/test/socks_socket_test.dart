import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Framing rules for [readHttpResponse].
///
/// Regression guard for the socks_socket merge. Two forks
/// each fixed a different bug in this file and neither took the other's:
/// One added the `connection: close` handling tested here, the other added the
/// `_subscription?.pause()` before the TLS upgrade. The merged file has both;
/// these tests keep the half that is testable without a socket from being
/// dropped again.

Stream<List<int>> _chunks(List<String> parts) => Stream.fromIterable(parts.map(utf8.encode));

/// A stream that emits [parts] and then hangs. Stands in for a keep-alive
/// connection the server has not closed: anything relying on EOF never
/// completes against it.
Stream<List<int>> _neverEnding(List<String> parts) {
  final controller = StreamController<List<int>>();
  for (final p in parts) {
    controller.add(utf8.encode(p));
  }
  return controller.stream;
}

void main() {
  group('Content-Length framing', () {
    test('stops once the declared body length has arrived', () async {
      final body = 'hello world';
      final response = await readHttpResponse(
        _neverEnding(['HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n', body]),
      );

      expect(response, endsWith(body));
      expect(response, contains('200 OK'));
    });

    test('does not require the stream to close', () async {
      // The whole point of Content-Length: a keep-alive connection stays open.
      final response = await readHttpResponse(
        _neverEnding(['HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n', 'ok']),
      ).timeout(const Duration(seconds: 2));

      expect(response, endsWith('ok'));
    });

    test('accepts a body split across chunks', () async {
      final response = await readHttpResponse(
        _neverEnding(['HTTP/1.1 200 OK\r\n', 'Content-Length: 10\r\n\r\n', 'abcde', 'fghij']),
      );

      expect(response, endsWith('abcdefghij'));
    });

    test('is case-insensitive on the header name', () async {
      final response = await readHttpResponse(
        _neverEnding(['HTTP/1.1 200 OK\r\ncOnTeNt-LeNgTh: 3\r\n\r\n', 'abc']),
      );

      expect(response, endsWith('abc'));
    });
  });

  group('connection: close framing (Skylight fix)', () {
    test('reads to EOF when the server will not keep the connection alive', () async {
      final response = await readHttpResponse(
        _chunks(['HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n', 'streamed ', 'in pieces']),
      );

      expect(response, endsWith('streamed in pieces'));
    });

    test('Connection: close WINS over a Content-Length that understates the body', () async {
      // The regression that motivated the fix. A server sending both headers
      // and then more body than Content-Length claims would, without this,
      // truncate the response. Reading to EOF is what makes it whole.
      final response = await readHttpResponse(
        _chunks([
          'HTTP/1.1 500 Internal Server Error\r\n'
              'Content-Length: 4\r\n'
              'Connection: close\r\n\r\n',
          'much longer than four bytes',
        ]),
      );

      expect(response, endsWith('much longer than four bytes'));
    });

    test('matches the header case-insensitively', () async {
      final response = await readHttpResponse(
        _chunks(['HTTP/1.1 200 OK\r\nCONNECTION: CLOSE\r\n\r\n', 'body']),
      );

      expect(response, endsWith('body'));
    });

    test('handles an empty body', () async {
      final response = await readHttpResponse(
        _chunks(['HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n']),
      );

      expect(response, contains('204'));
    });
  });

  group('chunked framing', () {
    test('stops at the terminating zero-length chunk', () async {
      final response = await readHttpResponse(
        _neverEnding([
          'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n',
          '4\r\nWiki\r\n',
          '0\r\n\r\n',
        ]),
      );

      expect(response, contains('Wiki'));
    });
  });

  group('degenerate input', () {
    test('a stream that closes before any headers yields what arrived', () async {
      expect(await readHttpResponse(_chunks(['HTTP/1.1 200 OK\r\n'])), 'HTTP/1.1 200 OK\r\n');
    });

    test('an empty stream yields an empty string', () async {
      expect(await readHttpResponse(const Stream<List<int>>.empty()), isEmpty);
    });
  });
}
