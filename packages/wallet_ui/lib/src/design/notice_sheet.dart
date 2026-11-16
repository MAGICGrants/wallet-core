import 'package:flutter/material.dart';

import 'brand.dart';
import 'brand_button.dart';
import 'sheet.dart';

/// A message with nothing to decide, as a brand bottom sheet: a handle, an icon
/// tile + title, a body, then one button that closes it. The same chrome as
/// [showConfirmSheet], for the "this happened" cases a dialog used to carry; on
/// desktop it is the usual centered modal.
Future<void> showNoticeSheet({
  required BuildContext context,
  required IconData icon,
  required String title,
  required String body,
  required String closeLabel,
  Color? iconBg,
  Color? iconColor,
}) {
  return showBrandSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      top: false,
      // Desktop modal: the card owns the edge padding.
      child: Padding(
        padding: isDesktopModal ? EdgeInsets.zero : const EdgeInsets.fromLTRB(22, 8, 22, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetHandle(),
            Row(
              children: [
                SheetIcon(
                  icon: icon,
                  bg: iconBg ?? BrandColors.surfaceAccent,
                  color: iconColor ?? BrandColors.primary,
                ),
                const SizedBox(width: 11),
                // The sheet's heading, and the name screen readers give it.
                Expanded(
                  child: Semantics(
                    container: true,
                    header: true,
                    namesRoute: true,
                    child: Text(title, style: BrandText.sheetTitle),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            // What happened, spoken as the sheet opens: a sheet's title alone is
            // not read until the user moves to it.
            Semantics(
              container: true,
              liveRegion: true,
              child: Text(body, style: BrandText.bodyMuted.copyWith(fontSize: 13, height: 1.5)),
            ),
            const SizedBox(height: 18),
            BrandButton(label: closeLabel, onPressed: () => Navigator.pop(sheetContext)),
          ],
        ),
      ),
    ),
  );
}
