import 'package:flutter/material.dart';

import 'brand.dart';

/// Small tan icon+label pill (Paste / Scan / Contacts). [bordered] adds a
/// hairline + slightly rounder corners (contact sheet); the plain variant is
/// used on the send screen's To card. Wrap in [Expanded] to fill a row.
class MiniActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool bordered;

  /// Fill color; defaults to [defaultFill] (or the tan sunken surface).
  final Color? color;

  /// App-wide default fill, resolved live each build so it tracks dark mode.
  /// Set once from the app's `main()` (e.g. `() => BrandColors.orangeBg`);
  /// null falls back to the sunken surface. Per-instance [color] still wins.
  static Color Function()? defaultFill;

  const MiniActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.bordered = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: color ?? defaultFill?.call() ?? BrandColors.surfaceSunken,
          border: bordered ? Border.all(color: BrandColors.border) : null,
          borderRadius: BorderRadius.circular(bordered ? 12 : 10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: BrandColors.primaryDeep),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: BrandColors.primaryDeep,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
