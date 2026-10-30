import 'package:flutter/material.dart';

import 'brand.dart';

/// Amber callout for something the user should know and can act on: a
/// connection that will not be used as set up, a server still waiting to
/// approve the wallet.
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
