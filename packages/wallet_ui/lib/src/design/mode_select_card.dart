import 'package:flutter/material.dart';

import 'brand.dart';
import 'click_cursor.dart';
import 'radio_dot.dart';

/// A selectable radio card — title + description with a radio dot. Selected pops
/// white with a 2px primary border; the rest recede on a tinted fill. The dot
/// sits on the right by default ([radioLeading] moves it to the left); [expanded]
/// reveals extra controls below the row while selected.
class ModeSelectCard extends StatelessWidget {
  final String title;
  final String description;
  final bool selected;
  final VoidCallback onTap;
  final bool radioLeading;
  final Widget? expanded;

  /// Optional leading widget (e.g. a theme preview swatch) shown before the text.
  final Widget? leading;

  const ModeSelectCard({
    super.key,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
    this.radioLeading = false,
    this.expanded,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final text = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: BrandText.listTitle),
          const SizedBox(height: 3),
          Text(description, style: BrandText.caption),
        ],
      ),
    );
    final dot = RadioDot(selected: selected);

    return Tappable(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: BrandMotion.transition,
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? BrandColors.card : BrandColors.surfaceSunken,
          borderRadius: BrandRadii.rField,
        ),
        // foregroundDecoration paints the border over the content, so growing it
        // to 2px on select doesn't inset/shift the content (CSS border-box).
        foregroundDecoration: BoxDecoration(
          borderRadius: BrandRadii.rField,
          border: Border.all(
            color: selected ? BrandColors.primary : BrandColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (radioLeading) ...[dot, const SizedBox(width: 13)],
                if (leading != null) ...[leading!, const SizedBox(width: 13)],
                text,
                if (!radioLeading) ...[const SizedBox(width: 13), dot],
              ],
            ),
            if (selected && expanded != null) ...[const SizedBox(height: 14), expanded!],
          ],
        ),
      ),
    );
  }
}
