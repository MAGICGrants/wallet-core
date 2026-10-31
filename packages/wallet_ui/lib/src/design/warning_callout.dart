import 'package:flutter/material.dart';

import 'brand.dart';
import 'brand_card.dart';

/// A page's warning: a card in the warning tint, the warning icon beside its
/// text. The one style for a warning that stands on its own in a screen's
/// content; [WarningCallout] is the compact form, inside a form or a list.
class WarningCard extends StatelessWidget {
  final Widget child;

  const WarningCard({super.key, required this.child});

  /// The usual case: one paragraph of body text.
  WarningCard.text(String message, {super.key}) : child = Text(message, style: BrandText.body);

  @override
  Widget build(BuildContext context) {
    return BrandCard(
      color: BrandColors.warningBg,
      borderColor: BrandColors.warningBg,
      padding: const EdgeInsets.all(BrandSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 19, color: BrandColors.warning),
          const SizedBox(width: BrandSpacing.md),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// Amber callout for something the user should know and can act on: a
/// connection that will not be used as set up, a server still waiting to
/// approve the wallet. Compact, for a note inside a form or a list; a
/// warning standing on its own in a page is a [WarningCard].
class WarningCallout extends StatelessWidget {
  final String message;

  const WarningCallout(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BrandColors.warningBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_rounded, size: 18, color: BrandColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: BrandText.caption.copyWith(color: BrandColors.warning, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
