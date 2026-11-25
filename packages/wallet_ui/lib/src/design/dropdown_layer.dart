import 'package:flutter/widgets.dart';

import '../l10n/ui_strings.dart';
import 'escape_closes.dart';

/// The open list of an anchored dropdown, for an [OverlayPortal]'s
/// `overlayChildBuilder`: a tap-outside barrier under [menu], which the caller
/// positions (a `CompositedTransformFollower`). Drawn as before; what it adds:
///
/// - Esc closes it ([EscapeCloses]).
/// - Screen readers get the list and, for the rest of the screen, one "Close"
///   action: the list drawn over the page is not read after the whole page.
/// - [takeFocus], for a list opened from the keyboard: focus moves to its first
///   option and Tab stays in the list. A list opened by mouse or touch leaves
///   focus where it was, so nothing new is highlighted.
///
/// The barrier and list go into an overlay entry of their own, as a dialog's
/// do: hiding the page from screen readers ([BlockSemantics]) only reaches
/// what an entry below it draws, not the page an [OverlayPortal] child is
/// part of. The portal itself draws nothing.
class DropdownLayer extends StatefulWidget {
  final VoidCallback onClose;
  final bool takeFocus;
  final Widget menu;

  const DropdownLayer({
    super.key,
    required this.onClose,
    required this.menu,
    this.takeFocus = false,
  });

  @override
  State<DropdownLayer> createState() => _DropdownLayerState();
}

class _DropdownLayerState extends State<DropdownLayer> {
  final _scope = FocusScopeNode(debugLabel: 'DropdownLayer');
  OverlayEntry? _entry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _entry = OverlayEntry(builder: _layer);
      Overlay.of(context).insert(_entry!);
      if (widget.takeFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scope.requestFocus();
          _scope.nextFocus();
        });
      }
    });
  }

  @override
  void didUpdateWidget(DropdownLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The list shows what the page passes in now (the selected option).
    WidgetsBinding.instance.addPostFrameCallback((_) => _entry?.markNeedsBuild());
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry?.dispose();
    _scope.dispose();
    super.dispose();
  }

  Widget _layer(BuildContext context) {
    return EscapeCloses(
      onClose: widget.onClose,
      // Around the whole layer and with no semantics of its own, so it adds no
      // render box: the list's CompositedTransformFollower must be the Stack's
      // own child, or taps on it are tested against where it would sit
      // unmoved, miss, and land on the barrier.
      child: FocusScope(
        node: _scope,
        includeSemantics: false,
        child: Stack(
          children: [
            Positioned.fill(
              // Hides the page from screen readers while the list is open, and
              // stands in for it as "Close".
              child: BlockSemantics(
                child: Semantics(
                  label: uiStringsOf(context)?.close,
                  onTap: widget.onClose,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onClose,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ),
            widget.menu,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
