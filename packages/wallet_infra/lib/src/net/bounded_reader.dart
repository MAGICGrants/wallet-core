import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClientResponse;

/// Default ceiling on a single response body.
///
/// Generous on purpose: a Blockscout address history is the largest thing any
/// of these clients legitimately asks for, and refusing a real answer is a worse
/// failure than reading a few megabytes. Callers that know their replies are
/// small pass something tighter; a Kraken ticker or a Monero node status is
/// kilobytes, and a cap of the right order turns "hostile server floods us" into
/// an immediate, cheap error instead of a slow one.
///
/// The value is policy, and the project's own README said so before this
/// existed. What is *not* policy is that some bound exists: an unbounded reader
/// on a network the user does not control has no honest defence.
const int kDefaultMaxResponseBytes = 8 * 1024 * 1024;

/// Thrown when a response exceeds the cap it was read under.
///
/// Names sizes only. The bytes that arrived are attacker-supplied and have no
/// business in a log line.
class ResponseTooLargeException implements Exception {
  const ResponseTooLargeException({required this.limitBytes, required this.readBytes});

  final int limitBytes;
  final int readBytes;

  @override
  String toString() =>
      'ResponseTooLargeException: response exceeded $limitBytes bytes '
      '(stopped at $readBytes)';
}

/// Reads [chunks] until [isComplete] says the response is whole, the stream
/// ends, [maxBytes] is exceeded, or [timeout] elapses.
///
/// Shared by every reader in this file, for three properties they all need:
///
///  - **Bounded.** Accumulation stops at [maxBytes]. Without it, only the server
///    decides how much memory a read uses.
///  - **Cancelling, not abandoning.** The subscription is cancelled as soon as
///    the read finishes, fails or times out. Wrapping a read in `.timeout()`
///    completes the future but leaves the subscription attached, so a slow flood
///    keeps arriving and appending to a buffer nobody will read.
///  - **Linear.** [isComplete] gets the index new bytes started at, so it can
///    scan what just arrived instead of the whole buffer each chunk. Re-decoding
///    the accumulated body every chunk measured 4 MiB at 20.4s on the main
///    isolate.
Future<List<int>> readBounded(
  Stream<List<int>> chunks, {
  required int maxBytes,
  Duration? timeout,
  bool Function(List<int> bytes, int newFrom)? isComplete,
}) {
  final bytes = <int>[];
  final completer = Completer<List<int>>();
  StreamSubscription<List<int>>? subscription;
  Timer? timer;

  void finish({Object? error, StackTrace? stackTrace}) {
    if (completer.isCompleted) return;
    timer?.cancel();
    // Cancel rather than let it run: this is the half `.timeout()` never did.
    unawaited(subscription?.cancel());
    if (error != null) {
      completer.completeError(error, stackTrace ?? StackTrace.current);
    } else {
      completer.complete(bytes);
    }
  }

  subscription = chunks.listen(
    (chunk) {
      final newFrom = bytes.length;
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        finish(
          error: ResponseTooLargeException(limitBytes: maxBytes, readBytes: bytes.length),
        );
        return;
      }
      if (isComplete != null && isComplete(bytes, newFrom)) finish();
    },
    onError: (Object error, StackTrace stackTrace) => finish(error: error, stackTrace: stackTrace),
    onDone: finish,
    cancelOnError: false,
  );

  if (timeout != null) {
    timer = Timer(timeout, () => finish(error: TimeoutException('response not complete', timeout)));
  }

  return completer.future;
}

/// Reads an `HttpClient` response body under a cap.
///
/// `HttpClient` has already framed the body, so this only has to bound it;
/// which `await response.transform(utf8.decoder).join()` did not.
Future<String> readBoundedBody(
  HttpClientResponse response, {
  int maxBytes = kDefaultMaxResponseBytes,
  Duration? timeout,
}) async => utf8.decode(await readBounded(response, maxBytes: maxBytes, timeout: timeout));

// ----- HTTP framing over a raw byte stream -----

const List<int> _headerTerminator = [13, 10, 13, 10]; // CRLF CRLF
const List<int> _chunkedTerminator = [13, 10, 48, 13, 10, 13, 10]; // CRLF "0" CRLF CRLF

final RegExp _contentLengthPattern = RegExp(r'content-length:\s*(\d+)', caseSensitive: false);

/// State a framing scan carries between chunks.
class _HttpFraming {
  int? headerEnd;
  int? contentLength;

  /// Where the next header search may start. Kept back by three bytes from the
  /// end so a terminator split across two chunks is still found.
  int headerScanFrom = 0;

  /// Same idea for the chunked terminator, which is seven bytes.
  int bodyScanFrom = 0;
}

/// Index of [needle] in [haystack] at or after [from], or -1.
int _indexOfBytes(List<int> haystack, List<int> needle, int from) {
  final last = haystack.length - needle.length;
  for (var i = from < 0 ? 0 : from; i <= last; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

int _backFrom(int length, int overlap) {
  final from = length - overlap;
  return from < 0 ? 0 : from;
}

/// Accumulates a complete HTTP response from [chunks].
///
/// Three framing rules, and getting their interaction wrong is what the two apps
/// each did differently:
///
///  - `Content-Length: N`: stop once N body bytes have arrived.
///  - Chunked: stop at the `\r\n0\r\n\r\n` terminator.
///  - `Connection: close`: the server will not keep the connection alive, so
///    **ignore Content-Length and read to EOF**. Without this a server that
///    sends both headers leaves the caller waiting on a finished socket.
///
/// Those rules are unchanged. What changed is everything around them: the scan
/// is linear and byte-level rather than decoding the whole buffer per chunk, the
/// body is capped at [maxBytes], and [timeout] cancels the subscription instead
/// of abandoning it. See [readBounded].
Future<String> readHttpResponse(
  Stream<List<int>> chunks, {
  int maxBytes = kDefaultMaxResponseBytes,
  Duration? timeout,
}) async {
  final framing = _HttpFraming();

  bool isComplete(List<int> bytes, int newFrom) {
    if (framing.headerEnd == null) {
      final at = _indexOfBytes(bytes, _headerTerminator, framing.headerScanFrom);
      if (at < 0) {
        framing.headerScanFrom = _backFrom(bytes.length, _headerTerminator.length - 1);
        return false;
      }
      framing.headerEnd = at;
      framing.bodyScanFrom = at + _headerTerminator.length;

      // Decoded once, over the headers alone; bounded by whatever the server
      // spent before the terminator, which `maxBytes` already covers.
      final headers = utf8.decode(bytes.sublist(0, at), allowMalformed: true);
      final match = _contentLengthPattern.firstMatch(headers);
      framing.contentLength = match == null ? null : int.tryParse(match.group(1)!);
      // Rule three: an announced close means EOF frames the body, whatever
      // Content-Length claimed.
      if (headers.toLowerCase().contains('connection: close')) framing.contentLength = null;
    }

    final headerEnd = framing.headerEnd!;
    final bodyStart = headerEnd + _headerTerminator.length;
    final declared = framing.contentLength;
    if (declared != null) return bytes.length - bodyStart >= declared;

    // Chunked, or read-to-EOF. The terminator can only be at the tail, so look
    // there rather than rescanning the body; that scan, over a re-decoded
    // buffer, was the quadratic half.
    final from = [
      framing.bodyScanFrom,
      bodyStart,
      _backFrom(newFrom, _chunkedTerminator.length - 1),
    ].reduce((a, b) => a > b ? a : b);
    if (_indexOfBytes(bytes, _chunkedTerminator, from) >= 0) return true;
    framing.bodyScanFrom = _backFrom(bytes.length, _chunkedTerminator.length - 1);
    return false;
  }

  final bytes = await readBounded(
    chunks,
    maxBytes: maxBytes,
    timeout: timeout,
    isComplete: isComplete,
  );
  return utf8.decode(bytes);
}
