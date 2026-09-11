import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart' show SecureClipboard;

import 'brand.dart';

const _defaultDuration = Duration(seconds: 3);

/// Shows [message] as a brand toast.
///
/// Replaces `ScaffoldMessenger.showSnackBar`. A SnackBar renders inside the
/// page's `Scaffold`, which puts it *underneath* any modal route on top of it:
/// copy a value from a bottom sheet and the confirmation is hidden behind the
/// sheet and its scrim. This inserts into the root overlay instead, so it draws
/// above sheets, dialogs and the scrim.
///
/// One toast at a time: a second call replaces the first, which is the
/// behaviour the `hideCurrentSnackBar()` call sites were reaching for.
void showBrandToast(BuildContext context, String message, {Duration duration = _defaultDuration}) =>
    BrandToast.of(context).show(message, duration: duration);

/// Confirms a clipboard copy with [message] -- unless the platform already
/// confirmed it.
///
/// Android 13 shows its own "Copied" pill whenever anything reaches the
/// clipboard, so an app toast on top of it tells the user the same thing twice,
/// in two different shapes. Google's copy/paste guidance is to drop the app's
/// own there. Every other platform stays silent, so the toast is the only
/// feedback and must still be shown.
///
/// Use this for copy confirmations specifically; [showBrandToast] stays the
/// right call for everything else.
Future<void> showCopyToast(BuildContext context, String message) async {
  if (await SecureClipboard.systemConfirmsCopy) return;
  if (context.mounted) showBrandToast(context, message);
}

/// A toast handle captured from a context, for callers that need to show a
/// message *after* the context that created it is gone -- the same reason the
/// old call sites wrote `final messenger = ScaffoldMessenger.of(context)`
/// before popping a route. The root overlay outlives the popped route, so the
/// captured handle stays valid.
class BrandToast {
  final OverlayState _overlay;

  const BrandToast._(this._overlay);

  factory BrandToast.of(BuildContext context) =>
      BrandToast._(Overlay.of(context, rootOverlay: true));

  static OverlayEntry? _entry;

  /// Removes the toast on screen, if any. Immediate -- no exit animation --
  /// because the only caller is [show] making room for the next one.
  static void hide() {
    _entry?.remove();
    _entry = null;
  }

  void show(String message, {Duration duration = _defaultDuration}) {
    hide();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _BrandToastCard(
        message: message,
        duration: duration,
        // Only clear the shared slot if this toast is still the one in it; a
        // replacement may already have taken over by the time we fade out.
        onDismissed: () {
          if (_entry == entry) {
            _entry = null;
            entry.remove();
          }
        },
      ),
    );
    _entry = entry;
    _overlay.insert(entry);
  }
}

class _BrandToastCard extends StatefulWidget {
  final String message;
  final Duration duration;
  final VoidCallback onDismissed;

  const _BrandToastCard({
    required this.message,
    required this.duration,
    required this.onDismissed,
  });

  @override
  State<_BrandToastCard> createState() => _BrandToastCardState();
}

class _BrandToastCardState extends State<_BrandToastCard> with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  )..forward();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    _timer?.cancel();
    if (!mounted) return;
    await _fade.reverse();
    if (mounted) widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      // Sit above the home indicator, and above the keyboard when one is up --
      // a toast fired from a form should not land behind it.
      bottom: media.padding.bottom + media.viewInsets.bottom + 22,
      child: FadeTransition(
        opacity: _fade,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.35), end: Offset.zero).animate(
            CurvedAnimation(parent: _fade, curve: Curves.easeOutCubic),
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: GestureDetector(
                  onTap: _dismiss,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                      decoration: BoxDecoration(
                        color: BrandColors.inverseSurface,
                        borderRadius: BrandRadii.rPill,
                        boxShadow: BrandShadows.sheet,
                      ),
                      child: Text(
                        widget.message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'Ubuntu',
                          fontSize: 13,
                          height: 1.35,
                          color: BrandColors.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
