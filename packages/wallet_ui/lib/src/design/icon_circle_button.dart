import 'package:flutter/material.dart';

import 'brand.dart';

/// Circular icon button on a light ground with a hairline border — back, close,
/// settings in the top bars.
class IconCircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  /// Visual diameter. The tappable footprint is padded to a 44px minimum.
  final double size;
  final Color? color;

  const IconCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 36,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final target = size < 44 ? 44.0 : size;
    return SizedBox(
      width: target,
      height: target,
      child: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: Material(
            color: color ?? BrandColors.card,
            shape: CircleBorder(side: BorderSide(color: BrandColors.border)),
            child: InkWell(
              onTap: onPressed,
              customBorder: const CircleBorder(),
              child: Icon(icon, size: size * 0.5, color: BrandColors.ink),
            ),
          ),
        ),
      ),
    );
  }
}
