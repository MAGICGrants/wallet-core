import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wallet_infra/wallet_infra.dart' show HostPlatform;

import 'desktop_layout.dart';

/// Desktop: the platform's Back shortcut goes back a screen, as the back link
/// does: Cmd+[ on a Mac, Alt+Left on Windows and Linux. It pops through the
/// navigator, so a screen that refuses to be left (PopScope) still refuses and
/// the first screen stays. Phones: nothing (their Back is the system's).
///
/// Wrap the app's navigator with it (MaterialApp.builder's child), under any
/// cover drawn over the navigator, so a lock screen on top does not take it.
class DesktopBackShortcut extends StatelessWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const DesktopBackShortcut({super.key, required this.navigatorKey, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!isDesktopLayout) return child;
    final mac = defaultTargetPlatform == TargetPlatform.macOS || HostPlatform.isIosAppOnMac;
    final back = mac
        ? const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true)
        : const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true);
    return CallbackShortcuts(
      bindings: {back: () => navigatorKey.currentState?.maybePop()},
      child: child,
    );
  }
}
