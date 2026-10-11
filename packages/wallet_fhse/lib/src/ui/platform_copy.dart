import 'dart:io';

import '../l10n/fhse_localizations.dart';

/// The copy that names the device or how a key reaches it: a Mac's wording
/// differs from a phone's, and Android's from iPhone's.
extension FhsePlatformCopy on FhseLocalizations {
  String get introBody => Platform.isMacOS ? securityKeysIntroBodyMac : securityKeysIntroBody;

  String get requirements =>
      Platform.isMacOS ? securityKeysRequirementsMac : securityKeysRequirements;

  String get turnOffBody => Platform.isMacOS ? securityKeysTurnOffBodyMac : securityKeysTurnOffBody;

  String get connectBody => Platform.isMacOS
      ? securityKeyConnectBodyMac
      : Platform.isIOS
      ? securityKeyConnectBodyIos
      : securityKeyConnectBodyAndroid;

  String get pinBody => Platform.isMacOS ? securityKeyPinBodyMac : securityKeyPinBody;
}
