import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:screen_protector/screen_protector.dart';

/// Blocks screenshots and screen recording (Android `FLAG_SECURE`, iOS) and
/// covers the app with a blur when it is backgrounded (iOS resign-active),
/// for as long as the screen is mounted.
///
/// Use on anything that displays a secret: seed, private keys, LWS view key.
/// The display-side counterpart to `Redact`; the same value
/// that must not reach a log should not reach the app switcher's screenshot.
mixin SecureScreenMixin<T extends StatefulWidget> on State<T> {
  // screen_protector is a mobile-only plugin (no desktop implementation), so the
  // FLAG_SECURE / blur is a no-op on Linux/Windows/macOS. The mount counter is
  // kept on every platform so the ref-count (and its tests) stay valid.
  static final bool _supported = Platform.isAndroid || Platform.isIOS;

  /// Ref-count across the seed-then-keys onboarding routes this mixin guards.
  static int _mounted = 0;

  @override
  void initState() {
    super.initState();
    if (_mounted++ == 0 && _supported) {
      ScreenProtector.preventScreenshotOn();
      ScreenProtector.protectDataLeakageWithBlur();
    }
  }

  @override
  void dispose() {
    // Clamped: a dispose without a matching initState would otherwise drive the
    // count negative and leave protection stuck on for the process.
    _mounted = _mounted > 0 ? _mounted - 1 : 0;
    if (_mounted == 0 && _supported) {
      ScreenProtector.preventScreenshotOff();
      ScreenProtector.protectDataLeakageWithBlurOff();
    }
    super.dispose();
  }

  /// Test-only: the number of protected screens currently mounted.
  @visibleForTesting
  static int get mountedProtectedScreens => _mounted;

  @visibleForTesting
  static void resetForTesting() => _mounted = 0;
}
