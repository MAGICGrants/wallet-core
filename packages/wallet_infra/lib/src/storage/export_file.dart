import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Saves [bytes] as a file named [name] wherever the user chooses: on a phone
/// through the share sheet (Files, a cloud drive, a mail draft), on a desktop
/// OS through a save dialog. Returns false when the user cancelled.
///
/// [typeLabel], [extension] and [mimeType] describe the file to the dialog and
/// the share sheet. [sharePositionOrigin] anchors the iPad popover; without
/// it, sharing throws on an iPad.
///
/// On a phone the file is written to the app's temporary folder for the share
/// sheet, then deleted.
Future<bool> saveExportFile({
  required String name,
  required List<int> bytes,
  required String typeLabel,
  required String extension,
  required String mimeType,
  Rect? sharePositionOrigin,
}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await (await getTemporaryDirectory()).createTemp('export');
    final file = File('${dir.path}/$name');
    try {
      await file.writeAsBytes(bytes, flush: true);
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: mimeType)],
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
      return result.status != ShareResultStatus.dismissed;
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  final location = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: [
      XTypeGroup(label: typeLabel, extensions: [extension], mimeTypes: [mimeType]),
    ],
  );
  if (location == null) return false;
  await File(location.path).writeAsBytes(bytes, flush: true);
  return true;
}

/// A file name for an export: [stem] and the local date,
/// `skylight-history-20261017.csv`.
String exportFileName(String stem, String extension, DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '$stem-${now.year}${two(now.month)}${two(now.day)}.$extension';
}
