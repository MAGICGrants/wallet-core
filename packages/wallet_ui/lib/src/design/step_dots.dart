import 'package:flutter/material.dart';

import 'brand.dart';
import '../l10n/ui_strings.dart';

/// Onboarding progress — the active step is a wider primary pill.
class StepDots extends StatelessWidget {
  final int count;
  final int index;

  const StepDots({super.key, required this.count, required this.index});

  @override
  Widget build(BuildContext context) {
    final label = uiStringsOf(context)?.a11yStepOfCount(index + 1, count);
    return Semantics(
      label: label,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: BrandMotion.transition,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              height: 6,
              width: i == index ? 18 : 6,
              decoration: BoxDecoration(
                color: i == index ? BrandColors.primary : BrandColors.borderStrong,
                borderRadius: BrandRadii.rPill,
              ),
            ),
        ],
      ),
    );
  }
}
