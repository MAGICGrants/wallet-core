import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../logging.dart';
import 'host_platform.dart';

/// Blocks screenshots and screen recording for as long as the screen is
/// mounted: Android `FLAG_SECURE`; on iOS the window is drawn inside a secure
/// text field's canvas, which iOS leaves out of screenshots, recordings and
/// mirroring.
///
/// Use on anything that displays a secret: seed, private keys, LWS view key.
/// The display-side counterpart to `Redact`; the same value
/// that must not reach a log should not reach a screenshot. The app switcher's
/// snapshot is covered on every screen, not just these: Android 13+ via
/// `setRecentsScreenshotEnabled(false)`, iOS via wallet_fhse's `PrivacyCover`.
mixin SecureScreenMixin<T extends StatefulWidget> on State<T> {
  /// Fixed, app-neutral channel name. Each app registers the handler itself
  /// (MainActivity, AppDelegate), as for `SecureClipboard`.
  static const channelName = 'org.magicgrants.wallet/secure_screen';

  static const _channel = MethodChannel(channelName);

  // Mobile only, and not enforced for the iOS build on a Mac. The mount
  // counter is still kept everywhere so the ref-count stays valid.
  @visibleForTesting
  static bool? debugForceProtectablePlatform;

  static bool get _supported =>
      (debugForceProtectablePlatform ?? (Platform.isAndroid || Platform.isIOS)) &&
      !HostPlatform.isIosAppOnMac;

  /// Ref-count across the seed-then-keys onboarding routes this mixin guards.
  static int _mounted = 0;

  @override
  void initState() {
    super.initState();
    if (_mounted++ == 0 && _supported) unawaited(_setSecure(true));
  }

  @override
  void dispose() {
    // Clamped: a dispose without a matching initState would otherwise drive the
    // count negative and leave protection stuck on for the process.
    _mounted = _mounted > 0 ? _mounted - 1 : 0;
    if (_mounted == 0 && _supported) unawaited(_setSecure(false));
    super.dispose();
  }

  static Future<void> _setSecure(bool secure) async {
    try {
      await _channel.invokeMethod<void>('setSecure', {'secure': secure});
    } catch (e) {
      // An app build without the handler. Nothing to fall back to.
      log(LogLevel.warn, 'secure screen channel failed: $e');
    }
  }

  /// Test-only: the number of protected screens currently mounted.
  @visibleForTesting
  static int get mountedProtectedScreens => _mounted;

  @visibleForTesting
  static void resetForTesting() => _mounted = 0;
}
