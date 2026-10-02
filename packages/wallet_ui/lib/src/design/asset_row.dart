import 'package:flutter/material.dart';

import 'brand.dart';

/// A list row: leading icon, title (+ optional subtitle), trailing widget or a
/// chevron. Used for the asset list, settings, contacts.
class AssetRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final TextStyle? subtitleStyle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  /// When true, the row is its own white card with a thin border (the asset /
  /// chain list). Otherwise it's a bare row (activity feed, settings groups).
  final bool card;

  const AssetRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.subtitleStyle,
    this.trailing,
    this.onTap,
    this.card = false,
    this.padding = const EdgeInsets.symmetric(vertical: 14, horizontal: BrandSpacing.lg),
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: padding,
      child: Row(
        children: [
          leading,
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: BrandText.listTitle),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: subtitleStyle ?? BrandText.caption),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: BrandSpacing.sm), trailing!],
        ],
      ),
    );
    final radius = card ? BrandRadii.rField : BrandRadii.rCard;
    Widget content = row;
    if (onTap != null) {
      content = ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(mouseCursor: WidgetStateMouseCursor.clickable, onTap: onTap, child: row),
        ),
      );
    }
    if (!card) return content;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: BrandColors.card,
        borderRadius: radius,
        border: Border.all(color: BrandColors.border),
      ),
      child: content,
    );
  }
}
