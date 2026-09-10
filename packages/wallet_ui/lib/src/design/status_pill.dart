import 'package:flutter/material.dart';

import 'brand.dart';

/// Coloured dot + label — connection/sync status ("Internal Tor · LWS").
class StatusPill extends StatelessWidget {
  final String label;
  final Color? color;

  const StatusPill({super.key, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color ?? BrandColors.success, shape: BoxShape.circle),
        ),
        const SizedBox(width: BrandSpacing.sm),
        Text(label, style: BrandText.caption.copyWith(color: BrandColors.ink)),
      ],
    );
  }
}
