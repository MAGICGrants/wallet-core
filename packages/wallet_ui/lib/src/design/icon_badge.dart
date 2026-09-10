import 'package:flutter/material.dart';

import 'brand.dart';

/// Circular cream badge with a coloured icon — the leading glyph on activity
/// rows (received/sent/bridged).
class IconBadge extends StatelessWidget {
  final IconData icon;
  final Color? color;
  final double size;

  const IconBadge({super.key, required this.icon, this.color, this.size = 32});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: BrandColors.surfaceSunken, shape: BoxShape.circle),
      child: Icon(icon, size: size * 0.47, color: color ?? BrandColors.primaryDeep),
    );
  }
}
