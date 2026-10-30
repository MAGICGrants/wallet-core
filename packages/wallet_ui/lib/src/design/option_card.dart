import 'package:flutter/material.dart';

import 'brand.dart';

/// Full-width choice card: icon tile + title + description, and a chevron.
///
/// The create/restore layout, shared: an action card is tapped as a whole
/// ([onTap]); a card for something that stays on or off puts its control in
/// [trailing] (a switch) instead of the chevron, and [child] adds what belongs
/// to that choice under a rule (a status line, buttons). A card with
/// [enabled] false is drawn faded and takes no taps.
class OptionCard extends StatelessWidget {
  const OptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.onTap,
    this.trailing,
    this.child,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback? onTap;

  /// In place of the chevron; the chevron shows only on a tappable card.
  final Widget? trailing;
  final Widget? child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final tap = enabled ? onTap : null;
    final end =
        trailing ??
        (tap != null ? Icon(Icons.chevron_right, color: BrandColors.inkFaint, size: 20) : null);
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: BrandColors.card,
        borderRadius: BrandRadii.rField,
        border: Border.all(color: BrandColors.border),
      ),
      child: ClipRRect(
        borderRadius: BrandRadii.rField,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            mouseCursor: tap != null ? WidgetStateMouseCursor.clickable : MouseCursor.defer,
            onTap: tap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: BrandColors.surfaceSunken,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(icon, color: BrandColors.primary, size: 22),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: BrandColors.ink,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(description, style: BrandText.caption),
                          ],
                        ),
                      ),
                      if (end != null) ...[const SizedBox(width: BrandSpacing.sm), end],
                    ],
                  ),
                  if (child != null) ...[
                    const SizedBox(height: 12),
                    Divider(height: 1, thickness: 1, color: BrandColors.border),
                    const SizedBox(height: 12),
                    Padding(padding: const EdgeInsets.only(left: 59), child: child),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (enabled) return card;
    // Faded, and nothing in it answers: not the card, nor its trailing or child.
    return IgnorePointer(child: Opacity(opacity: 0.55, child: card));
  }
}
