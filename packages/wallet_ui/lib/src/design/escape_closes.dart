import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// While [active], Esc runs [onClose], wherever focus is (a panel opened with
/// the mouse closes too), as long as the screen it is on is the top one: a
/// dialog over it takes Esc for itself. For an open dropdown or filter panel.
class EscapeCloses extends StatefulWidget {
  final bool active;
  final VoidCallback onClose;
  final Widget child;

  const EscapeCloses({super.key, this.active = true, required this.onClose, required this.child});

  @override
  State<EscapeCloses> createState() => _EscapeClosesState();
}

class _EscapeClosesState extends State<EscapeCloses> {
  ModalRoute<Object?>? _route;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (!widget.active || event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    if (_route != null && !_route!.isCurrent) return false;
    widget.onClose();
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
