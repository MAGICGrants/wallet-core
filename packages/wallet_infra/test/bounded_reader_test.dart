import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// The three properties the old reader lacked: a bound, real cancellation, and
/// a linear scan.
///
/// Framing behaviour is pinned separately in `socks_socket_test.dart`, which
/// this rewrite had to leave untouched; those tests are the regression guard
/// for the transport merge, and passing them unmodified is the evidence that
/// the framing rules did not move.

/// A source that records whether it was cancelled and how much it was asked for.
class _Source {
  _Source() {
    controller = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
  }

  late final StreamController<List<int>> controller;
  bool cancelled = false;

  Stream<List<int>> get stream => controller.stream;

  void send(String s) => controller.add(utf8.encode(s));
  void sendBytes(List<int> b) => controller.add(b);
  Future<void> close() => controller.close();
}

void main() {
  group('the cap', () {
    test('a body past the limit is refused rather than accumulated', () async {
      final source = _Source();
      source.send('HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n');
      source.send('x' * 5000);

      await expectLater(
        readHttpResponse(source.stream, maxBytes: 1024),
        throwsA(isA<ResponseTooLargeException>()),
      );
    });

    test('refusing names sizes and not one byte of the body', () async {
      // The body is attacker-supplied; an exception that quotes it is a log
      // disclosure waiting to happen.
      final source = _Source();
      source.send('HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n');
      source.send('SECRETMARKER' * 500);

      try {
        await readHttpResponse(source.stream, maxBytes: 512);
        fail('must throw');
      } on ResponseTooLargeException catch (e) {
        expect(e.toString(), contains('512'));
        expect(e.toString(), isNot(contains('SECRETMARKER')));
      }
    });

    test('a response inside the limit is returned whole', () async {
      final body = 'y' * 900;
      final source = _Source();
      source.send('HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n');
      source.send(body);

      final response = await readHttpResponse(source.stream, maxBytes: 4096);
      expect(response, endsWith(body));
    });

    test('the limit applies to headers too, so an endless header set is bounded', () async {
      // Without this, a server that never sends the terminator is unbounded no
      // matter what the body rules say.
      final source = _Source();
      source.send('HTTP/1.1 200 OK\r\n');
      source.send('X-Filler: ${'a' * 5000}\r\n');

      await expectLater(
        readHttpResponse(source.stream, maxBytes: 1024),
        throwsA(isA<ResponseTooLargeException>()),
      );
    });
  });

  group('cancellation, not abandonment', () {
    test('hitting the cap cancels the subscription', () async {
      // The half `.timeout()` never did: the future completed, the subscription
      // stayed attached, and a slow flood kept arriving into a buffer nobody
      // would read.
      final source = _Source();
      source.send('HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n');
      source.send('x' * 5000);

      await expectLater(
        readHttpResponse(source.stream, maxBytes: 1024),
        throwsA(isA<ResponseTooLargeException>()),
      );
      await pumpEventQueue();
      expect(source.cancelled, isTrue);
    });

    test('a timeout cancels the subscription', () async {
      final source = _Source();
      source.send('HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n');
      // Never closed, never completed: the keep-alive flood case.

      await expectLater(
        readHttpResponse(source.stream, timeout: const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
      await pumpEventQueue();
      expect(source.cancelled, isTrue, reason: 'a timed-out read must stop consuming');
    });

    test('a completed read cancels too', () async {
      final source = _Source();
      source.send('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok');

      expect(await readHttpResponse(source.stream), endsWith('ok'));
      await pumpEventQueue();
      expect(source.cancelled, isTrue);
    });

    test('a stream error surfaces and stops the read', () async {
      final source = _Source();
      source.controller.addError(const FakeSocketError('reset'));

      await expectLater(readHttpResponse(source.stream), throwsA(isA<FakeSocketError>()));
    });
  });

  group('the scan is linear', () {
    test('4 MiB over Connection: close reads in well under a second', () async {
      // The measurement in the old reader's own doc comment: 4 MiB in **20.4
      // seconds**, on the main isolate, because every chunk re-decoded the whole
      // accumulated buffer to UTF-16 and rescanned it. 4× the body for ~16× the
      // time. A generous ceiling here still fails loudly if that shape returns.
      final source = _Source();
      final segment = List<int>.filled(1400, 0x78); // 'x'
      final segments = (4 * 1024 * 1024) ~/ segment.length;

      final watch = Stopwatch()..start();
      final read = readHttpResponse(source.stream, maxBytes: 16 * 1024 * 1024);
      source.send('HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n');
      for (var i = 0; i < segments; i++) {
        source.sendBytes(segment);
      }
      await source.close();
      final response = await read;
      watch.stop();

      expect(response.length, greaterThan(4 * 1024 * 1024 - 4096));
      expect(
        watch.elapsedMilliseconds,
        lessThan(3000),
        reason: 'the quadratic reader took 20400ms for this exact input',
      );
    });
  });

  group('terminators split across chunks are still found', () {
    test('the header terminator arriving in pieces', () async {
      final source = _Source();
      source.send('HTTP/1.1 200 OK\r\nContent-Length: 2\r');
      source.send('\n\r\n');
      source.send('ok');

      expect(await readHttpResponse(source.stream), endsWith('ok'));
    });

    test('the chunked terminator arriving in pieces', () async {
      final source = _Source();
      source.send('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n');
      source.send('2\r\nhi\r\n');
      source.send('0\r');
      source.send('\n\r\n');

      final response = await readHttpResponse(source.stream);
      expect(response, contains('hi'));
    });

    test('a body containing the terminator bytes early still frames correctly', () async {
      // Content-Length wins, so an embedded `\r\n0\r\n\r\n` inside the body must
      // not end the read short.
      const body = 'a\r\n0\r\n\r\nbcdef';
      final source = _Source();
      source.send('HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n\r\n');
      source.send(body);

      final response = await readHttpResponse(source.stream);
      expect(response, endsWith(body));
    });
  });

  group('readBoundedBody', () {
    test('caps a plain byte stream and cancels', () async {
      final source = _Source();
      source.sendBytes(List<int>.filled(5000, 0x61));

      await expectLater(
        readBounded(source.stream, maxBytes: 1024),
        throwsA(isA<ResponseTooLargeException>()),
      );
      await pumpEventQueue();
      expect(source.cancelled, isTrue);
    });

    test('returns everything when the stream ends inside the cap', () async {
      // The read is started first: `close()` on a controller with no listener
      // never completes, so awaiting it before subscribing hangs.
      final source = _Source();
      final read = readBounded(source.stream, maxBytes: 64);
      source.send('hello');
      await source.close();

      expect(utf8.decode(await read), 'hello');
    });
  });
}

/// Stands in for a socket error without importing `dart:io` for one type.
class FakeSocketError implements Exception {
  const FakeSocketError(this.message);
  final String message;
}
