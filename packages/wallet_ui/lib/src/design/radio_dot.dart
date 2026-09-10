import 'package:flutter/material.dart';

import 'brand.dart';

/// Selection indicator for radio cards — a filled primary circle with a white
/// check when selected, a hollow ring when not.
class RadioDot extends StatelessWidget {
  final bool selected;
  final double size;

  const RadioDot({super.key, required this.selected, this.size = 22});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? BrandColors.primary : BrandColors.card,
        shape: BoxShape.circle,
        border: selected ? null : Border.all(color: BrandColors.inkDisabled, width: 1.6),
      ),
      child: selected ? Icon(Icons.check, size: size * 0.64, color: BrandColors.onPrimary) : null,
    );
  }
}
