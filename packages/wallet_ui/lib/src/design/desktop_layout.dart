import 'dart:io' show Platform;

import 'package:wallet_infra/wallet_infra.dart' show HostPlatform;

/// True when the app shows its desktop layout: on Linux, Windows and macOS, and
/// for the iOS build running on a Mac.
///
/// The App Store offers the iOS build on Apple silicon Macs, where Dart reports
/// iOS ([HostPlatform.isIosAppOnMac]), so going by [Platform] alone gave a Mac
/// window the phone layout. Layout only: what the platform can do (camera,
/// share sheet, keystore, App Lock, background sync) still follows [Platform].
bool get isDesktopLayout =>
    Platform.isLinux || Platform.isWindows || Platform.isMacOS || HostPlatform.isIosAppOnMac;
