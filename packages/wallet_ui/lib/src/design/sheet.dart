import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'brand.dart';
import 'desktop_modal.dart';

/// Presents a brand-styled modal bottom sheet (paper ground, rounded top,
/// capped width). Use [SheetHandle]/[SheetIcon] inside for the grabber/title.
///
/// The paper background is drawn *inside* the builder content (not via the
/// modal's `backgroundColor`, which is captured once at open) so it repaints
/// when the theme changes while the sheet is open.
///
/// **This owns the keyboard inset. A [builder] must not add its own.** The
/// padding below lifts the whole sheet clear of the keyboard; a second
/// `viewInsets.bottom` inside the content lifts it by twice the keyboard
/// height, which leaves a keyboard-sized void under the sheet and pushes its
/// top off the screen. Content that needs to know the keyboard is up should
/// read `viewInsets.bottom` to *size* itself (see [maxSheetHeight]), never to
/// pad itself again.
Future<T?> showBrandSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  double maxWidth = 520,
}) {
  // Desktop has no bottom sheets: present the same content as a centered modal
  // with a top-right close button (the SheetHandle hides itself there).
  // [DesktopModalCard] owns the uniform edge padding; sheet contents drop their
  // own (see [isDesktopModal]) so it isn't doubled.
  if (isDesktopModal) {
    return showDialog<T>(
      context: context,
      builder: (context) => DesktopModalCard(maxWidth: maxWidth, child: builder(context)),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    // Without this a scroll-controlled sheet is free to grow under the status
    // bar and the notch, which is where a too-tall sheet ends up rather than
    // being capped.
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints(maxWidth: maxWidth),
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: BrandColors.paper,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: BrandShadows.sheet,
        ),
        child: builder(context),
      ),
    ),
  );
}

/// Test seam for [isDesktopModal]; null uses the real host platform.
@visibleForTesting
bool? debugIsDesktopModalOverride;

/// True on desktop, where a sheet is a centered [DesktopModalCard] that owns the
/// content padding. Sheet contents use this to drop their own edge padding there
/// (mobile keeps it, so mobile layout is unchanged).
bool get isDesktopModal =>
    debugIsDesktopModalOverride ?? (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

/// A sheet's primary + secondary action buttons. Stacked (primary above
/// secondary) on a mobile sheet; side by side (secondary left, primary right) in
/// a desktop modal. Buttons fill their slot, so pass plain [BrandButton]s.
class SheetActions extends StatelessWidget {
  final Widget primary;
  final Widget secondary;

  /// Vertical gap between the stacked buttons on mobile.
  final double gap;

  const SheetActions({super.key, required this.primary, required this.secondary, this.gap = 2});

  @override
  Widget build(BuildContext context) {
    if (isDesktopModal) {
      return Row(
        children: [
          Expanded(child: secondary),
          const SizedBox(width: 10),
          Expanded(child: primary),
        ],
      );
    }
    return Column(
      children: [
        primary,
        SizedBox(height: gap),
        secondary,
      ],
    );
  }
}

/// The tallest a sheet's content may be: [fraction] of the space above the
/// keyboard.
///
/// A sheet that caps its own height has to measure against the space that is
/// actually free. `size.height` is the whole screen, keyboard included, so a
/// fraction of *that* plus [showBrandSheet]'s keyboard inset comes out taller
/// than the screen and the top of the sheet goes off it.
///
/// The top safe area needs no term here: [showBrandSheet] passes
/// `useSafeArea: true`, so the constraints handed to the content already
/// exclude it. (Inside a modal sheet both `padding.top` and `viewPadding.top`
/// read zero, so subtracting them would be a no-op that only looked careful.)
double maxSheetHeight(BuildContext context, {double fraction = 0.88}) {
  final mq = MediaQuery.of(context);
  return (mq.size.height - mq.viewInsets.bottom) * fraction;
}

/// The little drag grabber at the top of a sheet.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    // No drag grabber in a desktop modal.
    if (isDesktopModal) return const SizedBox.shrink();
    return Center(
      child: Container(
        width: 38,
        height: 5,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: BrandColors.borderStrong,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}

/// Rounded icon tile used next to a sheet/dialog title.
class SheetIcon extends StatelessWidget {
  final IconData icon;
  final Color bg;
  final Color color;

  const SheetIcon({super.key, required this.icon, required this.bg, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(11)),
      child: Icon(icon, size: 18, color: color),
    );
  }
}
