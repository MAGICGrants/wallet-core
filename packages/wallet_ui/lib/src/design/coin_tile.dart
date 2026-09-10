import 'package:flutter/material.dart';

/// Rounded-square chain tile holding a white glyph. Radius tracks size (~0.3×),
/// matching the design (40→12, 34→11, 22→7).
class CoinTile extends StatelessWidget {
  final Color color;
  final Widget? glyph;
  final double size;

  const CoinTile({super.key, required this.color, this.glyph, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(size * 0.3)),
      child: glyph,
    );
  }
}
