import 'package:flutter/widgets.dart';

import 'brand.dart';

/// Shows the pointer (hand) cursor over [child] on desktop and web — the piece a
/// bare [GestureDetector] lacks (unlike [InkWell]). Inert without a mouse, so
/// mobile is unaffected. Use it to wrap a tappable you can't swap for [Tappable].
class ClickCursor extends StatelessWidget {
  final Widget child;

  const ClickCursor({super.key, required this.child});

  @override
  Widget build(BuildContext context) => MouseRegion(cursor: SystemMouseCursors.click, child: child);
}

/// A [GestureDetector] for genuine controls (not full-screen dismiss barriers):
/// it shows the pointer cursor on desktop and web, and it is a control to
/// assistive tech and the keyboard as well as to touch.
///
/// - Screen readers get one node, a button by default, named by the text
///   inside it (or [semanticLabel]) and carrying the state set here.
/// - Tab reaches it while [onTap] is set, and Enter or Space runs [onTap]. A
///   ring marks it only while it has focus from the keyboard, so how it looks
///   to touch and mouse users does not change.
///
/// The cursor only changes while [onTap]/[onLongPress] is set.
class Tappable extends StatefulWidget {
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final HitTestBehavior behavior;
  final MouseCursor? cursor;
  final Widget child;

  /// What a screen reader calls this control, for one with no text of its own
  /// (an icon) or text that does not say what it does. Name the action, never
  /// a secret value.
  final String? semanticLabel;

  /// Reads [semanticLabel] in place of the text inside [child], not after it.
  final bool excludeSemantics;

  /// A switch's on/off state; set, this reads as a switch, not a button.
  final bool? toggled;

  /// A checkbox's state; set, this reads as a checkbox, or as a radio button
  /// with [inMutuallyExclusiveGroup].
  final bool? checked;
  final bool inMutuallyExclusiveGroup;

  /// The current choice of a tab bar, chip row or option list.
  final bool? selected;

  /// Whether the dropdown or panel this opens is open.
  final bool? expanded;

  /// False reads as dimmed (disabled). Null: enabled while [onTap] is set, and
  /// no control at all to assistive tech while it isn't.
  final bool? enabled;

  /// False for a tap target that only passes focus on to a control inside it
  /// that is already focusable and named (a text field's padding): it then
  /// adds no tab stop and no node of its own.
  final bool control;

  /// Corners of the keyboard focus ring; match the control's own shape.
  final BorderRadius focusRadius;

  /// For a caller that moves keyboard focus back to it (a dropdown's trigger
  /// when its list closes).
  final FocusNode? focusNode;

  const Tappable({
    super.key,
    this.onTap,
    this.onLongPress,
    this.behavior = HitTestBehavior.opaque,
    this.cursor,
    this.semanticLabel,
    this.excludeSemantics = false,
    this.toggled,
    this.checked,
    this.inMutuallyExclusiveGroup = false,
    this.selected,
    this.expanded,
    this.enabled,
    this.control = true,
    this.focusRadius = const BorderRadius.all(Radius.circular(10)),
    this.focusNode,
    required this.child,
  });

  @override
  State<Tappable> createState() => _TappableState();
}

class _TappableState extends State<Tappable> {
  bool _ring = false;

  void _activate() => widget.onTap?.call();

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final clickable = w.onTap != null || w.onLongPress != null;
    final enabled = w.enabled ?? clickable;

    // The tree keeps the same shape whatever onTap is, so a field inside keeps
    // its state when the control is switched on or off.
    final Widget body = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: _ring && w.control
          ? BoxDecoration(
              border: Border.all(color: BrandColors.ink, width: 2),
              borderRadius: w.focusRadius,
            )
          : const BoxDecoration(),
      child: GestureDetector(
        behavior: w.behavior,
        onTap: w.onTap,
        onLongPress: w.onLongPress,
        // The Semantics below carries the actions, so a label that replaces
        // the child's text does not drop them.
        excludeFromSemantics: true,
        child: ExcludeSemantics(excluding: w.excludeSemantics, child: w.child),
      ),
    );

    final focusable = FocusableActionDetector(
      focusNode: w.focusNode,
      enabled: w.control && enabled && w.onTap != null,
      mouseCursor: w.cursor ?? (clickable ? SystemMouseCursors.click : MouseCursor.defer),
      includeFocusSemantics: w.control,
      onShowFocusHighlight: (show) {
        if (mounted && show != _ring) setState(() => _ring = show);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _activate()),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(onInvoke: (_) => _activate()),
      },
      child: body,
    );

    if (!w.control) return focusable;

    final role = clickable || w.enabled != null;
    final stated =
        w.toggled != null || w.checked != null || w.selected != null || w.expanded != null;
    if (!role && !stated && w.semanticLabel == null) return focusable;
    return Semantics(
      container: true,
      button: role && w.toggled == null && w.checked == null ? true : null,
      enabled: role ? enabled : null,
      toggled: w.toggled,
      checked: w.checked,
      inMutuallyExclusiveGroup: w.inMutuallyExclusiveGroup ? true : null,
      selected: w.selected,
      expanded: w.expanded,
      label: w.semanticLabel,
      onTap: enabled ? w.onTap : null,
      onLongPress: enabled ? w.onLongPress : null,
      child: focusable,
    );
  }
}
