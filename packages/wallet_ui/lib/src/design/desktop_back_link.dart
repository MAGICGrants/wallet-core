import 'package:flutter/material.dart';

import 'brand.dart';

/// Shared style for a desktop screen's large title (Settings, Contacts, …).
TextStyle get desktopTitleStyle => TextStyle(
  fontFamily: 'Ubuntu',
  fontSize: 26,
  height: 1.2,
  fontWeight: FontWeight.w700,
  color: BrandColors.ink,
);

/// The "‹ label" back link at the top of a desktop sub-screen (receive, send,
/// ToS, …) — the shared back affordance in place of a mobile app bar.
class DesktopBackLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const DesktopBackLink({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Sized to its content (left-aligned) so the hover/ripple doesn't span the
    // full parent width; a little right padding keeps the ripple off the label.
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 4, 4, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chevron_left, size: 18, color: BrandColors.primary),
              const SizedBox(width: 2),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Ubuntu',
                  fontSize: 12.5,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  color: BrandColors.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
