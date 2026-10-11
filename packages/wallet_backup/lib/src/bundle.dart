import 'dart:typed_data';

import 'padding.dart';

/// The single-file export: every sealed file of one backup, one after the
/// other, for saving anywhere a file can go (Proton Drive, Files, a USB stick)
/// and importing on restore.
///
/// ```
/// bundle = (length (u32, big-endian) ‖ sealed file)*
/// ```
///
/// No names (each file's name is recomputed from its content after opening) and
/// no magic number. Each entry is an ordinary sealed file with its own visible
/// header; the bundle adds nothing a reader has to trust.
abstract final class BackupBundle {
  /// [files] in a fixed order, so exporting the same backup twice gives the
  /// same bytes.
  static Uint8List encode(Iterable<Uint8List> files) {
    final sorted = files.toList()..sort(_compare);
    final out = BytesBuilder(copy: false);
    for (final f in sorted) {
      out.add(Uint8List(4)..buffer.asByteData().setUint32(0, f.length, Endian.big));
      out.add(f);
    }
    return out.takeBytes();
  }

  /// The files in [bundle]. Throws [FormatException] if it is not a bundle.
  static List<Uint8List> decode(Uint8List bundle) {
    final out = <Uint8List>[];
    var pos = 0;
    final data = ByteData.sublistView(bundle);
    while (pos < bundle.length) {
      if (bundle.length - pos < 4) throw const FormatException('truncated bundle');
      final len = data.getUint32(pos, Endian.big);
      pos += 4;
      if (len == 0 || len > maxFileSize || len > bundle.length - pos) {
        throw const FormatException('not a backup file');
      }
      out.add(Uint8List.fromList(Uint8List.sublistView(bundle, pos, pos + len)));
      pos += len;
    }
    return out;
  }

  static int _compare(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
