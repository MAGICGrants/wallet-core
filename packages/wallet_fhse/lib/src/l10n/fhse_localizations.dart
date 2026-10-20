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
  /// **'Advanced Security'**
  String get advancedSecurityLabel;

  /// No description provided for @advancedSecurityTitle.
  ///
  /// In en, this message translates to:
  /// **'Advanced Security'**
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

  /// No description provided for @advancedSecurityNeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'Needs attention'**
  String get advancedSecurityNeedsAttention;

  /// No description provided for @securityKeysUnreadableTitle.
  ///
  /// In en, this message translates to:
  /// **'Set up your security keys again'**
  String get securityKeysUnreadableTitle;

  /// No description provided for @securityKeysUnreadableBody.
  ///
  /// In en, this message translates to:
  /// **'This happens after moving to a new phone. Your wallet is safe and your recovery phrase still opens it. Set up your keys again, or turn security keys off.'**
  String get securityKeysUnreadableBody;

  /// No description provided for @securityKeysLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load your security key settings.'**
  String get securityKeysLoadFailed;

  /// No description provided for @securityKeysIntroTitle.
  ///
  /// In en, this message translates to:
  /// **'Protect this wallet with a security key'**
  String get securityKeysIntroTitle;

  /// No description provided for @securityKeysIntroBody.
  ///
  /// In en, this message translates to:
  /// **'Advanced Security is another layer of protection for your wallet beyond the App Lock. When enabled, your wallet can only be opened with your security key and its PIN.'**
  String get securityKeysIntroBody;

  /// No description provided for @securityKeysRequirements.
  ///
  /// In en, this message translates to:
  /// **'Works with most FIDO2 capable hardware security keys over NFC. Over USB, only YubiKeys work for now (on iPhone, with firmware 5.8 or later).'**
  String get securityKeysRequirements;

  /// No description provided for @securityKeysSetUpButton.
  ///
  /// In en, this message translates to:
  /// **'Set up security keys'**
  String get securityKeysSetUpButton;

  /// No description provided for @securityKeysUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Security keys only work with a wallet created or restored in this version of {appName}.'**
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
  /// **'You have only one key. Add a second one as a backup. Without a key, you\'ll need your recovery phrase.'**
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
  /// **'Set up again without that key'**
  String get securityKeysRemoveSubtitle;

  /// No description provided for @securityKeysRemoveLink.
  ///
  /// In en, this message translates to:
  /// **'Set up'**
  String get securityKeysRemoveLink;

  /// No description provided for @securityKeysRemoveExplain.
  ///
  /// In en, this message translates to:
  /// **'To remove a key, set up again with only the keys you want to keep. Any key you leave out stops working. Have all the keys you\'re keeping with you.'**
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
  /// **'Your wallet will open without a security key again.'**
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
  /// **'After this long in the background, {appName} fully locks the wallet. You\'ll need a security key to open it again.'**
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
  /// **'While locked, the wallet keeps syncing and can show new payments, but it can\'t spend.'**
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
  /// **'Add only the keys you want to keep. Any key you leave out stops working.'**
  String get securityKeysSetupAgainNote;

  /// Set up security keys screen, first setup: the one line above the keys added so far.
  ///
  /// In en, this message translates to:
  /// **'Add each security key you want to use, then tap Finish.'**
  String get securityKeysSetupNote;

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
  /// **'Use only one key?'**
  String get securityKeysOneKeyTitle;

  /// No description provided for @securityKeysOneKeyBody.
  ///
  /// In en, this message translates to:
  /// **'We recommend at least two. If you lose your only key, you\'ll need your recovery phrase.'**
  String get securityKeysOneKeyBody;

  /// No description provided for @securityKeysFinishAnyway.
  ///
  /// In en, this message translates to:
  /// **'Use one key'**
  String get securityKeysFinishAnyway;

  /// No description provided for @securityKeysNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Key name'**
  String get securityKeysNameLabel;

  /// No description provided for @securityKeysNameDefault.
  ///
  /// In en, this message translates to:
  /// **'Security key {number}'**
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
  /// **'The PINs don\'t match.'**
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
  /// **'This key is locked after too many wrong PINs. It can only be reset, and a reset key no longer opens any wallet.'**
  String get securityKeysErrorPinBlocked;

  /// No description provided for @securityKeysErrorPinAuthBlocked.
  ///
  /// In en, this message translates to:
  /// **'Too many wrong PINs. Disconnect the key and connect it again.'**
  String get securityKeysErrorPinAuthBlocked;

  /// No description provided for @securityKeysErrorPinPolicy.
  ///
  /// In en, this message translates to:
  /// **'The key didn\'t accept that PIN. Some keys need 6 or more characters.'**
  String get securityKeysErrorPinPolicy;

  /// No description provided for @securityKeysErrorNotEnrolled.
  ///
  /// In en, this message translates to:
  /// **'This key isn\'t set up for this wallet.'**
  String get securityKeysErrorNotEnrolled;

  /// No description provided for @securityKeysErrorNotThisWallet.
  ///
  /// In en, this message translates to:
  /// **'Your security key settings don\'t match this wallet. Open it with your recovery phrase, then set up your keys again.'**
  String get securityKeysErrorNotThisWallet;

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
  /// **'Lost the connection to your key. Try again.'**
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
  /// **'Open the wallet with your recovery phrase, then set up new keys in Settings.'**
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
  /// **'That recovery phrase doesn\'t match this wallet.'**
  String get securityKeyRecoveryWrongPhrase;

  /// No description provided for @securityKeyRecoveryNotPossible.
  ///
  /// In en, this message translates to:
  /// **'This wallet was restored from a 25-word recovery phrase, which can\'t unlock it here. Delete the wallet, then restore it from that phrase.'**
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
  /// **'Plug in your security key and touch it when it blinks, or hold it flat against the back of your phone.'**
  String get securityKeyConnectBodyAndroid;

  /// No description provided for @securityKeyConnectBodyIos.
  ///
  /// In en, this message translates to:
  /// **'Hold your security key near the top of your iPhone, or plug it in and touch it when it blinks.'**
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
  /// **'Connecting to your key…'**
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
  /// **'Touch your security key while it blinks.'**
  String get securityKeyTouchBody;

  /// No description provided for @securityKeyPinTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your key\'s PIN'**
  String get securityKeyPinTitle;

  /// No description provided for @securityKeyPinBody.
  ///
  /// In en, this message translates to:
  /// **'This is your security key\'s PIN, not your phone\'s passcode.'**
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
  /// **'This key doesn\'t have a PIN yet. Choose one with at least {count} characters, so someone who finds your key can\'t use it.'**
  String securityKeysNewPinBodyCount(int count);

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
  /// **'Keep holding your key to the phone.'**
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
  /// **'Use a finger you added to this security key.'**
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
  /// **'This security key isn\'t supported. Try a different one.'**
  String get securityKeysErrorKeyUnsupported;

  /// No description provided for @securityKeysErrorPinChangeRequired.
  ///
  /// In en, this message translates to:
  /// **'This security key needs a new PIN first. Change it with the key maker\'s app, then try again.'**
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
  /// **'Fingerprint is locked on this key. Enter its PIN instead.'**
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
  /// **'This isn\'t the key you touched. Start again with the key you want to use.'**
  String get securityKeysErrorDifferentKey;

  /// No description provided for @securityKeysErrorMultipleKeys.
  ///
  /// In en, this message translates to:
  /// **'More than one security key is plugged in. Unplug the others, then try again.'**
  String get securityKeysErrorMultipleKeys;

  /// Linux/Windows unlock: the wallet files are bound to a PC's TPM that this PC cannot use (another computer, or a cleared TPM).
  ///
  /// In en, this message translates to:
  /// **'This wallet can\'t be opened on this PC. If you created it on this PC, restart the PC and try again. Otherwise, restore the wallet from its recovery phrase.'**
  String get unlockBoundToAnotherPc;

  /// Cancel button in the security key sheets.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get securityKeysCancel;

  /// Shown when the PIN field is submitted empty.
  ///
  /// In en, this message translates to:
  /// **'Enter your PIN.'**
  String get securityKeysPinEmpty;

  /// Advanced Security: the wallet is only as safe as its least protected copy, so protect the recovery phrase and every device that has the wallet.
  ///
  /// In en, this message translates to:
  /// **'Your wallet is only as strong as the weakest protection. Make sure your recovery phrase is saved safely, and if you use the same wallet on multiple devices, make sure to set up Advanced Security there too.'**
  String get securityKeysSharedPhraseWarning;

  /// No description provided for @securityKeysRequirementsMac.
  ///
  /// In en, this message translates to:
  /// **'Works with most FIDO2 capable hardware security keys.'**
  String get securityKeysRequirementsMac;

  /// No description provided for @securityKeyConnectBodyMac.
  ///
  /// In en, this message translates to:
  /// **'Plug your security key into this Mac and touch it when it blinks.'**
  String get securityKeyConnectBodyMac;

  /// No description provided for @securityKeyPinBodyMac.
  ///
  /// In en, this message translates to:
  /// **'This is your security key\'s PIN, not your Mac\'s password.'**
  String get securityKeyPinBodyMac;

  /// No description provided for @desktopAutoLockLabel.
  ///
  /// In en, this message translates to:
  /// **'Lock after'**
  String get desktopAutoLockLabel;

  /// No description provided for @desktopAutoLockDescription.
  ///
  /// In en, this message translates to:
  /// **'After this long without use, {appName} locks the wallet. Unlock it to continue.'**
  String desktopAutoLockDescription(String appName);

  /// No description provided for @securityKeysRequirementsLinux.
  ///
  /// In en, this message translates to:
  /// **'Works with most FIDO2 capable hardware security keys. Needs libfido2, which most Linux systems already have.'**
  String get securityKeysRequirementsLinux;

  /// No description provided for @securityKeysRequirementsWindows.
  ///
  /// In en, this message translates to:
  /// **'Works with most FIDO2 capable hardware security keys. Needs Windows 11 (22H2 or later).'**
  String get securityKeysRequirementsWindows;

  /// No description provided for @securityKeysTurnOffBodyDesktop.
  ///
  /// In en, this message translates to:
  /// **'Your password alone will open the wallet again.'**
  String get securityKeysTurnOffBodyDesktop;

  /// No description provided for @securityKeyConnectBodyDesktop.
  ///
  /// In en, this message translates to:
  /// **'Plug your security key into this computer and touch it when it blinks.'**
  String get securityKeyConnectBodyDesktop;

  /// No description provided for @securityKeyConnectBodyWindows.
  ///
  /// In en, this message translates to:
  /// **'Windows asks for your security key, its PIN, and a touch.'**
  String get securityKeyConnectBodyWindows;

  /// No description provided for @securityKeyPinBodyDesktop.
  ///
  /// In en, this message translates to:
  /// **'This is your security key\'s PIN, not your wallet password.'**
  String get securityKeyPinBodyDesktop;

  /// No description provided for @securityKeyWindowsPromptTitle.
  ///
  /// In en, this message translates to:
  /// **'Continue in Windows Security'**
  String get securityKeyWindowsPromptTitle;

  /// No description provided for @securityKeyWindowsPromptBody.
  ///
  /// In en, this message translates to:
  /// **'Enter your security key\'s PIN, then touch the key.'**
  String get securityKeyWindowsPromptBody;

  /// No description provided for @securityKeyWindowsPromptEnrollBody.
  ///
  /// In en, this message translates to:
  /// **'Windows will ask twice. Each time, enter your security key\'s PIN, then touch the key.'**
  String get securityKeyWindowsPromptEnrollBody;

  /// No description provided for @securityKeyWindowsWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for Windows Security…'**
  String get securityKeyWindowsWaiting;

  /// No description provided for @securityKeyUseButton.
  ///
  /// In en, this message translates to:
  /// **'Use security key'**
  String get securityKeyUseButton;

  /// No description provided for @advancedSecurityAuthReason.
  ///
  /// In en, this message translates to:
  /// **'Confirm it\'s you to open Advanced Security'**
  String get advancedSecurityAuthReason;

  /// No description provided for @advancedSecurityAuthFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t confirm it\'s you.'**
  String get advancedSecurityAuthFailed;

  /// No description provided for @advancedSecurityPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your password'**
  String get advancedSecurityPasswordTitle;

  /// No description provided for @advancedSecurityPasswordBody.
  ///
  /// In en, this message translates to:
  /// **'Enter the password you use to unlock {appName}.'**
  String advancedSecurityPasswordBody(String appName);

  /// No description provided for @advancedSecurityPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get advancedSecurityPasswordLabel;

  /// No description provided for @advancedSecurityPasswordWrong.
  ///
  /// In en, this message translates to:
  /// **'Incorrect password.'**
  String get advancedSecurityPasswordWrong;

  /// No description provided for @advancedSecurityContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get advancedSecurityContinue;

  /// No description provided for @appLockLabel.
  ///
  /// In en, this message translates to:
  /// **'App Lock'**
  String get appLockLabel;

  /// No description provided for @appLockImmediately.
  ///
  /// In en, this message translates to:
  /// **'Immediately'**
  String get appLockImmediately;

  /// No description provided for @appLockDescriptionPhone.
  ///
  /// In en, this message translates to:
  /// **'How long {appName} can be in the background before it asks for your face, fingerprint or passcode again.'**
  String appLockDescriptionPhone(String appName);

  /// No description provided for @appLockDescriptionMac.
  ///
  /// In en, this message translates to:
  /// **'How long {appName} can go unused before it asks for Touch ID or your Mac\'s password again. Immediately locks it as soon as its window is hidden. The wallet keeps syncing.'**
  String appLockDescriptionMac(String appName);

  /// No description provided for @appLockDescriptionPassword.
  ///
  /// In en, this message translates to:
  /// **'How long {appName} can go unused before it asks for your password again. Immediately locks it as soon as its window is hidden. The wallet keeps syncing.'**
  String appLockDescriptionPassword(String appName);

  /// No description provided for @appLockNoDeviceLock.
  ///
  /// In en, this message translates to:
  /// **'This device has no screen lock, so anyone holding it can open {appName}. Set a passcode or screen lock in the device\'s settings.'**
  String appLockNoDeviceLock(String appName);

  /// No description provided for @lockLaterAuthReason.
  ///
  /// In en, this message translates to:
  /// **'Confirm it\'s you to lock {appName} less often'**
  String lockLaterAuthReason(String appName);

  /// No description provided for @lockLaterPasswordBody.
  ///
  /// In en, this message translates to:
  /// **'A longer time leaves {appName} open for longer. Enter the password you unlock it with.'**
  String lockLaterPasswordBody(String appName);

  /// No description provided for @appLockUseRecoveryPhraseBody.
  ///
  /// In en, this message translates to:
  /// **'If this device can\'t confirm it\'s you, your recovery phrase opens {appName} instead.'**
  String appLockUseRecoveryPhraseBody(String appName);
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
