import 'package:flutter/material.dart';

import 'brand.dart';

/// Cream tile with a stacked icon + label — the Receive/Send/Swap row.
class ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// Tile fill; defaults to the cream/sunken surface.
  final Color? color;

  const ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color ?? BrandColors.surfaceSunken,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: BrandColors.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
              onTap: onPressed,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 13),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 19, color: BrandColors.primaryDeep),
                    const SizedBox(height: 7),
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
            ),
          ),
        ),
      ),
    );
  }
}
