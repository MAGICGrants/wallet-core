import 'package:flutter/material.dart';

import 'brand.dart';

/// Large balance with the fraction in a lighter tone ("$99,412.65").
class BalanceText extends StatelessWidget {
  final String whole; // includes any currency symbol, e.g. "$99,412"
  final String fraction; // digits only, e.g. "65"
  final String separator;
  final TextStyle? style;

  const BalanceText({
    super.key,
    required this.whole,
    required this.fraction,
    this.separator = '.',
    this.style,
  });

  /// Splits a formatted amount on its last [separator] ("$99,412.65" / ".").
  factory BalanceText.split(String amount, {String separator = '.', TextStyle? style}) {
    final i = amount.lastIndexOf(separator);
    if (i < 0) return BalanceText(whole: amount, fraction: '', separator: separator, style: style);
    return BalanceText(
      whole: amount.substring(0, i),
      fraction: amount.substring(i + 1),
      separator: separator,
      style: style,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = style ?? BrandText.balance;
    return RichText(
      text: TextSpan(
        style: s,
        children: [
          TextSpan(text: whole),
          if (fraction.isNotEmpty)
            TextSpan(
              text: '$separator$fraction',
              style: s.copyWith(color: BrandColors.inkDisabled),
            ),
        ],
      ),
    );
  }
}
