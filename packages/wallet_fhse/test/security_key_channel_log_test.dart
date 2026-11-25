import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fhse/wallet_fhse.dart';
import 'package:wallet_infra/wallet_infra.dart' show LogLevel, MemoryLogSink, WalletLog;

/// The native halves' `log` calls on the security key channel reach the app's
/// log, so an exported log shows which key answered and how a request ended.
const _channel = MethodChannel(SecurityKeyService.channelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryLogSink sink;
  var loggingOn = true;

  setUp(() {
    sink = MemoryLogSink();
    loggingOn = true;
    WalletLog.sink = sink;
    WalletLog.isLoggingOn = () async => loggingOn;
    // Registers the channel's handler, whatever host the test runs on.
    SecurityKeyService.channelBackendForTesting();
  });

  tearDown(WalletLog.resetForTesting);

  /// Delivers a call from the native side and waits until it is handled.
  Future<void> fromNative(String method, Object? arguments) {
    final handled = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => handled.complete(),
    );
    return handled.future;
  }

  test('a key line is info and a failure is a warning', () async {
    await fromNative('log', {'line': 'enroll: nfc, firmware 5.7.4', 'warning': false});
    await fromNative('log', {
      'line': 'enroll failed: pinInvalid, 5 attempts left; steps connect > PIN token',
      'warning': true,
    });

    expect(sink.records.map((r) => r.level), [LogLevel.info, LogLevel.warn]);
    expect(sink.records[0].line, endsWith('[INFO] [SecurityKey] enroll: nfc, firmware 5.7.4'));
    expect(
      sink.records[1].line,
      endsWith(
        '[WARN] [SecurityKey] enroll failed: pinInvalid, 5 attempts left; steps connect > PIN token',
      ),
    );
  });

  test('with logging off, only failures reach the sink', () async {
    loggingOn = false;
    await fromNative('log', {'line': 'getHmacSecret finished', 'warning': false});
    await fromNative('log', {'line': 'getHmacSecret failed: transport', 'warning': true});

    expect(sink.records.map((r) => r.line), [
      endsWith('[SecurityKey] getHmacSecret failed: transport'),
    ]);
  });

  test('a malformed log call is dropped', () async {
    await fromNative('log', {'line': 42, 'warning': true});
    await fromNative('log', 'inspect finished');

    expect(sink.records, isEmpty);
  });
}
