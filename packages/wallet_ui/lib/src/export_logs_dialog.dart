import 'package:flutter/material.dart';

import 'package:wallet_infra/wallet_infra.dart' show LogFileInfo, LogLevel, exportLogFiles, log;

import 'design/brand.dart';
import 'design/brand_button.dart';
import 'design/share_anchor.dart';
import 'design/sheet.dart';
import 'design/toast.dart';

/// Translated strings for [ExportLogsDialog]. The app builds this from its own
/// l10n and passes it in; the package carries no localization of its own.
class ExportLogsLabels {
  final String title;
  final String cancel;

  /// Shown when the export itself fails. Not the "no logs to export" message --
  /// this dialog only opens with files to show, and saying the list is empty
  /// while the user is looking at it explains nothing.
  final String exportError;

  const ExportLogsLabels({required this.title, required this.cancel, required this.exportError});
}

/// Lists the app's log files in a brand sheet (a centered modal on desktop);
/// tapping one shares it via the system share sheet.
class ExportLogsDialog {
  static void show(BuildContext context, List<LogFileInfo> logFiles, ExportLogsLabels labels) {
    showBrandSheet<void>(
      context: context,
      builder: (sheetContext) {
        // Desktop modal: the card owns the edge padding.
        final hpad = isDesktopModal ? 0.0 : 22.0;
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxSheetHeight(sheetContext)),
            child: Padding(
              padding: EdgeInsets.only(top: isDesktopModal ? 0 : 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SheetHandle(),
                  Padding(
                    padding: EdgeInsets.fromLTRB(hpad, 0, hpad, 6),
                    child: Row(
                      children: [
                        SheetIcon(
                          icon: Icons.description_outlined,
                          bg: BrandColors.surfaceAccent,
                          color: BrandColors.primary,
                        ),
                        const SizedBox(width: 11),
                        Expanded(child: Text(labels.title, style: BrandText.sheetTitle)),
                      ],
                    ),
                  ),
                  Flexible(child: _list(logFiles, labels, hpad)),
                  Padding(
                    padding: EdgeInsets.fromLTRB(hpad, 12, hpad, isDesktopModal ? 0 : 12),
                    child: BrandButton(
                      label: labels.cancel,
                      onPressed: () => Navigator.of(sheetContext).pop(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static Widget _list(
    List<LogFileInfo> logFiles,
    ExportLogsLabels labels,
    double hpad,
  ) => ListView.builder(
    shrinkWrap: true,
    padding: EdgeInsets.symmetric(horizontal: hpad),
    itemCount: logFiles.length,
    itemBuilder: (context, index) {
      final file = logFiles[index];
      final dateStr =
          '${file.modified.year}-${file.modified.month.toString().padLeft(2, '0')}-${file.modified.day.toString().padLeft(2, '0')}';
      final sizeKb = (file.size / 1024).toStringAsFixed(1);

      // The `Builder` is what makes the tile measurable. An
      // itemBuilder's context is the *sliver's*, not the row's, so
      // `findRenderObject()` on it yields a RenderSliverList and
      // [shareAnchorRect] gives back null -- which iOS then rejects the
      // share over, since it has nothing to anchor the popover to.
      return Builder(
        builder: (context) => ListTile(
          contentPadding: EdgeInsets.zero,
          onTap: () async {
            // Captured before the pop: this tile's context is defunct
            // afterward. The rect anchors the iOS share popover.
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
        ),
      );
    },
  );
}
