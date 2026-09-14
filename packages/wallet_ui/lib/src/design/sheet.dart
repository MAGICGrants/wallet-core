import 'package:flutter/material.dart';

import 'brand.dart';

/// Presents a brand-styled modal bottom sheet (paper ground, rounded top,
/// capped width). Use [SheetHandle]/[SheetIcon] inside for the grabber/title.
///
/// The paper background is drawn *inside* the builder content (not via the
/// modal's `backgroundColor`, which is captured once at open) so it repaints
/// when the theme changes while the sheet is open.
Future<T?> showBrandSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 520),
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

/// The little drag grabber at the top of a sheet.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
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
