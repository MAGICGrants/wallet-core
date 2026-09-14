import 'package:flutter/material.dart';

import 'package:wallet_infra/wallet_infra.dart' show LogFileInfo, LogLevel, exportLogFiles, log;

import 'design/share_anchor.dart';
import 'design/toast.dart';

/// Translated strings for [ExportLogsDialog]. The app builds this from its own
/// l10n and passes it in; the package carries no localization of its own.
class ExportLogsLabels {
  final String title;
  final String cancel;
  final String exportError;

  const ExportLogsLabels({required this.title, required this.cancel, required this.exportError});
}

/// Lists the app's log files; tapping one shares it via the system share sheet.
class ExportLogsDialog {
  static void show(BuildContext context, List<LogFileInfo> logFiles, ExportLogsLabels labels) {
    final screenWidth = MediaQuery.of(context).size.width;
    final dialogWidth = screenWidth.clamp(0.0, 500.0);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        constraints: BoxConstraints.tightFor(width: dialogWidth),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 24.0),
        title: Text(labels.title),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.builder(
            itemCount: logFiles.length,
            itemBuilder: (context, index) {
              final file = logFiles[index];
              final dateStr =
                  '${file.modified.year}-${file.modified.month.toString().padLeft(2, '0')}-${file.modified.day.toString().padLeft(2, '0')}';
              final sizeKb = (file.size / 1024).toStringAsFixed(1);

              return ListTile(
                onTap: () async {
                  // Captured before the pop: this tile's context is defunct
                  // afterward. The rect anchors the iPad share popover.
                  final toast = BrandToast.of(context);
                  final origin = shareAnchorRect(context);

                  // Unconditionally, and before anything that can fail. An
                  // exception raised while still inside this handler used to
                  // leave the dialog open with the tap doing nothing at all --
                  // no close, no share, no message.
                  Navigator.of(context).pop();

                  try {
                    await exportLogFiles([file], sharePositionOrigin: origin);
                  } catch (error) {
                    // Recorded, not swallowed. `catch (_)` here discarded the
                    // one explanation for a failure in the very feature whose
                    // job is to hand over the logs.
                    log(LogLevel.error, 'Log export failed: $error');
                    toast.show(labels.exportError);
                  }
                },
                leading: const Icon(Icons.description_outlined),
                title: Text(file.name),
                subtitle: Text('$dateStr • $sizeKb KB'),
                trailing: const Icon(Icons.ios_share),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(labels.cancel)),
        ],
      ),
    );
  }
}
