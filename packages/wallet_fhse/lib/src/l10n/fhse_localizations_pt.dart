// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'fhse_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class FhseLocalizationsPt extends FhseLocalizations {
  FhseLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get advancedSecurityLabel => 'Advanced Security';

  @override
  String get advancedSecurityTitle => 'Advanced Security';

  @override
  String get advancedSecurityOff => 'Off';

  @override
  String advancedSecurityKeyCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count keys',
      one: '1 key',
    );
    return '$_temp0';
  }

  @override
  String get advancedSecurityNeedsAttention => 'Needs attention';

  @override
  String get securityKeysUnreadableTitle => 'Set up your security keys again';

  @override
  String get securityKeysUnreadableBody =>
      'This happens after moving to a new phone. Your wallet is safe and your recovery phrase still opens it. Set up your keys again, or turn security keys off.';

  @override
  String get securityKeysLoadFailed => 'Couldn\'t load your security key settings.';

  @override
  String get securityKeysIntroTitle => 'Protect this wallet with a security key';

  @override
  String get securityKeysIntroBody =>
      'Advanced Security is another layer of protection for your wallet beyond the App Lock. When enabled, your wallet can only be opened with your security key and its PIN.';

  @override
  String get securityKeysRequirements =>
      'Works with most FIDO2 capable hardware security keys over NFC. Over USB, only YubiKeys work for now (on iPhone, with firmware 5.8 or later).';

  @override
  String get securityKeysSetUpButton => 'Set up security keys';

  @override
  String securityKeysUnavailable(String appName) {
    return 'Security keys only work with a wallet created or restored in this version of $appName.';
  }

  @override
  String get securityKeysYourKeys => 'Your keys';

  @override
  String securityKeysAdded(String date) {
    return 'Added $date';
  }

  @override
  String get securityKeysOneKeyWarning =>
      'You have only one key. Add a second one as a backup. Without a key, you\'ll need your recovery phrase.';

  @override
  String get securityKeysAddButton => 'Add a security key';

  @override
  String get securityKeysManageSection => 'Manage';

  @override
  String get securityKeysRemoveTitle => 'Remove a key';

  @override
  String get securityKeysRemoveSubtitle => 'Set up again without that key';

  @override
  String get securityKeysRemoveLink => 'Set up';

  @override
  String get securityKeysRemoveExplain =>
      'To remove a key, set up again with only the keys you want to keep. Any key you leave out stops working. Have all the keys you\'re keeping with you.';

  @override
  String get securityKeysRemoveConfirm => 'Set up again';

  @override
  String get securityKeysTurnOff => 'Turn off security keys';

  @override
  String get securityKeysTurnOffBody => 'Your wallet will open without a security key again.';

  @override
  String get securityKeysTurnOffConfirm => 'Turn off';

  @override
  String get securityKeysTurnedOff => 'Security keys are off';

  @override
  String get securityKeysTurnedOn => 'Security keys are on';

  @override
  String get securityKeysLockSection => 'Lock';

  @override
  String get securityKeysFullLockLabel => 'Fully lock after';

  @override
  String securityKeysFullLockDescription(String appName) {
    return 'After this long in the background, $appName fully locks the wallet. You\'ll need a security key to open it again.';
  }

  @override
  String securityKeysMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes',
      one: '1 minute',
    );
    return '$_temp0';
  }

  @override
  String securityKeysHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String get securityKeysBackgroundNote =>
      'While locked, the wallet keeps syncing and can show new payments, but it can\'t spend.';

  @override
  String get securityKeysSetupTitle => 'Set up security keys';

  @override
  String get securityKeysSetupAgainTitle => 'Set up keys again';

  @override
  String get securityKeysSetupAgainNote =>
      'Add only the keys you want to keep. Any key you leave out stops working.';

  @override
  String get securityKeysSetupNote => 'Add each security key you want to use, then tap Finish.';

  @override
  String get securityKeysAddFirst => 'Add your first key';

  @override
  String get securityKeysAddAnother => 'Add another key';

  @override
  String get securityKeysFinish => 'Finish';

  @override
  String get securityKeysOneKeyTitle => 'Use only one key?';

  @override
  String get securityKeysOneKeyBody =>
      'We recommend at least two. If you lose your only key, you\'ll need your recovery phrase.';

  @override
  String get securityKeysFinishAnyway => 'Use one key';

  @override
  String get securityKeysNameLabel => 'Key name';

  @override
  String securityKeysNameDefault(int number) {
    return 'Security key $number';
  }

  @override
  String get securityKeysPinLabel => 'Key PIN';

  @override
  String get securityKeysContinue => 'Continue';

  @override
  String get securityKeysNewPinTitle => 'Create a PIN for this key';

  @override
  String get securityKeysNewPinLabel => 'New PIN';

  @override
  String get securityKeysConfirmPinLabel => 'Confirm PIN';

  @override
  String get securityKeysSetPinButton => 'Set PIN';

  @override
  String get securityKeysPinMismatch => 'The PINs don\'t match.';

  @override
  String securityKeysErrorPinInvalid(int count) {
    return 'Incorrect PIN. $count attempts left before the key locks.';
  }

  @override
  String get securityKeysErrorPinInvalidUnknown => 'Incorrect PIN.';

  @override
  String get securityKeysErrorPinBlocked =>
      'This key is locked after too many wrong PINs. It can only be reset, and a reset key no longer opens any wallet.';

  @override
  String get securityKeysErrorPinAuthBlocked =>
      'Too many wrong PINs. Disconnect the key and connect it again.';

  @override
  String get securityKeysErrorPinPolicy =>
      'The key didn\'t accept that PIN. Some keys need 6 or more characters.';

  @override
  String get securityKeysErrorNotEnrolled => 'This key isn\'t set up for this wallet.';

  @override
  String get securityKeysErrorNotThisWallet =>
      'Your security key settings don\'t match this wallet. Open it with your recovery phrase, then set up your keys again.';

  @override
  String get securityKeysErrorAlreadyAdded => 'This key is already set up for this wallet.';

  @override
  String securityKeysErrorUnsupported(String reason) {
    return 'This key cannot be used here: $reason';
  }

  @override
  String get securityKeysErrorTimeout => 'No key was found. Try again.';

  @override
  String get securityKeysErrorTransport => 'Lost the connection to your key. Try again.';

  @override
  String securityKeysErrorGeneric(String reason) {
    return 'Something went wrong: $reason';
  }

  @override
  String get securityKeyUnlockTitle => 'Unlock with your security key';

  @override
  String get securityKeyUnlockButton => 'Unlock';

  @override
  String get securityKeyLostKeys => 'Lost your keys?';

  @override
  String get securityKeyLostKeysBody =>
      'Open the wallet with your recovery phrase, then set up new keys in Settings.';

  @override
  String get securityKeyUseRecoveryPhrase => 'Use recovery phrase';

  @override
  String get securityKeyRecoveryPhraseHint => 'Enter your recovery phrase';

  @override
  String get securityKeyRecoveryWrongPhrase => 'That recovery phrase doesn\'t match this wallet.';

  @override
  String get securityKeyRecoveryNotPossible =>
      'This wallet was restored from a 25-word recovery phrase, which can\'t unlock it here. Delete the wallet, then restore it from that phrase.';

  @override
  String get securityKeyRecoveredToast =>
      'Unlocked with your recovery phrase. Set up your keys again in Settings.';

  @override
  String get securityKeyConnectTitle => 'Connect your security key';

  @override
  String get securityKeyConnectBodyAndroid =>
      'Plug in your security key and touch it when it blinks, or hold it flat against the back of your phone.';

  @override
  String get securityKeyConnectBodyIos =>
      'Hold your security key near the top of your iPhone, or plug it in and touch it when it blinks.';

  @override
  String get securityKeyConnectButton => 'Connect key';

  @override
  String get securityKeyTryAgain => 'Try again';

  @override
  String get securityKeyWaiting => 'Waiting for your key…';

  @override
  String get securityKeyTalkingToKey => 'Connecting to your key…';

  @override
  String get securityKeyKeyBlinking => 'Your key is blinking';

  @override
  String get securityKeyTouchToSelect => 'Touch your key';

  @override
  String get securityKeyTouchBody => 'Touch your security key while it blinks.';

  @override
  String get securityKeyPinTitle => 'Enter your key\'s PIN';

  @override
  String get securityKeyPinBody => 'This is your security key\'s PIN, not your phone\'s passcode.';

  @override
  String securityKeyPinAttemptsLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count attempts left before the key locks.',
      one: '1 attempt left before the key locks.',
    );
    return '$_temp0';
  }

  @override
  String get securityKeyUseAnotherKey => 'Use a different key';

  @override
  String get securityKeyUseFingerprint => 'Use fingerprint instead';

  @override
  String get securityKeyUsePin => 'Use PIN instead';

  @override
  String securityKeysNewPinBodyCount(int count) {
    return 'This key doesn\'t have a PIN yet. Choose one with at least $count characters, so someone who finds your key can\'t use it.';
  }

  @override
  String securityKeysPinTooShortCount(int count) {
    return 'Use at least $count characters.';
  }

  @override
  String get securityKeyCheckingPin => 'Checking your PIN…';

  @override
  String get securityKeyWorking => 'One moment…';

  @override
  String get securityKeyKeepHolding => 'Keep holding your key to the phone.';

  @override
  String get securityKeyHoldAgain => 'Hold your key to your phone again';

  @override
  String get securityKeyConnectAgain => 'Connect your key again';

  @override
  String get securityKeyTouchToConfirm => 'Touch your key to confirm';

  @override
  String get securityKeyTouchOnceMore => 'Touch your key once more';

  @override
  String get securityKeyTouchToUnlock => 'Touch your key to unlock';

  @override
  String get securityKeyFingerprintToConfirm => 'Touch the fingerprint sensor';

  @override
  String get securityKeyFingerprintOnceMore => 'Touch the sensor once more';

  @override
  String get securityKeyFingerprintToUnlock => 'Touch the sensor to unlock';

  @override
  String get securityKeyFingerprintBody => 'Use a finger you added to this security key.';

  @override
  String securityKeyTouchCount(int current, int total) {
    return 'Touch $current of $total';
  }

  @override
  String get securityKeyAddedTitle => 'Key added';

  @override
  String get securityKeyNameBody => 'Give it a name so you can tell your keys apart.';

  @override
  String get securityKeySaveName => 'Save';

  @override
  String get securityKeysErrorKeyUnsupported =>
      'This security key isn\'t supported. Try a different one.';

  @override
  String get securityKeysErrorPinChangeRequired =>
      'This security key needs a new PIN first. Change it with the key maker\'s app, then try again.';

  @override
  String securityKeysErrorUvInvalid(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Fingerprint not recognized. $count tries left.',
      one: 'Fingerprint not recognized. 1 try left.',
    );
    return '$_temp0';
  }

  @override
  String get securityKeysErrorUvInvalidUnknown => 'Fingerprint not recognized.';

  @override
  String get securityKeysErrorUvBlocked =>
      'Fingerprint is locked on this key. Enter its PIN instead.';

  @override
  String get securityKeysErrorUvNotConfigured =>
      'This key has no fingerprint set up. Enter its PIN instead.';

  @override
  String securityKeyPinTitleNamed(String name) {
    return 'Enter the PIN for $name';
  }

  @override
  String securityKeysSerial(String serial) {
    return 'Serial $serial';
  }

  @override
  String get securityKeysErrorDifferentKey =>
      'This isn\'t the key you touched. Start again with the key you want to use.';

  @override
  String get securityKeysErrorMultipleKeys =>
      'More than one security key is plugged in. Unplug the others, then try again.';

  @override
  String get unlockBoundToAnotherPc =>
      'This wallet can\'t be opened on this PC. If you created it on this PC, restart the PC and try again. Otherwise, restore the wallet from its recovery phrase.';

  @override
  String get securityKeysCancel => 'Cancel';

  @override
  String get securityKeysPinEmpty => 'Enter your PIN.';

  @override
  String get securityKeysSharedPhraseWarning =>
      'Your wallet is only as strong as the weakest protection. Make sure your recovery phrase is saved safely, and if you use the same wallet on multiple devices, make sure to set up Advanced Security there too.';

  @override
  String get securityKeysRequirementsMac => 'Works with most FIDO2 capable hardware security keys.';

  @override
  String get securityKeyConnectBodyMac =>
      'Plug your security key into this Mac and touch it when it blinks.';

  @override
  String get securityKeyPinBodyMac => 'This is your security key\'s PIN, not your Mac\'s password.';

  @override
  String get desktopAutoLockLabel => 'Lock after';

  @override
  String desktopAutoLockDescription(String appName) {
    return 'After this long without use, $appName locks the wallet. Unlock it to continue.';
  }

  @override
  String get securityKeysRequirementsLinux =>
      'Works with most FIDO2 capable hardware security keys. Needs libfido2, which most Linux systems already have.';

  @override
  String get securityKeysRequirementsWindows =>
      'Works with most FIDO2 capable hardware security keys. Needs Windows 11 (22H2 or later).';

  @override
  String get securityKeysTurnOffBodyDesktop => 'Your password alone will open the wallet again.';

  @override
  String get securityKeyConnectBodyDesktop =>
      'Plug your security key into this computer and touch it when it blinks.';

  @override
  String get securityKeyConnectBodyWindows =>
      'Windows asks for your security key, its PIN, and a touch.';

  @override
  String get securityKeyPinBodyDesktop =>
      'This is your security key\'s PIN, not your wallet password.';

  @override
  String get securityKeyWindowsPromptTitle => 'Continue in Windows Security';

  @override
  String get securityKeyWindowsPromptBody => 'Enter your security key\'s PIN, then touch the key.';

  @override
  String get securityKeyWindowsPromptEnrollBody =>
      'Windows will ask twice. Each time, enter your security key\'s PIN, then touch the key.';

  @override
  String get securityKeyWindowsWaiting => 'Waiting for Windows Security…';

  @override
  String get securityKeyUseButton => 'Use security key';

  @override
  String get advancedSecurityAuthReason => 'Confirm it\'s you to open Advanced Security';

  @override
  String get advancedSecurityAuthFailed => 'Couldn\'t confirm it\'s you.';

  @override
  String get advancedSecurityPasswordTitle => 'Enter your password';

  @override
  String advancedSecurityPasswordBody(String appName) {
    return 'Enter the password you use to unlock $appName.';
  }

  @override
  String get advancedSecurityPasswordLabel => 'Password';

  @override
  String get advancedSecurityPasswordWrong => 'Incorrect password.';

  @override
  String get advancedSecurityContinue => 'Continue';

  @override
  String get appLockLabel => 'App Lock';

  @override
  String get appLockImmediately => 'Immediately';

  @override
  String appLockDescriptionPhone(String appName) {
    return 'How long $appName can be in the background before it asks for your face, fingerprint or passcode again.';
  }

  @override
  String appLockDescriptionMac(String appName) {
    return 'How long $appName can go unused before it asks for Touch ID or your Mac\'s password again. Immediately locks it as soon as its window is hidden. The wallet keeps syncing.';
  }

  @override
  String appLockDescriptionPassword(String appName) {
    return 'How long $appName can go unused before it asks for your password again. Immediately locks it as soon as its window is hidden. The wallet keeps syncing.';
  }

  @override
  String appLockNoDeviceLock(String appName) {
    return 'This device has no screen lock, so anyone holding it can open $appName. Set a passcode or screen lock in the device\'s settings.';
  }

  @override
  String lockLaterAuthReason(String appName) {
    return 'Confirm it\'s you to lock $appName less often';
  }

  @override
  String lockLaterPasswordBody(String appName) {
    return 'A longer time leaves $appName open for longer. Enter the password you unlock it with.';
  }

  @override
  String appLockUseRecoveryPhraseBody(String appName) {
    return 'If this device can\'t confirm it\'s you, your recovery phrase opens $appName instead.';
  }
}
