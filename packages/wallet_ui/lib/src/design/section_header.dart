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
      // A heading for screen readers, read as written: shown upper-cased, a
      // short word can be spelled out letter by letter.
      // Its own node, so a header inside a card does not take in the text
      // around it.
      child: Semantics(
        container: true,
        header: true,
        label: label,
        child: ExcludeSemantics(child: Text(label.toUpperCase(), style: BrandText.section)),
      ),
    );
  }
}
