import 'package:flutter/material.dart';

import 'brand.dart';
import 'brand_screen_header.dart';
import 'desktop_back_link.dart';
import 'desktop_layout.dart';

/// What a shared sub-page takes from the app: the back links' strings, and the
/// app's own desktop frame (its sidebar differs per app).
class SubPageChrome {
  /// The desktop back link outside the frame ("Back"), as from onboarding.
  final String back;

  /// The desktop back link inside it, naming where it returns ("Settings").
  final String parent;

  /// Wraps a page opened from inside the frame, on desktop.
  final Widget Function(Widget page)? desktopShell;

  const SubPageChrome({required this.back, required this.parent, this.desktopShell});
}

/// A full-screen page under a back header, 520 wide: a centred title beside a
/// back button on a phone, a back link above a large title on desktop. Opened
/// with `arguments: true` from inside the app's desktop frame (Settings), it
/// sits in [SubPageChrome.desktopShell].
class SubPageScaffold extends StatelessWidget {
  final String title;
  final SubPageChrome chrome;
  final Widget child;

  /// The desktop back link's label, for a page with its own way back.
  final String? backLabel;

  /// Defaults to popping the route.
  final VoidCallback? onBack;

  const SubPageScaffold({
    super.key,
    required this.title,
    required this.chrome,
    required this.child,
    this.backLabel,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final inShell = ModalRoute.of(context)?.settings.arguments == true;
    final back = onBack ?? () => Navigator.pop(context);
    final header = isDesktopLayout
        ? Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DesktopBackLink(
                  label: backLabel ?? (inShell ? chrome.parent : chrome.back),
                  onTap: back,
                ),
                const SizedBox(height: 12),
                Text(title, style: desktopTitleStyle),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: BrandScreenHeader(
              onBack: back,
              // Clear of the 44pt back button: a title can be long.
              center: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 52),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BrandText.appBar.copyWith(fontSize: 16),
                ),
              ),
            ),
          );
    final body = SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );

    final shell = chrome.desktopShell;
    if (isDesktopLayout && inShell && shell != null) return shell(body);
    return Scaffold(backgroundColor: BrandColors.paper, body: body);
  }
}
