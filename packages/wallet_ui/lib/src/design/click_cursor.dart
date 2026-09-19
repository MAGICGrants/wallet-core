import 'package:flutter/widgets.dart';

/// Shows the pointer (hand) cursor over [child] on desktop and web — the piece a
/// bare [GestureDetector] lacks (unlike [InkWell]). Inert without a mouse, so
/// mobile is unaffected. Use it to wrap a tappable you can't swap for [Tappable].
class ClickCursor extends StatelessWidget {
  final Widget child;

  const ClickCursor({super.key, required this.child});

  @override
  Widget build(BuildContext context) => MouseRegion(cursor: SystemMouseCursors.click, child: child);
}

/// A [GestureDetector] that also shows the pointer cursor on desktop/web. Drop-in
/// for `GestureDetector(onTap:, child:)` on genuine controls (not full-screen
/// dismiss barriers, where a hand cursor over everything would be wrong). The
/// cursor only changes while [onTap]/[onLongPress] is set.
class Tappable extends StatelessWidget {
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final HitTestBehavior behavior;
  final Widget child;

  const Tappable({
    super.key,
    this.onTap,
    this.onLongPress,
    this.behavior = HitTestBehavior.opaque,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final clickable = onTap != null || onLongPress != null;
    return MouseRegion(
      cursor: clickable ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        behavior: behavior,
        onTap: onTap,
        onLongPress: onLongPress,
        child: child,
      ),
    );
  }
}
