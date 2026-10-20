import 'package:flutter/material.dart';
import 'package:wallet_ui/wallet_ui.dart' show BrandColors;

import 'app_lock.dart' show passAppLock;

/// A screen that needs a passing App Lock ([passAppLock]): the recovery
/// phrase, spend or view keys, Advanced Security. Applied at the route, so the
/// wrapped screen, and its secret-reading `initState`, is only built once App
/// Lock passes; anything else goes back without it.
///
/// Must wrap the route, not sit inside the screen's `build`: any route
/// (Settings, coin settings, a deep link) then goes through the same gate, and
/// no caller can be trusted to have asked first. A desktop sheet is not a
/// route, so the function that opens one calls [passAppLock] itself.
///
/// Asks every time, however recently App Lock was passed. What it asks for is
/// the platform's App Lock, not the caller's choice: the device's own prompt
/// with [reason], or the wallet password with [passwordBody] on Linux and
/// Windows.
///
/// It does not ask for a security key: with keys on, opening the wallet
/// already needed one. If the wallet can ever be opened without a key while
/// keys are on, revisit the screens behind this gate.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.reason, this.passwordBody, required this.child});

  final String reason;
  final String? passwordBody;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> {
  bool _passed = false;

  @override
  void initState() {
    super.initState();
    // After the first frame: the password sheet needs this route's navigator.
    WidgetsBinding.instance.addPostFrameCallback((_) => _pass());
  }

  Future<void> _pass() async {
    if (!mounted) return;
    final passed = await passAppLock(
      context,
      reason: widget.reason,
      passwordBody: widget.passwordBody,
    );
    if (!mounted) return;
    if (passed) {
      setState(() => _passed = true);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) => _passed
      ? widget.child
      // Opaque ground until passed, so nothing sensitive renders behind the prompt.
      : ColoredBox(color: BrandColors.paper, child: const SizedBox.expand());
}
