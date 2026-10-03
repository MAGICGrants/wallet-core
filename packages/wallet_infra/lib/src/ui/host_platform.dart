import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging.dart';

/// What the app is running on, where `dart:io`'s [Platform] cannot tell.
///
/// The App Store offers the iOS build on Apple silicon Macs ("Designed for
/// iPad"), and there Dart reports iOS: the binary, its plugins and its keychain
/// are all iOS's, and only the machine is a Mac. Behaviour stays iOS's;
/// [isIosAppOnMac] is for the few decisions that follow the machine instead,
/// such as the desktop layout.
///
/// Like [SecureClipboard], the native side lives in each app, under
/// [channelName].
class HostPlatform {
  HostPlatform._();

  /// Fixed, app-neutral channel name; each app registers a handler for it.
  static const channelName = 'org.magicgrants.wallet/host_platform';

  static const _channel = MethodChannel(channelName);

  static var _iosAppOnMac = false;

  /// True when the iOS build is running on a Mac. False until [init] has run.
  static bool get isIosAppOnMac => _iosAppOnMac;

  /// Asks the host. Await it before `runApp`: the layout reads [isIosAppOnMac]
  /// synchronously from the first frame.
  static Future<void> init() async {
    if (!Platform.isIOS) return;
    try {
      _iosAppOnMac = await _channel.invokeMethod<bool>('isIosAppOnMac') ?? false;
    } catch (e) {
      // A host build without the handler: lay out for the device iOS reports.
      log(LogLevel.warn, 'host platform check failed: $e');
    }
  }

  /// Test seam: pin [isIosAppOnMac] without a platform channel.
  @visibleForTesting
  static set iosAppOnMacForTesting(bool value) => _iosAppOnMac = value;
}
