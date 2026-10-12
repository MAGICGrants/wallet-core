import 'dart:io';

import '../l10n/fhse_localizations.dart';

/// The copy that names the device or how a key reaches it: a Mac's wording
/// differs from a phone's, Android's from iPhone's, and Linux and Windows,
/// where the user types the wallet password, from both.
extension FhsePlatformCopy on FhseLocalizations {
  static bool get _typesPassword => Platform.isLinux || Platform.isWindows;

  String get introBody => Platform.isMacOS
      ? securityKeysIntroBodyMac
      : _typesPassword
      ? securityKeysIntroBodyDesktop
      : securityKeysIntroBody;

  String get requirements => Platform.isMacOS
      ? securityKeysRequirementsMac
      : Platform.isLinux
      ? securityKeysRequirementsLinux
      : Platform.isWindows
      ? securityKeysRequirementsWindows
      : securityKeysRequirements;

  String get turnOffBody => Platform.isMacOS
      ? securityKeysTurnOffBodyMac
      : _typesPassword
      ? securityKeysTurnOffBodyDesktop
      : securityKeysTurnOffBody;

  String get connectBody => Platform.isMacOS
      ? securityKeyConnectBodyMac
      : Platform.isIOS
      ? securityKeyConnectBodyIos
      : Platform.isLinux
      ? securityKeyConnectBodyDesktop
      : Platform.isWindows
      ? securityKeyConnectBodyWindows
      : securityKeyConnectBodyAndroid;

  String get pinBody => Platform.isMacOS
      ? securityKeyPinBodyMac
      : _typesPassword
      ? securityKeyPinBodyDesktop
      : securityKeyPinBody;
}
