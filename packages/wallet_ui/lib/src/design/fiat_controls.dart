import 'package:flutter/material.dart';

import 'brand.dart';

/// A currency pill — code + its symbol. Primary when selected, tinted otherwise.
class FiatCurrencyChip extends StatelessWidget {
  final String code;
  final String symbol;
  final bool selected;
  final VoidCallback onTap;

  const FiatCurrencyChip({
    super.key,
    required this.code,
    required this.symbol,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected ? BrandColors.onPrimary : BrandColors.ink;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(11),
      side: selected ? BorderSide.none : BorderSide(color: BrandColors.border),
    );
    return Material(
      color: selected ? BrandColors.primary : BrandColors.surfaceSunken,
      shape: shape,
      child: InkWell(
        onTap: onTap,
        customBorder: shape,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                code,
                style: TextStyle(
                  fontFamily: 'Ubuntu Mono',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: fg,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                symbol,
                style: TextStyle(
                  fontFamily: 'Ubuntu Mono',
                  fontSize: 11.5,
                  color: selected
                      ? BrandColors.onPrimary.withValues(alpha: 0.7)
                      : BrandColors.inkFaint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
