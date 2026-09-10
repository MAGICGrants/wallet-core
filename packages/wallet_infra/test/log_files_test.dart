import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wallet_log_files');
    WalletPaths.install(
      linuxDirName: '.test_wallet',
      windowsAppDataDir: 'MAGIC Grants/Test Wallet',
      directories: FixedDirectories(tmp),
    );
  });

  tearDown(() {
    WalletPaths.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<File> writeLog(String name, {DateTime? modified}) async {
    final logsDir = Directory('${tmp.path}/logs')..createSync(recursive: true);
    final file = File('${logsDir.path}/$name')..writeAsStringSync('line\n');
    if (modified != null) file.setLastModifiedSync(modified);
    return file;
  }

  test('returns empty when the logs directory is absent', () async {
    expect(await getLogFiles(), isEmpty);
  });

  test('lists .txt log files with their size', () async {
    await writeLog('log_2026-08-19.txt');
    final files = await getLogFiles();
    expect(files, hasLength(1));
    expect(files.single.name, 'log_2026-08-19.txt');
    expect(files.single.size, greaterThan(0));
  });

  test('ignores non-.txt files', () async {
    await writeLog('log_2026-08-19.txt');
    await writeLog('notes.md');
    final files = await getLogFiles();
    expect(files.map((f) => f.name), ['log_2026-08-19.txt']);
  });

  test('sorts newest first', () async {
    await writeLog('old.txt', modified: DateTime(2026, 1, 1));
    await writeLog('new.txt', modified: DateTime(2026, 8, 1));
    final files = await getLogFiles();
    expect(files.map((f) => f.name), ['new.txt', 'old.txt']);
  });

  test('exportLogFiles rejects an empty selection', () {
    expect(exportLogFiles([]), throwsException);
  });

  group('FileLogSink', () {
    tearDown(WalletLog.resetForTesting);

    test('appends to a dated file when verbose', () async {
      WalletLog.isVerbose = () async => true;
      final sink = FileLogSink();
      await sink.write(LogLevel.info, 'first');
      await sink.write(LogLevel.warn, 'second');

      final files = await getLogFiles();
      expect(files, hasLength(1));
      expect(files.single.name, startsWith('log_'));
      final contents = File(files.single.path).readAsStringSync();
      expect(contents, 'first\nsecond\n');
    });

    test('writes nothing when verbose is off', () async {
      WalletLog.isVerbose = () async => false;
      await FileLogSink().write(LogLevel.error, 'dropped');
      expect(await getLogFiles(), isEmpty);
    });
  });

  test('cleanOldLogFiles removes stale files, keeps recent ones', () async {
    await writeLog('old.txt', modified: DateTime(2000, 1, 1));
    await writeLog('fresh.txt');
    await cleanOldLogFiles();
    final files = await getLogFiles();
    expect(files.map((f) => f.name), ['fresh.txt']);
  });
}
