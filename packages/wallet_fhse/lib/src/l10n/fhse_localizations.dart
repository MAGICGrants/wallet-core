import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'fhse_localizations_en.dart';
import 'fhse_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of FhseLocalizations
/// returned by `FhseLocalizations.of(context)`.
///
/// Applications need to include `FhseLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/fhse_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: FhseLocalizations.localizationsDelegates,
///   supportedLocales: FhseLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the FhseLocalizations.supportedLocales
/// property.
abstract class FhseLocalizations {
  FhseLocalizations(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static FhseLocalizations of(BuildContext context) {
    return Localizations.of<FhseLocalizations>(context, FhseLocalizations)!;
  }

  static const LocalizationsDelegate<FhseLocalizations> delegate = _FhseLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en'), Locale('pt')];

  /// No description provided for @advancedSecurityLabel.
  ///
  /// In en, this message translates to:
  /// **'Advanced security'**
  String get advancedSecurityLabel;

  /// No description provided for @advancedSecurityTitle.
  ///
  /// In en, this message translates to:
  /// **'Advanced security'**
  String get advancedSecurityTitle;

  /// No description provided for @advancedSecurityOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get advancedSecurityOff;

  /// No description provided for @advancedSecurityKeyCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 key} other{{count} keys}}'**
  String advancedSecurityKeyCount(int count);

  /// No description provided for @securityKeysSection.
  ///
  /// In en, this message translates to:
  /// **'Security keys'**
  String get securityKeysSection;

  /// No description provided for @securityKeysIntroTitle.
  ///
  /// In en, this message translates to:
  /// **'Protect this wallet with a security key'**
  String get securityKeysIntroTitle;

  /// No description provided for @securityKeysIntroBody.
  ///
  /// In en, this message translates to:
  /// **'Require a YubiKey and its PIN, or the fingerprint on a YubiKey Bio, to open this wallet. Without one of your keys, the wallet files on this phone cannot be decrypted, even by someone who can unlock the phone.'**
  String get securityKeysIntroBody;

  /// No description provided for @securityKeysRequirements.
  ///
  /// In en, this message translates to:
  /// **'Works with YubiKey 5 series keys over NFC or USB-C, and with YubiKey Bio over USB-C on Android. On iPhone, USB-C needs YubiKey firmware 5.8 or later. Each key needs a FIDO2 PIN.'**
  String get securityKeysRequirements;

  /// No description provided for @securityKeysSuggestTwo.
  ///
  /// In en, this message translates to:
  /// **'Set up two or more keys and keep one somewhere safe. Your recovery phrase still restores the wallet if you lose them all.'**
  String get securityKeysSuggestTwo;

  /// No description provided for @securityKeysSetUpButton.
  ///
  /// In en, this message translates to:
  /// **'Set up security keys'**
  String get securityKeysSetUpButton;

  /// No description provided for @securityKeysUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Security keys need a wallet created or restored with this version of {appName}.'**
  String securityKeysUnavailable(String appName);

  /// No description provided for @securityKeysYourKeys.
  ///
  /// In en, this message translates to:
  /// **'Your keys'**
  String get securityKeysYourKeys;

  /// No description provided for @securityKeysAdded.
  ///
  /// In en, this message translates to:
  /// **'Added {date}'**
  String securityKeysAdded(String date);

  /// No description provided for @securityKeysOneKeyWarning.
  ///
  /// In en, this message translates to:
  /// **'You have one key. If you lose it, you will need your recovery phrase to open this wallet. Add a second key as a backup.'**
  String get securityKeysOneKeyWarning;

  /// No description provided for @securityKeysAddButton.
  ///
  /// In en, this message translates to:
  /// **'Add a security key'**
  String get securityKeysAddButton;

  /// No description provided for @securityKeysManageSection.
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get securityKeysManageSection;

  /// No description provided for @securityKeysRemoveTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove a key'**
  String get securityKeysRemoveTitle;

  /// No description provided for @securityKeysRemoveSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Set up again with only the keys you keep'**
  String get securityKeysRemoveSubtitle;

  /// No description provided for @securityKeysRemoveLink.
  ///
  /// In en, this message translates to:
  /// **'Set up'**
  String get securityKeysRemoveLink;

  /// No description provided for @securityKeysRemoveExplain.
  ///
  /// In en, this message translates to:
  /// **'To remove a key, set up your keys again with only the keys you want to keep. Any key you leave out stops working for this wallet. Have every key you keep with you.'**
  String get securityKeysRemoveExplain;

  /// No description provided for @securityKeysRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Set up again'**
  String get securityKeysRemoveConfirm;

  /// No description provided for @securityKeysTurnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn off security keys'**
  String get securityKeysTurnOff;

  /// No description provided for @securityKeysTurnOffBody.
  ///
  /// In en, this message translates to:
  /// **'The wallet password goes back into this phone\'s secure storage, and the wallet opens without a key.'**
  String get securityKeysTurnOffBody;

  /// No description provided for @securityKeysTurnOffConfirm.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get securityKeysTurnOffConfirm;

  /// No description provided for @securityKeysTurnedOff.
  ///
  /// In en, this message translates to:
  /// **'Security keys are off'**
  String get securityKeysTurnedOff;

  /// No description provided for @securityKeysTurnedOn.
  ///
  /// In en, this message translates to:
  /// **'Security keys are on'**
  String get securityKeysTurnedOn;

  /// No description provided for @securityKeysLockSection.
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get securityKeysLockSection;

  /// No description provided for @securityKeysFullLockLabel.
  ///
  /// In en, this message translates to:
  /// **'Fully lock after'**
  String get securityKeysFullLockLabel;

  /// No description provided for @securityKeysFullLockDescription.
  ///
  /// In en, this message translates to:
  /// **'After this long in the background, {appName} closes the wallet and forgets its password. Opening it again needs a security key.'**
  String securityKeysFullLockDescription(String appName);

  /// No description provided for @securityKeysMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute} other{{count} minutes}}'**
  String securityKeysMinutes(int count);

  /// No description provided for @securityKeysHours.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour} other{{count} hours}}'**
  String securityKeysHours(int count);

  /// No description provided for @securityKeysBackgroundNote.
  ///
  /// In en, this message translates to:
  /// **'Background sync keeps working with view-only access, which can see your payments but cannot spend.'**
  String get securityKeysBackgroundNote;

  /// No description provided for @securityKeysSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up security keys'**
  String get securityKeysSetupTitle;

  /// No description provided for @securityKeysSetupAgainTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up keys again'**
  String get securityKeysSetupAgainTitle;

  /// No description provided for @securityKeysSetupAgainNote.
  ///
  /// In en, this message translates to:
  /// **'Add only the keys you want to keep. Any key you leave out will no longer open this wallet.'**
  String get securityKeysSetupAgainNote;

  /// No description provided for @securityKeysAddFirst.
  ///
  /// In en, this message translates to:
  /// **'Add your first key'**
  String get securityKeysAddFirst;

  /// No description provided for @securityKeysAddAnother.
  ///
  /// In en, this message translates to:
  /// **'Add another key'**
  String get securityKeysAddAnother;

  /// No description provided for @securityKeysFinish.
  ///
  /// In en, this message translates to:
  /// **'Finish'**
  String get securityKeysFinish;

  /// No description provided for @securityKeysOneKeyTitle.
  ///
  /// In en, this message translates to:
  /// **'Finish with one key?'**
  String get securityKeysOneKeyTitle;

  /// No description provided for @securityKeysOneKeyBody.
  ///
  /// In en, this message translates to:
  /// **'We suggest two or more. If you lose your only key, you will need your recovery phrase to open this wallet.'**
  String get securityKeysOneKeyBody;

  /// No description provided for @securityKeysFinishAnyway.
  ///
  /// In en, this message translates to:
  /// **'Finish anyway'**
  String get securityKeysFinishAnyway;

  /// No description provided for @securityKeysNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Key name'**
  String get securityKeysNameLabel;

  /// No description provided for @securityKeysNameDefault.
  ///
  /// In en, this message translates to:
  /// **'YubiKey {number}'**
  String securityKeysNameDefault(int number);

  /// No description provided for @securityKeysPinLabel.
  ///
  /// In en, this message translates to:
  /// **'Key PIN'**
  String get securityKeysPinLabel;

  /// No description provided for @securityKeysContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get securityKeysContinue;

  /// No description provided for @securityKeysNewPinTitle.
  ///
  /// In en, this message translates to:
  /// **'Create a PIN for this key'**
  String get securityKeysNewPinTitle;

  /// No description provided for @securityKeysNewPinLabel.
  ///
  /// In en, this message translates to:
  /// **'New PIN'**
  String get securityKeysNewPinLabel;

  /// No description provided for @securityKeysConfirmPinLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirm PIN'**
  String get securityKeysConfirmPinLabel;

  /// No description provided for @securityKeysSetPinButton.
  ///
  /// In en, this message translates to:
  /// **'Set PIN'**
  String get securityKeysSetPinButton;

  /// No description provided for @securityKeysPinMismatch.
  ///
  /// In en, this message translates to:
  /// **'The PINs do not match.'**
  String get securityKeysPinMismatch;

  /// No description provided for @securityKeysErrorPinInvalid.
  ///
  /// In en, this message translates to:
  /// **'Incorrect PIN. {count} attempts left before the key locks.'**
  String securityKeysErrorPinInvalid(int count);

  /// No description provided for @securityKeysErrorPinInvalidUnknown.
  ///
  /// In en, this message translates to:
  /// **'Incorrect PIN.'**
  String get securityKeysErrorPinInvalidUnknown;

  /// No description provided for @securityKeysErrorPinBlocked.
  ///
  /// In en, this message translates to:
  /// **'This key\'s PIN is blocked. The key must be reset, which removes it from every wallet it protects.'**
  String get securityKeysErrorPinBlocked;

  /// No description provided for @securityKeysErrorPinAuthBlocked.
  ///
  /// In en, this message translates to:
  /// **'Too many wrong PINs in a row. Remove the key and connect it again.'**
  String get securityKeysErrorPinAuthBlocked;

  /// No description provided for @securityKeysErrorPinPolicy.
  ///
  /// In en, this message translates to:
  /// **'The key did not accept that PIN. Some keys need at least 6 characters.'**
  String get securityKeysErrorPinPolicy;

  /// No description provided for @securityKeysErrorNotEnrolled.
  ///
  /// In en, this message translates to:
  /// **'This key is not set up for this wallet.'**
  String get securityKeysErrorNotEnrolled;

  /// No description provided for @securityKeysErrorAlreadyAdded.
  ///
  /// In en, this message translates to:
  /// **'This key is already set up for this wallet.'**
  String get securityKeysErrorAlreadyAdded;

  /// No description provided for @securityKeysErrorUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This key cannot be used here: {reason}'**
  String securityKeysErrorUnsupported(String reason);

  /// No description provided for @securityKeysErrorTimeout.
  ///
  /// In en, this message translates to:
  /// **'No key was found. Try again.'**
  String get securityKeysErrorTimeout;

  /// No description provided for @securityKeysErrorTransport.
  ///
  /// In en, this message translates to:
  /// **'The connection to the key was lost. Try again.'**
  String get securityKeysErrorTransport;

  /// No description provided for @securityKeysErrorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong: {reason}'**
  String securityKeysErrorGeneric(String reason);

  /// No description provided for @securityKeyUnlockTitle.
  ///
  /// In en, this message translates to:
  /// **'Unlock with your security key'**
  String get securityKeyUnlockTitle;

  /// No description provided for @securityKeyUnlockButton.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get securityKeyUnlockButton;

  /// No description provided for @securityKeyLostKeys.
  ///
  /// In en, this message translates to:
  /// **'Lost your keys?'**
  String get securityKeyLostKeys;

  /// No description provided for @securityKeyLostKeysBody.
  ///
  /// In en, this message translates to:
  /// **'Your recovery phrase can open this wallet. Then set up new keys in Settings.'**
  String get securityKeyLostKeysBody;

  /// No description provided for @securityKeyUseRecoveryPhrase.
  ///
  /// In en, this message translates to:
  /// **'Use recovery phrase'**
  String get securityKeyUseRecoveryPhrase;

  /// No description provided for @securityKeyRecoveryPhraseHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your recovery phrase'**
  String get securityKeyRecoveryPhraseHint;

  /// No description provided for @securityKeyRecoveryWrongPhrase.
  ///
  /// In en, this message translates to:
  /// **'That recovery phrase is not this wallet\'s.'**
  String get securityKeyRecoveryWrongPhrase;

  /// No description provided for @securityKeyRecoveryNotPossible.
  ///
  /// In en, this message translates to:
  /// **'This wallet came from a 25-word seed, so its phrase cannot open it here. Delete the wallet and restore it from the phrase.'**
  String get securityKeyRecoveryNotPossible;

  /// No description provided for @securityKeyRecoveredToast.
  ///
  /// In en, this message translates to:
  /// **'Unlocked with your recovery phrase. Set up your keys again in Settings.'**
  String get securityKeyRecoveredToast;

  /// No description provided for @securityKeyConnectTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect your security key'**
  String get securityKeyConnectTitle;

  /// No description provided for @securityKeyConnectBodyAndroid.
  ///
  /// In en, this message translates to:
  /// **'Plug your YubiKey into the USB-C port and touch it when it blinks, or hold it flat against the back of your phone.'**
  String get securityKeyConnectBodyAndroid;

  /// No description provided for @securityKeyConnectBodyIos.
  ///
  /// In en, this message translates to:
  /// **'Hold your YubiKey near the top of your iPhone, or plug it in and touch it when it blinks.'**
  String get securityKeyConnectBodyIos;

  /// No description provided for @securityKeyConnectButton.
  ///
  /// In en, this message translates to:
  /// **'Connect key'**
  String get securityKeyConnectButton;

  /// No description provided for @securityKeyTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get securityKeyTryAgain;

  /// No description provided for @securityKeyWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your key…'**
  String get securityKeyWaiting;

  /// No description provided for @securityKeyTalkingToKey.
  ///
  /// In en, this message translates to:
  /// **'Talking to your key…'**
  String get securityKeyTalkingToKey;

  /// No description provided for @securityKeyKeyBlinking.
  ///
  /// In en, this message translates to:
  /// **'Your key is blinking'**
  String get securityKeyKeyBlinking;

  /// No description provided for @securityKeyTouchToSelect.
  ///
  /// In en, this message translates to:
  /// **'Touch your key'**
  String get securityKeyTouchToSelect;

  /// No description provided for @securityKeyTouchBody.
  ///
  /// In en, this message translates to:
  /// **'Touch the gold contact on your key while it blinks.'**
  String get securityKeyTouchBody;

  /// No description provided for @securityKeyPinTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your key\'s PIN'**
  String get securityKeyPinTitle;

  /// No description provided for @securityKeyPinBody.
  ///
  /// In en, this message translates to:
  /// **'The PIN you set for this YubiKey. It is not your phone\'s passcode.'**
  String get securityKeyPinBody;

  /// No description provided for @securityKeyPinAttemptsLeft.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 attempt left before the key locks.} other{{count} attempts left before the key locks.}}'**
  String securityKeyPinAttemptsLeft(int count);

  /// No description provided for @securityKeyUseAnotherKey.
  ///
  /// In en, this message translates to:
  /// **'Use a different key'**
  String get securityKeyUseAnotherKey;

  /// No description provided for @securityKeyUseFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Use fingerprint instead'**
  String get securityKeyUseFingerprint;

  /// No description provided for @securityKeyUsePin.
  ///
  /// In en, this message translates to:
  /// **'Use PIN instead'**
  String get securityKeyUsePin;

  /// No description provided for @securityKeysNewPinBodyCount.
  ///
  /// In en, this message translates to:
  /// **'This key has no PIN yet. Choose one with at least {count} characters. {appName} requires it, so a key found by someone else cannot open your wallet.'**
  String securityKeysNewPinBodyCount(int count, String appName);

  /// No description provided for @securityKeysPinTooShortCount.
  ///
  /// In en, this message translates to:
  /// **'Use at least {count} characters.'**
  String securityKeysPinTooShortCount(int count);

  /// No description provided for @securityKeyCheckingPin.
  ///
  /// In en, this message translates to:
  /// **'Checking your PIN…'**
  String get securityKeyCheckingPin;

  /// No description provided for @securityKeyWorking.
  ///
  /// In en, this message translates to:
  /// **'One moment…'**
  String get securityKeyWorking;

  /// No description provided for @securityKeyKeepHolding.
  ///
  /// In en, this message translates to:
  /// **'Keep your key against the phone.'**
  String get securityKeyKeepHolding;

  /// No description provided for @securityKeyHoldAgain.
  ///
  /// In en, this message translates to:
  /// **'Hold your key to your phone again'**
  String get securityKeyHoldAgain;

  /// No description provided for @securityKeyConnectAgain.
  ///
  /// In en, this message translates to:
  /// **'Connect your key again'**
  String get securityKeyConnectAgain;

  /// No description provided for @securityKeyTouchToConfirm.
  ///
  /// In en, this message translates to:
  /// **'Touch your key to confirm'**
  String get securityKeyTouchToConfirm;

  /// No description provided for @securityKeyTouchOnceMore.
  ///
  /// In en, this message translates to:
  /// **'Touch your key once more'**
  String get securityKeyTouchOnceMore;

  /// No description provided for @securityKeyTouchToUnlock.
  ///
  /// In en, this message translates to:
  /// **'Touch your key to unlock'**
  String get securityKeyTouchToUnlock;

  /// No description provided for @securityKeyFingerprintToConfirm.
  ///
  /// In en, this message translates to:
  /// **'Touch the fingerprint sensor'**
  String get securityKeyFingerprintToConfirm;

  /// No description provided for @securityKeyFingerprintOnceMore.
  ///
  /// In en, this message translates to:
  /// **'Touch the sensor once more'**
  String get securityKeyFingerprintOnceMore;

  /// No description provided for @securityKeyFingerprintToUnlock.
  ///
  /// In en, this message translates to:
  /// **'Touch the sensor to unlock'**
  String get securityKeyFingerprintToUnlock;

  /// No description provided for @securityKeyFingerprintBody.
  ///
  /// In en, this message translates to:
  /// **'Use a finger you enrolled on this YubiKey Bio.'**
  String get securityKeyFingerprintBody;

  /// No description provided for @securityKeyTouchCount.
  ///
  /// In en, this message translates to:
  /// **'Touch {current} of {total}'**
  String securityKeyTouchCount(int current, int total);

  /// No description provided for @securityKeyAddedTitle.
  ///
  /// In en, this message translates to:
  /// **'Key added'**
  String get securityKeyAddedTitle;

  /// No description provided for @securityKeyNameBody.
  ///
  /// In en, this message translates to:
  /// **'Give it a name so you can tell your keys apart.'**
  String get securityKeyNameBody;

  /// No description provided for @securityKeySaveName.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get securityKeySaveName;

  /// No description provided for @securityKeysErrorKeyUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This key cannot protect a wallet. Use a YubiKey 5 series key or a YubiKey Bio.'**
  String get securityKeysErrorKeyUnsupported;

  /// No description provided for @securityKeysErrorPinChangeRequired.
  ///
  /// In en, this message translates to:
  /// **'This key wants a new PIN first. Change it in the Yubico Authenticator app, then try again.'**
  String get securityKeysErrorPinChangeRequired;

  /// No description provided for @securityKeysErrorUvInvalid.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Fingerprint not recognized. 1 try left.} other{Fingerprint not recognized. {count} tries left.}}'**
  String securityKeysErrorUvInvalid(int count);

  /// No description provided for @securityKeysErrorUvInvalidUnknown.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint not recognized.'**
  String get securityKeysErrorUvInvalidUnknown;

  /// No description provided for @securityKeysErrorUvBlocked.
  ///
  /// In en, this message translates to:
  /// **'The fingerprint reader on this key is locked. Enter the key\'s PIN instead.'**
  String get securityKeysErrorUvBlocked;

  /// No description provided for @securityKeysErrorUvNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'This key has no fingerprint set up. Enter its PIN instead.'**
  String get securityKeysErrorUvNotConfigured;

  /// No description provided for @securityKeyPinTitleNamed.
  ///
  /// In en, this message translates to:
  /// **'Enter the PIN for {name}'**
  String securityKeyPinTitleNamed(String name);

  /// No description provided for @securityKeysSerial.
  ///
  /// In en, this message translates to:
  /// **'Serial {serial}'**
  String securityKeysSerial(String serial);

  /// No description provided for @securityKeysErrorDifferentKey.
  ///
  /// In en, this message translates to:
  /// **'That is a different key from the one you touched. Start again with the key you want to use.'**
  String get securityKeysErrorDifferentKey;

  /// Cancel button in the security key sheets.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get securityKeysCancel;

  /// Shown when the PIN field is submitted empty.
  ///
  /// In en, this message translates to:
  /// **'This field cannot be empty.'**
  String get securityKeysPinEmpty;

  /// Advanced security: the same recovery phrase in two apps is only as protected as the weaker app.
  ///
  /// In en, this message translates to:
  /// **'Using this recovery phrase in another wallet app too? Protect that app as well. Once unlocked, either app can show the phrase, so it is only as safe as the less protected one.'**
  String get securityKeysSharedPhraseWarning;
}

class _FhseLocalizationsDelegate extends LocalizationsDelegate<FhseLocalizations> {
  const _FhseLocalizationsDelegate();

  @override
  Future<FhseLocalizations> load(Locale locale) {
    return SynchronousFuture<FhseLocalizations>(lookupFhseLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_FhseLocalizationsDelegate old) => false;
}

FhseLocalizations lookupFhseLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return FhseLocalizationsEn();
    case 'pt':
      return FhseLocalizationsPt();
  }

  throw FlutterError(
    'FhseLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
