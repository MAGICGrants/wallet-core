import 'package:flutter/material.dart';

import 'brand.dart';
import 'brand_button.dart';
import 'sheet.dart';

/// A destructive/at-risk confirmation as a brand bottom sheet: a handle, an icon
/// tile + title, a body, then a solid Cancel and a ghost confirm (coloured by
/// [confirmColor], defaulting to error). Used for delete-wallet, the reveal
/// warnings and the Tor-disable warning so every "are you sure?" reads the same.
///
/// Resolves to `true` when the confirm action is tapped, `false` on cancel or
/// dismiss — so callers that need to branch can `await` it. As a convenience for
/// fire-and-forget callers, [onConfirm] (if given) runs after the sheet pops on
/// confirm.
Future<bool> showConfirmSheet({
  required BuildContext context,
  required IconData icon,
  required Color iconBg,
  required Color iconColor,
  required String title,
  required String body,
  required String confirmLabel,
  required String cancelLabel,
  VoidCallback? onConfirm,
  Color? confirmColor,
}) async {
  final confirmed = await showBrandSheet<bool>(
    context: context,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetHandle(),
            Row(
              children: [
                SheetIcon(icon: icon, bg: iconBg, color: iconColor),
                const SizedBox(width: 11),
                Expanded(child: Text(title, style: BrandText.sheetTitle)),
              ],
            ),
            const SizedBox(height: 7),
            Text(body, style: BrandText.bodyMuted.copyWith(fontSize: 13, height: 1.5)),
            const SizedBox(height: 18),
            BrandButton(label: cancelLabel, onPressed: () => Navigator.pop(sheetContext, false)),
            const SizedBox(height: 4),
            BrandButton.ghost(
              label: confirmLabel,
              color: confirmColor ?? BrandColors.error,
              onPressed: () {
                Navigator.pop(sheetContext, true);
                onConfirm?.call();
              },
            ),
          ],
        ),
      ),
    ),
  );
  return confirmed ?? false;
}
