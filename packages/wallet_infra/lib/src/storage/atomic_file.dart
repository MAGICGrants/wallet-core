import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

// Starts at random: every isolate has its own counter, and two isolates of one
// process (one pid) must not pick the same temporary name.
var _tmpCounter = Random.secure().nextInt(1 << 30);

/// Replaces [file]'s contents with [bytes] so that a crash midway leaves the
/// old file or the new one, never a truncated mix of the two.
///
/// The bytes go to a temporary file beside it, which is flushed to disk and
/// then renamed over [file]: a rename within one directory replaces the file in
/// one step on every platform the apps run on. The temporary name is unique, so
/// two writes of the same file at once each rename a complete file, and the
/// later one wins.
///
/// Not done: syncing the directory after the rename, which Dart cannot do
/// without FFI. After a power cut the file may come back as the old one.
/// A temporary file left by a crash before the rename stays behind (`*.tmp`).
Future<void> writeFileAtomic(File file, List<int> bytes) async {
  final tmp = File('${file.path}.$pid-${_tmpCounter++}.tmp');
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}

/// Deletes the temporary files [writeFileAtomic] left beside [file] when a
/// write of it was cut short (`<name>.<pid>-<n>.tmp`). Each holds an older
/// version of [file], so where that version must stop working (an old copy of
/// a password, say) these have to go with it.
///
/// Only for a file nothing is writing at the time: a write under way has its
/// temporary file deleted under it and fails. Deleting does not reach copies
/// in backups or blocks the disk has not reused. Returns how many were deleted;
/// one that cannot be deleted is left and not counted.
Future<int> deleteAtomicWriteLeftovers(File file) async {
  final dir = file.parent;
  if (!await dir.exists()) return 0;
  final leftover = RegExp('^${RegExp.escape(p.basename(file.path))}\\.\\d+-\\d+\\.tmp\$');
  var deleted = 0;
  await for (final entry in dir.list(followLinks: false)) {
    if (entry is! File || !leftover.hasMatch(p.basename(entry.path))) continue;
    try {
      await entry.delete();
      deleted++;
    } catch (_) {}
  }
  return deleted;
}

/// [writeFileAtomic] for text, as UTF-8.
Future<void> writeStringAtomic(File file, String contents) =>
    writeFileAtomic(file, utf8.encode(contents));
