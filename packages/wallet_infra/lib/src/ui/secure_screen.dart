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
  @override
  void initState() {
    super.initState();
    ScreenProtector.preventScreenshotOn();
    ScreenProtector.protectDataLeakageWithBlur();
  }

  @override
  void dispose() {
    ScreenProtector.preventScreenshotOff();
    ScreenProtector.protectDataLeakageWithBlurOff();
    super.dispose();
  }
}
