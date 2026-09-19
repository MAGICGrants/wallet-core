import 'package:flutter/material.dart';

import 'brand.dart';
import 'icon_circle_button.dart';

/// A centered desktop modal: a paper card with a top-right close (X) button
/// stacked over [child]. Used in place of a bottom sheet on desktop, where the X
/// replaces an explicit Cancel/Close button.
class DesktopModalCard extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  /// Uniform padding around [child]. The single lever for every modal's inset —
  /// sheet contents drop their own edge padding on desktop and let this own it.
  final EdgeInsetsGeometry contentPadding;

  const DesktopModalCard({
    super.key,
    required this.child,
    this.maxWidth = 480,
    this.contentPadding = const EdgeInsets.all(26),
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: BrandColors.paper,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Stack(
          children: [
            Padding(padding: contentPadding, child: child),
            Positioned(
              top: 10,
              right: 10,
              child: IconCircleButton(icon: Icons.close, onPressed: () => Navigator.pop(context)),
            ),
          ],
        ),
      ),
    );
  }
}
