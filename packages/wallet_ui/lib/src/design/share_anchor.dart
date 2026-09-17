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
/// Every failure yields null rather than throwing -- a throw inside a tap
/// handler costs the user the whole interaction, and `findRenderObject()`
/// throws, rather than returning null, when the element is gone or has not been
/// laid out. But treat a null as a bug to fix, not a tolerable outcome: iOS
/// refuses the share outright without an anchor, so the caller gets an error
/// instead of a share sheet.
///
/// Pass the context of the widget the user tapped. A `ListView.builder`'s
/// `itemBuilder` context is the *sliver's*, not the row's, and resolves to a
/// `RenderSliverList` -- wrap the row in a [Builder] and measure that instead.
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
