import 'package:flutter/material.dart';

import 'icon_circle_button.dart';
import '../l10n/ui_strings.dart';
import 'step_dots.dart';

/// Standard onboarding/screen header: a back button on the left, a centered
/// element (step dots or a title), and an optional right-hand action — with
/// spacers so the centre stays centred.
class BrandScreenHeader extends StatelessWidget {
  final VoidCallback? onBack;
  final Widget? center;
  final Widget? action;

  /// Leading affordance — a back chevron by default. Override only when a
  /// screen genuinely dismisses rather than navigates back.
  final IconData leadingIcon;

  /// What a screen reader calls the leading button. Defaults to "Back", or
  /// "Close" for [Icons.close].
  final String? leadingLabel;

  const BrandScreenHeader({
    super.key,
    this.onBack,
    this.center,
    this.action,
    this.leadingIcon = Icons.chevron_left,
    this.leadingLabel,
  });

  @override
  Widget build(BuildContext context) {
    final strings = uiStringsOf(context);
    final backLabel = leadingLabel ?? (leadingIcon == Icons.close ? strings?.close : strings?.back);
    // The centre is the screen's title, so it is its heading and the name
    // screen readers give the screen; step dots name only the step.
    final title = center == null || center is StepDots
        ? center
        : Semantics(header: true, namesRoute: true, child: center);
    // Stack (not Row) so the centre stays at the true middle of the width,
    // regardless of the side elements' sizes.
    return SizedBox(
      height: 44,
      child: Stack(
        children: [
          if (title != null) Center(child: title),
          if (onBack != null)
            Align(
              alignment: Alignment.centerLeft,
              child: IconCircleButton(
                icon: leadingIcon,
                onPressed: onBack,
                semanticLabel: backLabel,
              ),
            ),
          if (action != null) Align(alignment: Alignment.centerRight, child: action),
        ],
      ),
    );
  }
}
