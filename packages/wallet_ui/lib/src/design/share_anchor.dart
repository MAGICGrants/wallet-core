import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart' show LogLevel, log;

/// The rect of [context]'s widget in global coordinates -- the anchor a share
/// sheet is opened from -- or null when it cannot be measured.
///
/// iOS presents the share sheet as a popover that has to point at the control
/// the user tapped, so share_plus rejects a share whose `sharePositionOrigin`
/// is missing or empty. On a fire-and-forget share that rejection is invisible:
/// the future nobody awaits carries the error away and the button appears to do
/// nothing. Measure the tapped control and pass the result along.
///
/// Every failure yields null rather than throwing, because an unanchored share
/// still works on Android and on iPhone -- losing the measurement must not cost
/// the user the share. `findRenderObject()` throws, rather than returning null,
/// when the element is gone or has not been laid out.
Rect? shareAnchorRect(BuildContext context) {
  try {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  } catch (error) {
    log(LogLevel.warn, 'Could not anchor the share sheet: $error');
    return null;
  }
}
