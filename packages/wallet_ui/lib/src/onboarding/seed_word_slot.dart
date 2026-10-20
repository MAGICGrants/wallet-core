import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/click_cursor.dart';

/// One numbered seed-word field, as the restore screen shows it: the word's
/// position on the left, the word on the right, a red outline once a word
/// fails [validate] and the slot is left.
///
/// Self-managing: it listens to its own controller/focus and rebuilds only
/// itself, so typing in one slot never rebuilds the others.
class SeedWordSlot extends StatefulWidget {
  final int index;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool Function(String) validate;
  final bool isLast;

  /// Larger cell for the desktop (embedded) layout.
  final bool big;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmitted;

  const SeedWordSlot({
    super.key,
    required this.index,
    required this.controller,
    required this.focusNode,
    required this.validate,
    required this.isLast,
    required this.onChanged,
    required this.onSubmitted,
    this.big = false,
  });

  @override
  State<SeedWordSlot> createState() => _SeedWordSlotState();
}

class _SeedWordSlotState extends State<SeedWordSlot> {
  bool _filled = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _apply(_derive());
    widget.controller.addListener(_onChange);
    widget.focusNode.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    widget.focusNode.removeListener(_onChange);
    super.dispose();
  }

  // A word is flagged red only when its slot is not focused (typed or pasted,
  // then left) — never while it's being edited.
  (bool, bool) _derive() {
    final w = widget.controller.text.trim().toLowerCase();
    final filled = w.isNotEmpty;
    return (filled, filled && !widget.focusNode.hasFocus && !widget.validate(w));
  }

  void _apply((bool, bool) v) {
    _filled = v.$1;
    _error = v.$2;
  }

  void _onChange() {
    final v = _derive();
    if (v.$1 != _filled || v.$2 != _error) setState(() => _apply(v));
  }

  @override
  Widget build(BuildContext context) {
    final fs = widget.big ? 14.5 : 13.5;
    return Tappable(
      // The field box is text-tight; make the whole slot (incl. padding) focus it.
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.focusNode.requestFocus(),
      child: Container(
        padding: widget.big
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 13)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        decoration: BoxDecoration(
          color: _filled ? BrandColors.card : BrandColors.surfaceSunken,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _error ? BrandColors.error : BrandColors.border, width: 1),
        ),
        child: Row(
          // Bottom-align so the smaller number sits on the word's baseline.
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                widget.index.toString().padLeft(2, '0'),
                style: TextStyle(
                  fontFamily: 'Ubuntu Mono',
                  fontSize: 10,
                  height: 1,
                  fontWeight: FontWeight.w700,
                  color: BrandColors.inkDisabled,
                ),
              ),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                onChanged: widget.onChanged,
                onSubmitted: (_) => widget.onSubmitted(),
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                textInputAction: widget.isLast ? TextInputAction.done : TextInputAction.next,
                cursorColor: BrandColors.primary,
                // Force the field box down to the text height so it doesn't add
                // vertical padding (which made the slot tall + misaligned the no.).
                strutStyle: StrutStyle(forceStrutHeight: true, height: 1, fontSize: fs),
                style: TextStyle(
                  fontSize: fs,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  color: _error ? BrandColors.error : BrandColors.ink,
                ),
                decoration: const InputDecoration(
                  isCollapsed: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
