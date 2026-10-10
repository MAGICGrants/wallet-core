// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'fhse_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class FhseLocalizationsEn extends FhseLocalizations {
  FhseLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get advancedSecurityLabel => 'Advanced security';

  @override
  String get advancedSecurityTitle => 'Advanced security';

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
  String get securityKeysSection => 'Security keys';

  @override
  String get securityKeysIntroTitle => 'Protect this wallet with a security key';

  @override
  String get securityKeysIntroBody =>
      'Require a YubiKey and its PIN, or the fingerprint on a YubiKey Bio, to open this wallet. Without one of your keys, the wallet files on this phone cannot be decrypted, even by someone who can unlock the phone.';

  @override
  String get securityKeysRequirements =>
      'Works with YubiKey 5 series keys over NFC or USB-C, and with YubiKey Bio over USB-C on Android. On iPhone, USB-C needs YubiKey firmware 5.8 or later. Each key needs a FIDO2 PIN.';

  @override
  String get securityKeysSuggestTwo =>
      'Set up two or more keys and keep one somewhere safe. Your recovery phrase still restores the wallet if you lose them all.';

  @override
  String get securityKeysSetUpButton => 'Set up security keys';

  @override
  String securityKeysUnavailable(String appName) {
    return 'Security keys need a wallet created or restored with this version of $appName.';
  }

  @override
  String get securityKeysYourKeys => 'Your keys';

  @override
  String securityKeysAdded(String date) {
    return 'Added $date';
  }

  @override
  String get securityKeysOneKeyWarning =>
      'You have one key. If you lose it, you will need your recovery phrase to open this wallet. Add a second key as a backup.';

  @override
  String get securityKeysAddButton => 'Add a security key';

  @override
  String get securityKeysManageSection => 'Manage';

  @override
  String get securityKeysRemoveTitle => 'Remove a key';

  @override
  String get securityKeysRemoveSubtitle => 'Set up again with only the keys you keep';

  @override
  String get securityKeysRemoveLink => 'Set up';

  @override
  String get securityKeysRemoveExplain =>
      'To remove a key, set up your keys again with only the keys you want to keep. Any key you leave out stops working for this wallet. Have every key you keep with you.';

  @override
  String get securityKeysRemoveConfirm => 'Set up again';

  @override
  String get securityKeysTurnOff => 'Turn off security keys';

  @override
  String get securityKeysTurnOffBody =>
      'The wallet password goes back into this phone\'s secure storage, and the wallet opens without a key.';

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
    return 'After this long in the background, $appName closes the wallet and forgets its password. Opening it again needs a security key.';
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
      'Background sync keeps working with view-only access, which can see your payments but cannot spend.';

  @override
  String get securityKeysSetupTitle => 'Set up security keys';

  @override
  String get securityKeysSetupAgainTitle => 'Set up keys again';

  @override
  String get securityKeysSetupAgainNote =>
      'Add only the keys you want to keep. Any key you leave out will no longer open this wallet.';

  @override
  String get securityKeysAddFirst => 'Add your first key';

  @override
  String get securityKeysAddAnother => 'Add another key';

  @override
  String get securityKeysFinish => 'Finish';

  @override
  String get securityKeysOneKeyTitle => 'Finish with one key?';

  @override
  String get securityKeysOneKeyBody =>
      'We suggest two or more. If you lose your only key, you will need your recovery phrase to open this wallet.';

  @override
  String get securityKeysFinishAnyway => 'Finish anyway';

  @override
  String get securityKeysNameLabel => 'Key name';

  @override
  String securityKeysNameDefault(int number) {
    return 'YubiKey $number';
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
  String get securityKeysPinMismatch => 'The PINs do not match.';

  @override
  String securityKeysErrorPinInvalid(int count) {
    return 'Incorrect PIN. $count attempts left before the key locks.';
  }

  @override
  String get securityKeysErrorPinInvalidUnknown => 'Incorrect PIN.';

  @override
  String get securityKeysErrorPinBlocked =>
      'This key\'s PIN is blocked. The key must be reset, which removes it from every wallet it protects.';

  @override
  String get securityKeysErrorPinAuthBlocked =>
      'Too many wrong PINs in a row. Remove the key and connect it again.';

  @override
  String get securityKeysErrorPinPolicy =>
      'The key did not accept that PIN. Some keys need at least 6 characters.';

  @override
  String get securityKeysErrorNotEnrolled => 'This key is not set up for this wallet.';

  @override
  String get securityKeysErrorAlreadyAdded => 'This key is already set up for this wallet.';

  @override
  String securityKeysErrorUnsupported(String reason) {
    return 'This key cannot be used here: $reason';
  }

  @override
  String get securityKeysErrorTimeout => 'No key was found. Try again.';

  @override
  String get securityKeysErrorTransport => 'The connection to the key was lost. Try again.';

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
      'Your recovery phrase can open this wallet. Then set up new keys in Settings.';

  @override
  String get securityKeyUseRecoveryPhrase => 'Use recovery phrase';

  @override
  String get securityKeyRecoveryPhraseHint => 'Enter your recovery phrase';

  @override
  String get securityKeyRecoveryWrongPhrase => 'That recovery phrase is not this wallet\'s.';

  @override
  String get securityKeyRecoveryNotPossible =>
      'This wallet came from a 25-word seed, so its phrase cannot open it here. Delete the wallet and restore it from the phrase.';

  @override
  String get securityKeyRecoveredToast =>
      'Unlocked with your recovery phrase. Set up your keys again in Settings.';

  @override
  String get securityKeyConnectTitle => 'Connect your security key';

  @override
  String get securityKeyConnectBodyAndroid =>
      'Plug your YubiKey into the USB-C port and touch it when it blinks, or hold it flat against the back of your phone.';

  @override
  String get securityKeyConnectBodyIos =>
      'Hold your YubiKey near the top of your iPhone, or plug it in and touch it when it blinks.';

  @override
  String get securityKeyConnectButton => 'Connect key';

  @override
  String get securityKeyTryAgain => 'Try again';

  @override
  String get securityKeyWaiting => 'Waiting for your key…';

  @override
  String get securityKeyTalkingToKey => 'Talking to your key…';

  @override
  String get securityKeyKeyBlinking => 'Your key is blinking';

  @override
  String get securityKeyTouchToSelect => 'Touch your key';

  @override
  String get securityKeyTouchBody => 'Touch the gold contact on your key while it blinks.';

  @override
  String get securityKeyPinTitle => 'Enter your key\'s PIN';

  @override
  String get securityKeyPinBody =>
      'The PIN you set for this YubiKey. It is not your phone\'s passcode.';

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
  String securityKeysNewPinBodyCount(int count, String appName) {
    return 'This key has no PIN yet. Choose one with at least $count characters. $appName requires it, so a key found by someone else cannot open your wallet.';
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
  String get securityKeyKeepHolding => 'Keep your key against the phone.';

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
  String get securityKeyFingerprintBody => 'Use a finger you enrolled on this YubiKey Bio.';

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
      'This key cannot protect a wallet. Use a YubiKey 5 series key or a YubiKey Bio.';

  @override
  String get securityKeysErrorPinChangeRequired =>
      'This key wants a new PIN first. Change it in the Yubico Authenticator app, then try again.';

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
      'The fingerprint reader on this key is locked. Enter the key\'s PIN instead.';

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
      'That is a different key from the one you touched. Start again with the key you want to use.';

  @override
  String get securityKeysCancel => 'Cancel';

  @override
  String get securityKeysPinEmpty => 'This field cannot be empty.';

  @override
  String get securityKeysSharedPhraseWarning =>
      'Using this recovery phrase in another wallet app too? Protect that app as well. Once unlocked, either app can show the phrase, so it is only as safe as the less protected one.';
}
