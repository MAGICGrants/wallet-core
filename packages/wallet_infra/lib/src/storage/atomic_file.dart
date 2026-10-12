import 'dart:convert';
import 'dart:io';

var _tmpCounter = 0;

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

/// [writeFileAtomic] for text, as UTF-8.
Future<void> writeStringAtomic(File file, String contents) =>
    writeFileAtomic(file, utf8.encode(contents));
