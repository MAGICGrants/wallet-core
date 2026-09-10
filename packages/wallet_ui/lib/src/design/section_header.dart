import 'package:flutter/material.dart';

import 'brand.dart';

/// Small-caps, letter-spaced, muted label above a group ("ASSETS", "CONTENTS").
class SectionHeader extends StatelessWidget {
  final String label;
  final EdgeInsetsGeometry padding;

  const SectionHeader({
    super.key,
    required this.label,
    this.padding = const EdgeInsets.only(bottom: BrandSpacing.sm),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(label.toUpperCase(), style: BrandText.section),
    );
  }
}
