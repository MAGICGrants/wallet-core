import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

void main() {
  late MemoryLogSink sink;

  setUp(() {
    sink = MemoryLogSink();
    WalletLog.sink = sink;
    WalletLog.isVerbose = () async => true;
  });

  tearDown(WalletLog.resetForTesting);

  group('verbosity gating', () {
    test('info is dropped when verbose logging is off', () async {
      WalletLog.isVerbose = () async => false;
      await log(LogLevel.info, 'chatty');
      expect(sink.records, isEmpty);
    });

    test('warn and error always get through', () async {
      WalletLog.isVerbose = () async => false;
      await log(LogLevel.warn, 'careful');
      await log(LogLevel.error, 'broken');
      expect(sink.records.map((r) => r.level), [LogLevel.warn, LogLevel.error]);
    });

    test('info gets through when verbose is on', () async {
      await log(LogLevel.info, 'chatty');
      expect(sink.records, hasLength(1));
    });
  });

  group('formatting', () {
    test('carries an ISO-8601 UTC timestamp and an upper-case level', () async {
      await log(LogLevel.warn, 'message here');
      final line = sink.records.single.line;
      expect(line, matches(RegExp(r'^\[\d{4}-\d{2}-\d{2}T[\d:.]+Z\] \[WARN\] message here$')));
    });

    test('no double space and no trailing space when meta is absent', () async {
      // Skylight's version was '[ts] [LEVEL] $message $metaStr', which left a
      // trailing space on every meta-less line and a double space otherwise,
      // because metaStr already carries its own leading space.
      await log(LogLevel.error, 'plain');
      final line = sink.records.single.line;
      expect(line, endsWith('] plain'));
      expect(line, isNot(contains('  ')));
    });

    test('meta is appended with exactly one separating space', () async {
      await log(LogLevel.error, 'with meta', meta: {'a': 1});
      expect(sink.records.single.line, endsWith('with meta {a: 1}'));
    });

    test('empty meta is treated as absent', () async {
      await log(LogLevel.error, 'empty meta', meta: const {});
      expect(sink.records.single.line, endsWith('] empty meta'));
    });
  });

  group('coin prefix', () {
    test('is added when a coin is supplied', () async {
      await log(LogLevel.error, 'syncing', coin: 'XMR');
      expect(sink.records.single.line, endsWith('[XMR] syncing'));
    });

    test('is absent for a single-coin caller', () async {
      await log(LogLevel.error, 'syncing');
      expect(sink.records.single.line, endsWith('] syncing'));
      expect(sink.records.single.line, isNot(contains('[XMR]')));
    });

    test('is not applied twice to an already-prefixed message', () async {
      await log(LogLevel.error, '[XMR] already tagged', coin: 'XMR');
      final line = sink.records.single.line;
      expect(line, endsWith('[XMR] already tagged'));
      expect('[XMR]'.allMatches(line).length, 1);
    });

    test('an empty coin is treated as no coin', () async {
      await log(LogLevel.error, 'syncing', coin: '');
      expect(sink.records.single.line, endsWith('] syncing'));
    });
  });

  test('the default sink is restored by resetForTesting', () {
    WalletLog.resetForTesting();
    expect(WalletLog.sink, isA<DebugPrintLogSink>());
  });
}
