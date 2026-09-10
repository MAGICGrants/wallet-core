import 'dart:convert';
import 'dart:io';

import '../logging.dart';
import 'bounded_reader.dart';
import 'socks_socket.dart';

class ParsedHttpResponse {
  final String httpVersion;
  final int statusCode;
  final String reasonPhrase;
  final Map<String, String> headers;
  final String body;

  /// Decoded JSON when the response declared `application/json`, else null.
  final dynamic jsonBody;

  ParsedHttpResponse({
    required this.httpVersion,
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.body,
    this.jsonBody,
  });

  /// Safe to log.
  ///
  /// The inherited version printed the full body and the decoded JSON, which
  /// made `log(..., '$response')` a one-line disclosure of every address and
  /// amount in an LWS reply; exactly the "never interpolate a whole object"
  /// case for `Redact`. A response summary is diagnostic; its contents
  /// are not ours to record.
  @override
  String toString() =>
      'HTTP $statusCode $reasonPhrase ($httpVersion), '
      '${headers.length} headers, ${Redact.body(body.length)}';
}

String getRawHttpRequestString(String method, String url, {Object? jsonBody}) {
  final uri = Uri.parse(url);
  final host = uri.host;

  final path = uri.path.isEmpty ? '/' : uri.path;
  final query = uri.hasQuery ? '?${uri.query}' : '';
  final fullPath = '$path$query';

  final request = StringBuffer();

  request.write('${method.toUpperCase()} $fullPath HTTP/1.1\r\n');
  request.write('Host: $host\r\n');
  request.write('Connection: close\r\n');
  request.write('Accept: */*\r\n');

  final jsonBodyStr = jsonBody?.toString();

  if (jsonBodyStr != null && jsonBodyStr.isNotEmpty) {
    final bodyBytes = utf8.encode(jsonBodyStr);
    request.write('Content-Type: application/json; charset=UTF-8\r\n');
    request.write('Content-Length: ${bodyBytes.length}\r\n');
  }

  request.write('\r\n');

  if (jsonBodyStr != null && jsonBodyStr.isNotEmpty) {
    request.write(jsonBodyStr);
  }

  return request.toString();
}

ParsedHttpResponse parseHttpResponse(String rawResponse) {
  const separator = '\r\n\r\n';
  final separatorIndex = rawResponse.indexOf(separator);

  if (separatorIndex == -1) {
    throw const FormatException('Invalid HTTP response: No header/body separator found.');
  }

  final headersPart = rawResponse.substring(0, separatorIndex);
  final body = rawResponse.substring(separatorIndex + separator.length);
  final headerLines = headersPart.split('\r\n');

  final statusLine = headerLines.first;
  final statusLineParts = statusLine.split(' ');
  if (statusLineParts.length < 2) {
    throw const FormatException('Invalid HTTP response: malformed status line.');
  }
  final httpVersion = statusLineParts[0];
  final statusCode = int.parse(statusLineParts[1]);
  final reasonPhrase = statusLineParts.sublist(2).join(' ');

  final headers = <String, String>{};
  for (var i = 1; i < headerLines.length; i++) {
    final line = headerLines[i];
    final colonIndex = line.indexOf(':');
    if (colonIndex != -1) {
      final key = line.substring(0, colonIndex).trim().toLowerCase();
      final value = line.substring(colonIndex + 1).trim();
      headers[key] = value;
    }
  }

  dynamic jsonBody;
  if (headers['content-type']?.contains('application/json') ?? false) {
    try {
      jsonBody = jsonDecode(body);
    } catch (_) {
      jsonBody = null;
    }
  }

  return ParsedHttpResponse(
    httpVersion: httpVersion,
    statusCode: statusCode,
    reasonPhrase: reasonPhrase,
    headers: headers,
    body: body,
    jsonBody: jsonBody,
  );
}

/// One proxied HTTP request/response.
///
/// [maxBytes] and [timeout] bound the read itself rather than wrapping it in a
/// `.timeout()` at the call site: that completed the caller's future while the
/// subscription stayed attached, so a hostile or merely slow server kept
/// arriving into a buffer nobody would look at. See [readHttpResponse].
Future<ParsedHttpResponse> makeSocksHttpRequest(
  String method,
  String url,
  ({InternetAddress host, int port}) proxyInfo, {
  Object? body,
  int maxBytes = kDefaultMaxResponseBytes,
  Duration? timeout,
}) async {
  final uri = Uri.parse(url);

  final socket = await SOCKSSocket.create(
    proxyHost: proxyInfo.host.address,
    proxyPort: proxyInfo.port,
    sslEnabled: uri.scheme == 'https',
  );

  try {
    log(
      LogLevel.warn,
      '▶ SOCKS: connecting to proxy (${uri.host}:${uri.port}, ssl=${uri.scheme == 'https'})',
    );
    await socket.connect();
    log(LogLevel.warn, '▶ SOCKS: proxy connected; connectTo + TLS handshake…');
    await socket.connectTo(uri.host, uri.port);
    log(LogLevel.warn, '▶ SOCKS: connectTo done (handshake ok); sending request…');

    final rawRequest = getRawHttpRequestString(method, url, jsonBody: body);
    // Full-body framing (Content-Length/chunked/EOF). `send` alone stops at the
    // header terminator, so it returns a body only when the server put it in the
    // same TCP segment as the headers; replies split across segments (Kraken's
    // rate JSON, an eth block's txid array) come back truncated.
    final rawResponse = await socket.sendHttpRequest(
      rawRequest,
      maxBytes: maxBytes,
      timeout: timeout,
    );
    log(LogLevel.warn, '▶ SOCKS: response received (${rawResponse.length} chars)');

    return parseHttpResponse(rawResponse);
  } finally {
    // Each request opens its own SOCKS connection, and with it a Tor circuit.
    // Left open they accumulate for the life of the process; the fiat poller
    // alone starts one every ten minutes. Closing must not mask a request
    // error, so its own failure is only logged.
    //
    // Bounded: this runs in `finally`, before the already-parsed response is
    // returned, and closing a secure SOCKS socket over Tor can hang, which
    // would fail the request to the caller's timeout DESPITE the response having
    // arrived. That was the fiat-over-Tor bug. Skylight bounded it; match that.
    try {
      await socket.close().timeout(const Duration(seconds: 5));
    } catch (e) {
      log(LogLevel.warn, 'Failed to close SOCKS socket: $e');
    }
  }
}
