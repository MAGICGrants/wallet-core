import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:share_plus/share_plus.dart';

import 'logging.dart';
import 'paths.dart';

/// One log file on disk, for the export UI.
class LogFileInfo {
  final String path;
  final String name;
  final DateTime modified;
  final int size;

  LogFileInfo({required this.path, required this.name, required this.modified, required this.size});
}

/// Directory the file log sink writes to: Android's external storage, the app
/// directory everywhere else.
Future<Directory> _logsDir() async {
  final base = await WalletPaths.directories.externalStorage() ?? await getAppDir();
  return Directory('${base.path}/logs');
}

/// Today's log file, one per day. Creates the logs directory if absent.
Future<File> _todaysLogFile() async {
  final dir = await _logsDir();
  if (!await dir.exists()) await dir.create(recursive: true);
  final dateStr = DateTime.now().toIso8601String().split('T').first;
  return File('${dir.path}/log_$dateStr.txt');
}

/// The file half of the shared logger: appends each record to today's log file.
/// Only writes when verbose logging is on, matching the apps' original behaviour
/// (no file at all when the preference is off). Appends are serialized so
/// concurrent [log] calls can't interleave.
class FileLogSink extends LogSink {
  FileLogSink();

  Future<void>? _lastWrite;

  @override
  Future<void> write(LogLevel level, String line) {
    // Chain synchronously (no await before assigning _lastWrite) so ordering is
    // strict; the verbose gate lives inside the queued op.
    _lastWrite = (_lastWrite ?? Future.value()).then((_) async {
      if (!await WalletLog.isVerbose()) return;
      try {
        final file = await _todaysLogFile();
        await file.writeAsString('$line\n', mode: FileMode.append);
      } catch (error) {
        debugPrint('Failed to write log to file: $error');
      }
    });
    return _lastWrite!;
  }
}

/// Deletes log files older than [maxAge]. Best-effort; failures are logged only.
Future<void> cleanOldLogFiles({Duration maxAge = const Duration(days: 30)}) async {
  try {
    final dir = await _logsDir();
    if (!await dir.exists()) return;
    final cutoff = DateTime.now().subtract(maxAge);
    for (final entity in await dir.list().toList()) {
      if (entity is File) {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
          debugPrint('Deleted old log file: ${entity.path}');
        }
      }
    }
  } catch (error) {
    debugPrint('Failed to clean old logs: $error');
  }
}

/// Available log files, newest first. Empty when the logs directory is absent.
Future<List<LogFileInfo>> getLogFiles() async {
  final logsDir = await _logsDir();
  if (!await logsDir.exists()) return [];

  final logFiles = <LogFileInfo>[];
  for (final entity in await logsDir.list().toList()) {
    if (entity is File && entity.path.endsWith('.txt')) {
      final stat = await entity.stat();
      logFiles.add(
        LogFileInfo(
          path: entity.path,
          name: entity.path.split('/').last,
          modified: stat.modified,
          size: stat.size,
        ),
      );
    }
  }

  logFiles.sort((a, b) => b.modified.compareTo(a.modified));
  return logFiles;
}

/// Exports [files] via the system share sheet (iOS/Android). [sharePositionOrigin]
/// anchors the iPad popover; omitting it makes the share throw on iPad, which
/// looks like nothing happening.
Future<void> exportLogFiles(List<LogFileInfo> files, {Rect? sharePositionOrigin}) async {
  if (files.isEmpty) {
    throw Exception('No log files selected');
  }

  final xFiles = files.map((f) => XFile(f.path)).toList();
  await SharePlus.instance.share(
    ShareParams(files: xFiles, sharePositionOrigin: sharePositionOrigin),
  );
}
