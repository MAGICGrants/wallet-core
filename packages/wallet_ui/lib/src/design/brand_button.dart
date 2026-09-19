import 'package:flutter/material.dart';

import 'brand.dart';

/// - filled: primary fill, white label (primary CTA)
/// - outline: transparent, accent border + label
/// - secondary: sunken tan fill + hairline, accent label
/// - ghost: transparent, no border, accent label
enum BrandButtonVariant { filled, outline, secondary, ghost }

/// Brand button. The accent defaults to the brand primary; pass [color] to
/// recolour (e.g. `BrandColors.error` for a destructive action). [dense] is the
/// compact size used for inline pills.
class BrandButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final BrandButtonVariant variant;
  final IconData? icon;
  final bool iconTrailing;
  final bool expand;
  final bool loading;
  final Color? color;

  /// Overrides just the border colour (outline/secondary), letting it differ
  /// from the label [color] — e.g. a neutral cancel: muted label, hairline edge.
  final Color? borderColor;
  final bool dense;

  const BrandButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = BrandButtonVariant.filled,
    this.icon,
    this.iconTrailing = false,
    this.expand = true,
    this.loading = false,
    this.color,
    this.borderColor,
    this.dense = false,
  });

  const BrandButton.outline({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.iconTrailing = false,
    this.expand = true,
    this.loading = false,
    this.color,
    this.borderColor,
    this.dense = false,
  }) : variant = BrandButtonVariant.outline;

  const BrandButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.iconTrailing = false,
    this.expand = true,
    this.loading = false,
    this.color,
    this.borderColor,
    this.dense = false,
  }) : variant = BrandButtonVariant.secondary;

  const BrandButton.ghost({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.iconTrailing = false,
    this.expand = true,
    this.loading = false,
    this.color,
    this.borderColor,
    this.dense = false,
  }) : variant = BrandButtonVariant.ghost;

  @override
  Widget build(BuildContext context) {
    // `loading` keeps the enabled look but blocks taps and shows a spinner.
    final active = onPressed != null || loading;
    final interactive = onPressed != null && !loading;
    // Primary (filled/outline) uses primary; secondary/ghost use the quieter
    // primaryDeep. `color` overrides both (e.g. error for destructive).
    final primary = variant == BrandButtonVariant.filled || variant == BrandButtonVariant.outline;
    final accent = color ?? (primary ? BrandColors.primary : BrandColors.primaryDeep);

    late final Color bg;
    late final Color fg;
    late BorderSide side;
    switch (variant) {
      case BrandButtonVariant.filled:
        bg = active ? accent : BrandColors.surfaceMuted;
        fg = active ? BrandColors.onPrimary : BrandColors.inkDisabled;
        side = BorderSide.none;
      case BrandButtonVariant.outline:
        bg = Colors.transparent;
        fg = active ? accent : BrandColors.inkDisabled;
        side = BorderSide(color: active ? accent : BrandColors.borderStrong);
      case BrandButtonVariant.secondary:
        bg = BrandColors.surfaceSunken;
        fg = active ? accent : BrandColors.inkDisabled;
        side = BorderSide(color: BrandColors.borderStrong);
      case BrandButtonVariant.ghost:
        bg = Colors.transparent;
        fg = active ? accent : BrandColors.inkDisabled;
        side = BorderSide.none;
    }
    if (borderColor != null && side != BorderSide.none) {
      side = BorderSide(color: borderColor!);
    }

    final labelStyle = dense
        ? TextStyle(fontSize: 13.5, height: 1, fontWeight: FontWeight.w500, color: fg)
        : BrandText.buttonLabel.copyWith(color: fg);

    final child = loading
        ? SizedBox(
            height: dense ? 16 : 20,
            width: dense ? 16 : 20,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null && !iconTrailing) ...[
                Icon(icon, size: dense ? 15 : 18, color: fg),
                SizedBox(width: dense ? 6 : BrandSpacing.sm),
              ],
              Text(label, style: labelStyle),
              if (icon != null && iconTrailing) ...[
                SizedBox(width: dense ? 6 : BrandSpacing.sm),
                Icon(icon, size: dense ? 15 : 18, color: fg),
              ],
            ],
          );

    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(dense ? 12 : BrandRadii.button),
      side: side,
    );
    final button = Material(
      color: bg,
      shape: shape,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: interactive ? onPressed : null,
        customBorder: shape,
        child: Padding(
          padding: dense
              ? const EdgeInsets.symmetric(vertical: 11, horizontal: 14)
              : const EdgeInsets.symmetric(vertical: 17, horizontal: BrandSpacing.lg),
          child: Center(widthFactor: expand ? null : 1, child: child),
        ),
      ),
    );

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
