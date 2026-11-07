import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'wallet_ui_localizations_en.dart';
import 'wallet_ui_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of WalletUiLocalizations
/// returned by `WalletUiLocalizations.of(context)`.
///
/// Applications need to include `WalletUiLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/wallet_ui_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: WalletUiLocalizations.localizationsDelegates,
///   supportedLocales: WalletUiLocalizations.supportedLocales,
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
/// be consistent with the languages listed in the WalletUiLocalizations.supportedLocales
/// property.
abstract class WalletUiLocalizations {
  WalletUiLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static WalletUiLocalizations of(BuildContext context) {
    return Localizations.of<WalletUiLocalizations>(context, WalletUiLocalizations)!;
  }

  static const LocalizationsDelegate<WalletUiLocalizations> delegate =
      _WalletUiLocalizationsDelegate();

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

  /// Screen title. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Restore Wallet'**
  String get restoreWalletTitle;

  /// Screen title. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Verify Recovery Phrase'**
  String get verifySeedTitle;

  /// Choice title on Wallet Setup; the app's own line under it says what kind of phrase it makes. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Create New Wallet'**
  String get createNewWalletChoice;

  /// Choice title on Wallet Setup; the app's own line under it says which phrases it takes. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Restore Existing Wallet'**
  String get restoreExistingWalletChoice;

  /// Choice title for reaching a service (prices, OpenAlias) without Tor; its description says it is not private. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Clearnet-Only'**
  String get clearnetOnlyChoice;

  /// Empty state of a transaction list. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'No transactions'**
  String get noTransactions;

  /// Empty state of the address book. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'No contacts yet'**
  String get addressBookNoContacts;

  /// Empty state of an address book search. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'No contacts found'**
  String get addressBookNoSearchResults;

  /// Checkbox under a new recovery phrase. Sentence case. count is the phrase's word count, 0 while it is unknown.
  ///
  /// In en, this message translates to:
  /// **'I have written down {count, plural, =0{all the words} other{all {count} words}} and stored them somewhere only I can reach.'**
  String generateSeedConfirm(int count);

  /// Why the system unlock prompt is shown; the system sets it as a message. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'Unlock wallet'**
  String get unlockWalletReason;

  /// Checkbox under External Tor that fills in Orbot's port, on Android. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'Use Orbot/InviZible'**
  String get torUseOrbotLabel;

  /// The same checkbox on iOS, where InviZible does not exist. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'Use Orbot'**
  String get torUseOrbotLabelIos;

  /// No description provided for @continueText.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueText;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @unknownError.
  ///
  /// In en, this message translates to:
  /// **'Unknown error.'**
  String get unknownError;

  /// No description provided for @warning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get warning;

  /// No description provided for @amount.
  ///
  /// In en, this message translates to:
  /// **'Amount'**
  String get amount;

  /// No description provided for @networkFee.
  ///
  /// In en, this message translates to:
  /// **'Network Fee'**
  String get networkFee;

  /// No description provided for @address.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get address;

  /// No description provided for @pending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get pending;

  /// No description provided for @unconfirmed.
  ///
  /// In en, this message translates to:
  /// **'Unconfirmed'**
  String get unconfirmed;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @addressCopied.
  ///
  /// In en, this message translates to:
  /// **'Address copied to clipboard'**
  String get addressCopied;

  /// No description provided for @copiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copiedToClipboard;

  /// No description provided for @fieldEmptyError.
  ///
  /// In en, this message translates to:
  /// **'This field cannot be empty.'**
  String get fieldEmptyError;

  /// No description provided for @settingsLicensesLabel.
  ///
  /// In en, this message translates to:
  /// **'Open-Source Licenses'**
  String get settingsLicensesLabel;

  /// No description provided for @torChoiceTitle.
  ///
  /// In en, this message translates to:
  /// **'Tor Connection Setup'**
  String get torChoiceTitle;

  /// No description provided for @torChoiceBuiltInDesc.
  ///
  /// In en, this message translates to:
  /// **'Bundled with {appName} Wallet · recommended'**
  String torChoiceBuiltInDesc(String appName);

  /// No description provided for @torChoiceExternalDesc.
  ///
  /// In en, this message translates to:
  /// **'Orbot, or a daemon you run yourself'**
  String get torChoiceExternalDesc;

  /// No description provided for @torChoiceNoTorDesc.
  ///
  /// In en, this message translates to:
  /// **'Servers you connect to can see your IP address'**
  String get torChoiceNoTorDesc;

  /// No description provided for @torChoiceTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Test failed'**
  String get torChoiceTestFailed;

  /// No description provided for @torChoiceConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected to Tor'**
  String get torChoiceConnected;

  /// No description provided for @connectionTypeLws.
  ///
  /// In en, this message translates to:
  /// **'Light Wallet Server'**
  String get connectionTypeLws;

  /// No description provided for @connectionTypeNode.
  ///
  /// In en, this message translates to:
  /// **'Monero Node'**
  String get connectionTypeNode;

  /// No description provided for @lwsSetupUseTorLabel.
  ///
  /// In en, this message translates to:
  /// **'Use Tor'**
  String get lwsSetupUseTorLabel;

  /// No description provided for @lwsSetupTestConnectionButton.
  ///
  /// In en, this message translates to:
  /// **'Test Connection'**
  String get lwsSetupTestConnectionButton;

  /// No description provided for @connectionTestingTitle.
  ///
  /// In en, this message translates to:
  /// **'Testing connection'**
  String get connectionTestingTitle;

  /// No description provided for @connectionTestingDetail.
  ///
  /// In en, this message translates to:
  /// **'Checking whether the server answers.'**
  String get connectionTestingDetail;

  /// No description provided for @connectionTestStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get connectionTestStop;

  /// No description provided for @connectionResultWorksTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection works'**
  String get connectionResultWorksTitle;

  /// No description provided for @connectionReachedOverTor.
  ///
  /// In en, this message translates to:
  /// **'Reached over Tor'**
  String get connectionReachedOverTor;

  /// No description provided for @connectionReachedViaProxy.
  ///
  /// In en, this message translates to:
  /// **'Reached through your proxy'**
  String get connectionReachedViaProxy;

  /// No description provided for @connectionReachedDirect.
  ///
  /// In en, this message translates to:
  /// **'Reached directly'**
  String get connectionReachedDirect;

  /// No description provided for @connectionResultFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not reach this server'**
  String get connectionResultFailedTitle;

  /// No description provided for @connectionResultFailedDetail.
  ///
  /// In en, this message translates to:
  /// **'Nothing answered. Check the address and port, and whether the server accepts your connection.'**
  String get connectionResultFailedDetail;

  /// No description provided for @connectionTestAgain.
  ///
  /// In en, this message translates to:
  /// **'Test Again'**
  String get connectionTestAgain;

  /// No description provided for @lwsSetupStartingTor.
  ///
  /// In en, this message translates to:
  /// **'Starting Tor...'**
  String get lwsSetupStartingTor;

  /// No description provided for @lwsSetupContinueButton.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get lwsSetupContinueButton;

  /// No description provided for @fiatApiSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Price Display Setup'**
  String get fiatApiSetupTitle;

  /// No description provided for @fiatApiSettingsModeLabel.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get fiatApiSettingsModeLabel;

  /// No description provided for @fiatApiSettingsModeTorOnly.
  ///
  /// In en, this message translates to:
  /// **'Tor-Only'**
  String get fiatApiSettingsModeTorOnly;

  /// No description provided for @fiatApiSettingsModeDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get fiatApiSettingsModeDisabled;

  /// No description provided for @fiatModeTorOnlyDesc.
  ///
  /// In en, this message translates to:
  /// **'Prices fetched over Tor · recommended'**
  String get fiatModeTorOnlyDesc;

  /// No description provided for @fiatModeClearnetDesc.
  ///
  /// In en, this message translates to:
  /// **'Not private, the price server sees your IP address'**
  String get fiatModeClearnetDesc;

  /// No description provided for @fiatModeDisabledDesc.
  ///
  /// In en, this message translates to:
  /// **'No prices fetched, balances shown in crypto only'**
  String get fiatModeDisabledDesc;

  /// No description provided for @settingsOpenAliasSettingsLabel.
  ///
  /// In en, this message translates to:
  /// **'OpenAlias Settings'**
  String get settingsOpenAliasSettingsLabel;

  /// No description provided for @openAliasSettingsSheetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'How names like name@example.com are looked up when you send.'**
  String get openAliasSettingsSheetSubtitle;

  /// No description provided for @openAliasModeTorOnlyDesc.
  ///
  /// In en, this message translates to:
  /// **'Names looked up over Tor · recommended'**
  String get openAliasModeTorOnlyDesc;

  /// No description provided for @openAliasModeClearnetDesc.
  ///
  /// In en, this message translates to:
  /// **'Not private, DNS servers see your IP address and the name'**
  String get openAliasModeClearnetDesc;

  /// No description provided for @openAliasModeDisabledDesc.
  ///
  /// In en, this message translates to:
  /// **'No lookups, send to addresses only'**
  String get openAliasModeDisabledDesc;

  /// No description provided for @fiatApiSettingsDisplayCurrencyLabel.
  ///
  /// In en, this message translates to:
  /// **'Display Currency'**
  String get fiatApiSettingsDisplayCurrencyLabel;

  /// No description provided for @settingsFiatApiSettingsLabel.
  ///
  /// In en, this message translates to:
  /// **'Price Display Settings'**
  String get settingsFiatApiSettingsLabel;

  /// Price Display Settings sheet description, under its title. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'How prices are fetched, and the currency they are shown in.'**
  String get fiatApiSettingsSheetSubtitle;

  /// No description provided for @createWalletTitle.
  ///
  /// In en, this message translates to:
  /// **'Wallet Setup'**
  String get createWalletTitle;

  /// No description provided for @createWalletPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Create Wallet Password'**
  String get createWalletPasswordTitle;

  /// No description provided for @createWalletPasswordDescription.
  ///
  /// In en, this message translates to:
  /// **'Create a password to protect your wallet. This password will be required to unlock your wallet.'**
  String get createWalletPasswordDescription;

  /// No description provided for @createWalletPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your password'**
  String get createWalletPasswordHint;

  /// No description provided for @createWalletConfirmPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Confirm your password'**
  String get createWalletConfirmPasswordHint;

  /// No description provided for @passwordTooShortError.
  ///
  /// In en, this message translates to:
  /// **'Password must be at least 8 characters long.'**
  String get passwordTooShortError;

  /// No description provided for @passwordsDoNotMatchError.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match.'**
  String get passwordsDoNotMatchError;

  /// No description provided for @generateSeedTitle.
  ///
  /// In en, this message translates to:
  /// **'Write These Down, in Order'**
  String get generateSeedTitle;

  /// No description provided for @generateSeedTitleCovered.
  ///
  /// In en, this message translates to:
  /// **'Recovery Phrase'**
  String get generateSeedTitleCovered;

  /// No description provided for @generateSeedSubtitleRevealed.
  ///
  /// In en, this message translates to:
  /// **'Securely save these. Do not share them.'**
  String get generateSeedSubtitleRevealed;

  /// No description provided for @generateSeedScreenshotNote.
  ///
  /// In en, this message translates to:
  /// **'Screenshots are blocked on this screen. Make sure nobody is looking over your shoulder.'**
  String get generateSeedScreenshotNote;

  /// No description provided for @generateSeedReveal.
  ///
  /// In en, this message translates to:
  /// **'Tap to Reveal'**
  String get generateSeedReveal;

  /// No description provided for @generateSeedBirthdayLabel.
  ///
  /// In en, this message translates to:
  /// **'Wallet Birthday'**
  String get generateSeedBirthdayLabel;

  /// No description provided for @generateSeedBirthdayReason.
  ///
  /// In en, this message translates to:
  /// **'Where a future restore starts scanning'**
  String get generateSeedBirthdayReason;

  /// No description provided for @onboardingPriceNoteRatesOnly.
  ///
  /// In en, this message translates to:
  /// **'Only prices are requested. Your addresses and balances are not sent.'**
  String get onboardingPriceNoteRatesOnly;

  /// No description provided for @onboardingPriceNoteTor.
  ///
  /// In en, this message translates to:
  /// **'Prices are fetched over Tor by default.'**
  String get onboardingPriceNoteTor;

  /// No description provided for @onboardingTorNotePrivacy.
  ///
  /// In en, this message translates to:
  /// **'Connections over Tor can be slower.'**
  String get onboardingTorNotePrivacy;

  /// No description provided for @onboardingTorNoteChangeable.
  ///
  /// In en, this message translates to:
  /// **'You can change this later in Settings.'**
  String get onboardingTorNoteChangeable;

  /// No description provided for @onboardingPasswordNoteLaunch.
  ///
  /// In en, this message translates to:
  /// **'You need this password to open your wallet and to view your recovery phrase.'**
  String get onboardingPasswordNoteLaunch;

  /// No description provided for @onboardingPasswordNoteNotCloud.
  ///
  /// In en, this message translates to:
  /// **'This password can\'t be recovered. If you lose it, restore your wallet from your recovery phrase.'**
  String get onboardingPasswordNoteNotCloud;

  /// No description provided for @onboardingPasswordStrong.
  ///
  /// In en, this message translates to:
  /// **'Strong'**
  String get onboardingPasswordStrong;

  /// No description provided for @onboardingPasswordMatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords match'**
  String get onboardingPasswordMatch;

  /// No description provided for @onboardingWalletNoteGenerated.
  ///
  /// In en, this message translates to:
  /// **'{appName} Wallet generates your recovery phrase on this device.'**
  String onboardingWalletNoteGenerated(String appName);

  /// No description provided for @onboardingWalletNoteRestore.
  ///
  /// In en, this message translates to:
  /// **'When restoring, a scan-from date makes syncing faster.'**
  String get onboardingWalletNoteRestore;

  /// No description provided for @lwsDetailsDescription.
  ///
  /// In en, this message translates to:
  /// **'If your Monero light wallet server (LWS) requires registration, you can use these details to add this wallet to that server. Not all servers require registration.'**
  String get lwsDetailsDescription;

  /// No description provided for @restoreWalletSeedLength.
  ///
  /// In en, this message translates to:
  /// **'Number of Words'**
  String get restoreWalletSeedLength;

  /// No description provided for @restoreWalletPaste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get restoreWalletPaste;

  /// No description provided for @restoreWalletScanFrom.
  ///
  /// In en, this message translates to:
  /// **'Scan From'**
  String get restoreWalletScanFrom;

  /// No description provided for @restoreWalletScanFromReason.
  ///
  /// In en, this message translates to:
  /// **'Skip irrelevant history to save time'**
  String get restoreWalletScanFromReason;

  /// No description provided for @restoreWalletNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get restoreWalletNotSet;

  /// No description provided for @restoreScanTitle.
  ///
  /// In en, this message translates to:
  /// **'When Did This Wallet First Receive Funds?'**
  String get restoreScanTitle;

  /// No description provided for @restoreScanPickMonth.
  ///
  /// In en, this message translates to:
  /// **'Pick a Month'**
  String get restoreScanPickMonth;

  /// No description provided for @restoreScanNotSure.
  ///
  /// In en, this message translates to:
  /// **'I\'m Not Sure'**
  String get restoreScanNotSure;

  /// No description provided for @restoreScanNotSureDesc.
  ///
  /// In en, this message translates to:
  /// **'Scan everything. Slower this first setup but not any slower later. Always complete.'**
  String get restoreScanNotSureDesc;

  /// No description provided for @restoreScanFromStart.
  ///
  /// In en, this message translates to:
  /// **'Genesis'**
  String get restoreScanFromStart;

  /// No description provided for @restoreScanDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get restoreScanDone;

  /// No description provided for @restoreWalletBadWord.
  ///
  /// In en, this message translates to:
  /// **'Word {position} isn\'t a BIP39 word.'**
  String restoreWalletBadWord(int position);

  /// No description provided for @restoreWalletDidYouMean.
  ///
  /// In en, this message translates to:
  /// **'Did you mean {word}?'**
  String restoreWalletDidYouMean(String word);

  /// No description provided for @restoreWalletChecksumError.
  ///
  /// In en, this message translates to:
  /// **'This isn\'t a valid recovery phrase — check the words and their order.'**
  String get restoreWalletChecksumError;

  /// No description provided for @restoreWalletRestoreButton.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get restoreWalletRestoreButton;

  /// No description provided for @navigationBarSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navigationBarSettings;

  /// No description provided for @navigationBarHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get navigationBarHistory;

  /// No description provided for @historyTitle.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get historyTitle;

  /// No description provided for @historyExportCsv.
  ///
  /// In en, this message translates to:
  /// **'Export CSV'**
  String get historyExportCsv;

  /// No description provided for @historyExported.
  ///
  /// In en, this message translates to:
  /// **'History exported'**
  String get historyExported;

  /// No description provided for @historyExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not export the history'**
  String get historyExportFailed;

  /// History filter: received or sent.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get historyFilterType;

  /// No description provided for @historyFilterReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get historyFilterReset;

  /// No description provided for @unlockButton.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get unlockButton;

  /// No description provided for @unlockUnableToAuthError.
  ///
  /// In en, this message translates to:
  /// **'Unable to authenticate.'**
  String get unlockUnableToAuthError;

  /// No description provided for @unlockWithFaceId.
  ///
  /// In en, this message translates to:
  /// **'Unlock With Face ID'**
  String get unlockWithFaceId;

  /// No description provided for @unlockWithTouchId.
  ///
  /// In en, this message translates to:
  /// **'Unlock With Touch ID'**
  String get unlockWithTouchId;

  /// No description provided for @unlockPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your password'**
  String get unlockPasswordHint;

  /// No description provided for @unlockIncorrectPasswordError.
  ///
  /// In en, this message translates to:
  /// **'Incorrect password. Please try again.'**
  String get unlockIncorrectPasswordError;

  /// No description provided for @homeSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing'**
  String get homeSyncing;

  /// No description provided for @homeSynced.
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get homeSynced;

  /// No description provided for @homeTorConnected.
  ///
  /// In en, this message translates to:
  /// **'Tor · connected'**
  String get homeTorConnected;

  /// No description provided for @homeTorConnecting.
  ///
  /// In en, this message translates to:
  /// **'Tor · connecting'**
  String get homeTorConnecting;

  /// No description provided for @homeTorDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Tor · disconnected'**
  String get homeTorDisconnected;

  /// No description provided for @homeTorOff.
  ///
  /// In en, this message translates to:
  /// **'Tor · off'**
  String get homeTorOff;

  /// No description provided for @homeTorExternalConnected.
  ///
  /// In en, this message translates to:
  /// **'External Tor · connected'**
  String get homeTorExternalConnected;

  /// No description provided for @homeTorExternalConnecting.
  ///
  /// In en, this message translates to:
  /// **'External Tor · connecting'**
  String get homeTorExternalConnecting;

  /// No description provided for @homeTorExternalDisconnected.
  ///
  /// In en, this message translates to:
  /// **'External Tor · disconnected'**
  String get homeTorExternalDisconnected;

  /// No description provided for @homeBlocksRemaining.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 block left} other{{count} blocks left}}'**
  String homeBlocksRemaining(int count);

  /// No description provided for @coinHomeActivityTitle.
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get coinHomeActivityTitle;

  /// No description provided for @coinHomeSwap.
  ///
  /// In en, this message translates to:
  /// **'Swap'**
  String get coinHomeSwap;

  /// No description provided for @coinHomeSwapComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon!'**
  String get coinHomeSwapComingSoon;

  /// No description provided for @coinHomeReceived.
  ///
  /// In en, this message translates to:
  /// **'Received'**
  String get coinHomeReceived;

  /// No description provided for @coinHomeSent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get coinHomeSent;

  /// No description provided for @homeReceive.
  ///
  /// In en, this message translates to:
  /// **'Receive'**
  String get homeReceive;

  /// No description provided for @homeSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get homeSend;

  /// No description provided for @homeFiatApiError.
  ///
  /// In en, this message translates to:
  /// **'Error connecting to price server'**
  String get homeFiatApiError;

  /// No description provided for @receiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Receive'**
  String get receiveTitle;

  /// No description provided for @receivePrimaryAddressWarn.
  ///
  /// In en, this message translates to:
  /// **'Unless you know what you\'re doing, please use subaddresses for better privacy.'**
  String get receivePrimaryAddressWarn;

  /// No description provided for @receiveServerNoSubaddressesWarn.
  ///
  /// In en, this message translates to:
  /// **'This server does not support subaddresses. For better privacy, consider using a server that supports them.'**
  String get receiveServerNoSubaddressesWarn;

  /// No description provided for @receiveSubaddressUnavailableWarn.
  ///
  /// In en, this message translates to:
  /// **'You need to configure Monero to enable subaddresses, which better protect your privacy.'**
  String get receiveSubaddressUnavailableWarn;

  /// No description provided for @receiveMaxSubaddressesReachedWarn.
  ///
  /// In en, this message translates to:
  /// **'You have reached the maximum number of subaddresses supported by this server. This is a used address.'**
  String get receiveMaxSubaddressesReachedWarn;

  /// No description provided for @receiveSubaddressTab.
  ///
  /// In en, this message translates to:
  /// **'Subaddress'**
  String get receiveSubaddressTab;

  /// No description provided for @receivePrimaryTab.
  ///
  /// In en, this message translates to:
  /// **'Primary'**
  String get receivePrimaryTab;

  /// No description provided for @receiveCopyAddress.
  ///
  /// In en, this message translates to:
  /// **'Copy Address'**
  String get receiveCopyAddress;

  /// No description provided for @receiveEnlargeQr.
  ///
  /// In en, this message translates to:
  /// **'Tap to Enlarge and Brighten'**
  String get receiveEnlargeQr;

  /// No description provided for @receiveShrinkQr.
  ///
  /// In en, this message translates to:
  /// **'Tap to Shrink'**
  String get receiveShrinkQr;

  /// No description provided for @receiveShareError.
  ///
  /// In en, this message translates to:
  /// **'Could not open the share sheet'**
  String get receiveShareError;

  /// No description provided for @receiveAddressHeading.
  ///
  /// In en, this message translates to:
  /// **'Your {coin} Address'**
  String receiveAddressHeading(String coin);

  /// No description provided for @sendTitle.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get sendTitle;

  /// No description provided for @sendSendButton.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get sendSendButton;

  /// No description provided for @sendTransactionSuccessfullySent.
  ///
  /// In en, this message translates to:
  /// **'Transaction successfully sent!'**
  String get sendTransactionSuccessfullySent;

  /// No description provided for @sendOpenAliasResolveError.
  ///
  /// In en, this message translates to:
  /// **'Invalid OpenAlias.'**
  String get sendOpenAliasResolveError;

  /// No description provided for @sendOpenAliasDisabledError.
  ///
  /// In en, this message translates to:
  /// **'OpenAlias is turned off. Turn it on in Settings.'**
  String get sendOpenAliasDisabledError;

  /// No description provided for @sendContactsButton.
  ///
  /// In en, this message translates to:
  /// **'Contacts'**
  String get sendContactsButton;

  /// No description provided for @sendInsufficientBalanceError.
  ///
  /// In en, this message translates to:
  /// **'Insufficient balance.'**
  String get sendInsufficientBalanceError;

  /// No description provided for @sendInsufficientBalanceToCoverFeeError.
  ///
  /// In en, this message translates to:
  /// **'Insufficient balance to cover the network fee.'**
  String get sendInsufficientBalanceToCoverFeeError;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsSectionGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsSectionGeneral;

  /// No description provided for @settingsSectionSecurityPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Security and Privacy'**
  String get settingsSectionSecurityPrivacy;

  /// No description provided for @settingsSectionData.
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get settingsSectionData;

  /// No description provided for @settingsSectionBehaviour.
  ///
  /// In en, this message translates to:
  /// **'Behavior'**
  String get settingsSectionBehaviour;

  /// No description provided for @settingsSectionAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsSectionAbout;

  /// No description provided for @settingsSectionWallet.
  ///
  /// In en, this message translates to:
  /// **'Wallet'**
  String get settingsSectionWallet;

  /// No description provided for @settingsNotifyNewTxsLabel.
  ///
  /// In en, this message translates to:
  /// **'Transaction Notifications'**
  String get settingsNotifyNewTxsLabel;

  /// No description provided for @settingsNotifyNewTxsDescription.
  ///
  /// In en, this message translates to:
  /// **'Show a notification when you receive a transaction. Increase the sync frequency setting to see them sooner.'**
  String get settingsNotifyNewTxsDescription;

  /// No description provided for @settingsSyncFrequencyLabel.
  ///
  /// In en, this message translates to:
  /// **'Sync Frequency'**
  String get settingsSyncFrequencyLabel;

  /// No description provided for @syncFrequencyContinuous.
  ///
  /// In en, this message translates to:
  /// **'Continuous'**
  String get syncFrequencyContinuous;

  /// No description provided for @syncFrequencyPeriodic.
  ///
  /// In en, this message translates to:
  /// **'Periodic'**
  String get syncFrequencyPeriodic;

  /// No description provided for @syncFrequencyOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get syncFrequencyOff;

  /// No description provided for @syncFrequencyOffDesc.
  ///
  /// In en, this message translates to:
  /// **'Only syncs while the app is open.'**
  String get syncFrequencyOffDesc;

  /// No description provided for @settingsLoggingLabel.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic Logs'**
  String get settingsLoggingLabel;

  /// No description provided for @settingsLoggingDescription.
  ///
  /// In en, this message translates to:
  /// **'Log wallet operations to a text file in the app\'s data folder for debugging purposes.'**
  String get settingsLoggingDescription;

  /// No description provided for @settingsLoggingDescriptionIos.
  ///
  /// In en, this message translates to:
  /// **'Log wallet operations and allow the logs to be exported to a text file.'**
  String get settingsLoggingDescriptionIos;

  /// No description provided for @settingsExportLogsLabel.
  ///
  /// In en, this message translates to:
  /// **'Export Logs'**
  String get settingsExportLogsLabel;

  /// No description provided for @settingsExportLogsButton.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get settingsExportLogsButton;

  /// No description provided for @settingsExportLogsError.
  ///
  /// In en, this message translates to:
  /// **'No logs found to export.'**
  String get settingsExportLogsError;

  /// No description provided for @settingsExportLogsFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not export the log file'**
  String get settingsExportLogsFailed;

  /// No description provided for @settingsThemeLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get settingsThemeLabel;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsThemeSystem;

  /// No description provided for @settingsThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsThemeDark;

  /// No description provided for @settingsThemeDarkDesc.
  ///
  /// In en, this message translates to:
  /// **'Dark ground, easier at night'**
  String get settingsThemeDarkDesc;

  /// No description provided for @settingsThemeSystemDesc.
  ///
  /// In en, this message translates to:
  /// **'Follows your phone'**
  String get settingsThemeSystemDesc;

  /// No description provided for @settingsThemeSheetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pick a theme to match your style.'**
  String get settingsThemeSheetSubtitle;

  /// No description provided for @settingsLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguageLabel;

  /// No description provided for @settingsLanguageSheetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pick your language and localization.'**
  String get settingsLanguageSheetSubtitle;

  /// No description provided for @revealSeedAuthReason.
  ///
  /// In en, this message translates to:
  /// **'Confirm it\'s you to view your recovery phrase'**
  String get revealSeedAuthReason;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @settingsLwsViewKeysButton.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get settingsLwsViewKeysButton;

  /// No description provided for @settingsDeleteWalletButton.
  ///
  /// In en, this message translates to:
  /// **'Delete Wallet'**
  String get settingsDeleteWalletButton;

  /// No description provided for @settingsDeleteWalletDialogText.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete your wallet? You will lose access to your funds unless you have backed up your recovery phrase. This will not remove your address book and app settings.'**
  String get settingsDeleteWalletDialogText;

  /// No description provided for @settingsDeleteWalletDialogDeleteButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get settingsDeleteWalletDialogDeleteButton;

  /// No description provided for @settingsDeleteAddressBookButton.
  ///
  /// In en, this message translates to:
  /// **'Delete Address Book'**
  String get settingsDeleteAddressBookButton;

  /// No description provided for @settingsDeleteAddressBookDialogText.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete your address book? If automatic backup is turned on, it will also delete the address book in these automatic backups.'**
  String get settingsDeleteAddressBookDialogText;

  /// No description provided for @settingsDeleteAddressBookDialogDeleteButton.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get settingsDeleteAddressBookDialogDeleteButton;

  /// No description provided for @settingsAddressBookDeleted.
  ///
  /// In en, this message translates to:
  /// **'Address book deleted'**
  String get settingsAddressBookDeleted;

  /// Data settings row and its confirm sheet's title; shown only while there are labels. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Delete Address Labels'**
  String get settingsDeleteAddressLabelsButton;

  /// Body of the confirm sheet, worded as the address book's. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete your address labels? If automatic backup is turned on, it will also delete the address labels in these automatic backups.'**
  String get settingsDeleteAddressLabelsDialogText;

  /// Confirm button. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get settingsDeleteAddressLabelsDialogDeleteButton;

  /// Toast. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'Address labels deleted'**
  String get settingsAddressLabelsDeleted;

  /// No description provided for @txDetailsTitle.
  ///
  /// In en, this message translates to:
  /// **'Transaction Details'**
  String get txDetailsTitle;

  /// No description provided for @txDetailsCopyHint.
  ///
  /// In en, this message translates to:
  /// **'tap any value to copy'**
  String get txDetailsCopyHint;

  /// No description provided for @txDetailsHashLabel.
  ///
  /// In en, this message translates to:
  /// **'Hash'**
  String get txDetailsHashLabel;

  /// No description provided for @txDetailsTimeAndDateLabel.
  ///
  /// In en, this message translates to:
  /// **'Time and Date'**
  String get txDetailsTimeAndDateLabel;

  /// No description provided for @txDetailsConfirmationHeightLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirmation Height'**
  String get txDetailsConfirmationHeightLabel;

  /// No description provided for @txDetailsConfirmationsLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirmations'**
  String get txDetailsConfirmationsLabel;

  /// No description provided for @txDetailsViewKeyLabel.
  ///
  /// In en, this message translates to:
  /// **'View Key'**
  String get txDetailsViewKeyLabel;

  /// No description provided for @txDetailsRecipientsLabel.
  ///
  /// In en, this message translates to:
  /// **'Recipients'**
  String get txDetailsRecipientsLabel;

  /// No description provided for @txDetailsReceivedAtLabel.
  ///
  /// In en, this message translates to:
  /// **'Received At'**
  String get txDetailsReceivedAtLabel;

  /// No description provided for @txDetailsChangeRecipientLabel.
  ///
  /// In en, this message translates to:
  /// **'Change Recipient'**
  String get txDetailsChangeRecipientLabel;

  /// No description provided for @txDetailsFailed.
  ///
  /// In en, this message translates to:
  /// **'This transaction failed. The funds were not sent.'**
  String get txDetailsFailed;

  /// No description provided for @txDetailsUnknownStatus.
  ///
  /// In en, this message translates to:
  /// **'This transaction was not confirmed as sent. Check before sending again.'**
  String get txDetailsUnknownStatus;

  /// No description provided for @lwsKeysTitle.
  ///
  /// In en, this message translates to:
  /// **'LWS Keys'**
  String get lwsKeysTitle;

  /// No description provided for @lwsKeysPrimaryAddress.
  ///
  /// In en, this message translates to:
  /// **'Primary Address'**
  String get lwsKeysPrimaryAddress;

  /// No description provided for @lwsKeysRestoreHeight.
  ///
  /// In en, this message translates to:
  /// **'Restore Height'**
  String get lwsKeysRestoreHeight;

  /// No description provided for @lwsKeysSecretViewKey.
  ///
  /// In en, this message translates to:
  /// **'Secret View Key'**
  String get lwsKeysSecretViewKey;

  /// No description provided for @lwsKeysWarning.
  ///
  /// In en, this message translates to:
  /// **'Screenshots are blocked on this screen. Make sure nobody is looking over your shoulder.'**
  String get lwsKeysWarning;

  /// No description provided for @scanQrTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan QR Code'**
  String get scanQrTitle;

  /// No description provided for @confirmSendTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm Send'**
  String get confirmSendTitle;

  /// No description provided for @confirmSendDescription.
  ///
  /// In en, this message translates to:
  /// **'Transactions are irreversible, so make sure that these details match exactly.'**
  String get confirmSendDescription;

  /// No description provided for @confirmSendHighFeeWarning.
  ///
  /// In en, this message translates to:
  /// **'The network fee is {percent} of the amount you are sending.'**
  String confirmSendHighFeeWarning(String percent);

  /// No description provided for @addressBookTitle.
  ///
  /// In en, this message translates to:
  /// **'Address Book'**
  String get addressBookTitle;

  /// No description provided for @addressBookAddContact.
  ///
  /// In en, this message translates to:
  /// **'Add Contact'**
  String get addressBookAddContact;

  /// No description provided for @addressBookEditContact.
  ///
  /// In en, this message translates to:
  /// **'Edit Contact'**
  String get addressBookEditContact;

  /// No description provided for @addressBookDeleteContact.
  ///
  /// In en, this message translates to:
  /// **'Delete Contact'**
  String get addressBookDeleteContact;

  /// No description provided for @addressBookDeleteContactConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{contactName}\"?'**
  String addressBookDeleteContactConfirmation(String contactName);

  /// No description provided for @addressBookDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get addressBookDelete;

  /// No description provided for @addressBookSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search contacts...'**
  String get addressBookSearchHint;

  /// No description provided for @addressBookNoContactsDescription.
  ///
  /// In en, this message translates to:
  /// **'Add your first contact by tapping the + button'**
  String get addressBookNoContactsDescription;

  /// No description provided for @addressBookEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get addressBookEdit;

  /// No description provided for @addressBookContactName.
  ///
  /// In en, this message translates to:
  /// **'Contact Name'**
  String get addressBookContactName;

  /// No description provided for @addressBookNameHint.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get addressBookNameHint;

  /// No description provided for @addressBookUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get addressBookUpdate;

  /// No description provided for @scanQrUnexpectedCode.
  ///
  /// In en, this message translates to:
  /// **'That QR isn\'t a valid address or payment code.'**
  String get scanQrUnexpectedCode;

  /// No description provided for @deepLinkCoinNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Please configure your {chain} connection first.'**
  String deepLinkCoinNotConfigured(String chain);

  /// No description provided for @sendPriorityLow.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get sendPriorityLow;

  /// No description provided for @sendPriorityNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get sendPriorityNormal;

  /// No description provided for @sendPriorityHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get sendPriorityHigh;

  /// No description provided for @sendToLabel.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get sendToLabel;

  /// No description provided for @sendPriorityHeading.
  ///
  /// In en, this message translates to:
  /// **'Priority'**
  String get sendPriorityHeading;

  /// No description provided for @sendAvailableSuffix.
  ///
  /// In en, this message translates to:
  /// **'available'**
  String get sendAvailableSuffix;

  /// No description provided for @sendSwitchUnit.
  ///
  /// In en, this message translates to:
  /// **'Switch Amount Unit'**
  String get sendSwitchUnit;

  /// No description provided for @sendNetworkFee.
  ///
  /// In en, this message translates to:
  /// **'Network Fee'**
  String get sendNetworkFee;

  /// No description provided for @sendMaxButton.
  ///
  /// In en, this message translates to:
  /// **'MAX'**
  String get sendMaxButton;

  /// No description provided for @sendPasteButton.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get sendPasteButton;

  /// No description provided for @sendScanButton.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get sendScanButton;

  /// No description provided for @sendPickContactTitle.
  ///
  /// In en, this message translates to:
  /// **'Send to a Contact'**
  String get sendPickContactTitle;

  /// No description provided for @sendFailedToGetFeesError.
  ///
  /// In en, this message translates to:
  /// **'Failed to get fees.'**
  String get sendFailedToGetFeesError;

  /// No description provided for @sendNoConnectionError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t reach the server. Check your connection and try again.'**
  String get sendNoConnectionError;

  /// No description provided for @torSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Tor Settings'**
  String get torSettingsTitle;

  /// No description provided for @torSettingsModeBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'Built-in Tor'**
  String get torSettingsModeBuiltIn;

  /// No description provided for @torSettingsModeExternal.
  ///
  /// In en, this message translates to:
  /// **'External Tor'**
  String get torSettingsModeExternal;

  /// No description provided for @torSettingsModeDisabled.
  ///
  /// In en, this message translates to:
  /// **'No Tor'**
  String get torSettingsModeDisabled;

  /// No description provided for @torSettingsSocksPortLabel.
  ///
  /// In en, this message translates to:
  /// **'SOCKS Port'**
  String get torSettingsSocksPortLabel;

  /// No description provided for @torSettingsTestConnectionButton.
  ///
  /// In en, this message translates to:
  /// **'Test Connection'**
  String get torSettingsTestConnectionButton;

  /// No description provided for @torDisabledWalletsWarningTitle.
  ///
  /// In en, this message translates to:
  /// **'Disable Tor?'**
  String get torDisabledWalletsWarningTitle;

  /// No description provided for @torDisabledWalletsWarningBody.
  ///
  /// In en, this message translates to:
  /// **'Some wallets are set to connect over Tor. Disabling Tor will disconnect them, and they will stay disconnected until you reconfigure their connection.'**
  String get torDisabledWalletsWarningBody;

  /// No description provided for @torDisabledWalletsWarningConfirm.
  ///
  /// In en, this message translates to:
  /// **'Disable Tor'**
  String get torDisabledWalletsWarningConfirm;

  /// No description provided for @connectionRemoteIpNotAllowed.
  ///
  /// In en, this message translates to:
  /// **'Connections to remote IP addresses aren\'t allowed. Use a domain name or a local IP address.'**
  String get connectionRemoteIpNotAllowed;

  /// No description provided for @connectionLocalOverTorNotAllowed.
  ///
  /// In en, this message translates to:
  /// **'A local address can\'t be reached through Tor. Turn Tor off, or use the server\'s onion address.'**
  String get connectionLocalOverTorNotAllowed;

  /// No description provided for @connectionOnionNeedsTor.
  ///
  /// In en, this message translates to:
  /// **'An onion address can only be reached through Tor. Turn Tor on to use it.'**
  String get connectionOnionNeedsTor;

  /// No description provided for @connectionPathNotSupported.
  ///
  /// In en, this message translates to:
  /// **'This server is reached at its root, so its address can\'t include a path like /wallet. Remove the path.'**
  String get connectionPathNotSupported;

  /// No description provided for @lwsAwaitingApprovalAccount.
  ///
  /// In en, this message translates to:
  /// **'Your light wallet server hasn\'t approved this wallet yet. Ask the server\'s operator to approve it so you can see your balance and transactions.'**
  String get lwsAwaitingApprovalAccount;

  /// No description provided for @lwsAwaitingApprovalRestoreHeight.
  ///
  /// In en, this message translates to:
  /// **'Your light wallet server hasn\'t approved scanning from your restore height yet, so older transactions may be missing. Ask the server\'s operator to approve it.'**
  String get lwsAwaitingApprovalRestoreHeight;

  /// No description provided for @connectionTorDisabledWarning.
  ///
  /// In en, this message translates to:
  /// **'Tor is disabled, so this connection no longer works. Please reconfigure it.'**
  String get connectionTorDisabledWarning;

  /// No description provided for @connectionProtocolHttps.
  ///
  /// In en, this message translates to:
  /// **'Removing protocol. Using HTTPS for domains.'**
  String get connectionProtocolHttps;

  /// No description provided for @connectionProtocolHttp.
  ///
  /// In en, this message translates to:
  /// **'Removing protocol. Using HTTP for local addresses.'**
  String get connectionProtocolHttp;

  /// No description provided for @connectionProtocolHttpOnion.
  ///
  /// In en, this message translates to:
  /// **'Removing protocol. Onion addresses use HTTP over Tor.'**
  String get connectionProtocolHttpOnion;

  /// No description provided for @settingsTorSettingsLabel.
  ///
  /// In en, this message translates to:
  /// **'Tor Settings'**
  String get settingsTorSettingsLabel;

  /// No description provided for @lwsSetupTorDisabledError.
  ///
  /// In en, this message translates to:
  /// **'Tor is disabled. Please go back and enable it.'**
  String get lwsSetupTorDisabledError;

  /// No description provided for @homeIncomingTitle.
  ///
  /// In en, this message translates to:
  /// **'Incoming'**
  String get homeIncomingTitle;

  /// No description provided for @homeIncomingUnlocksIn.
  ///
  /// In en, this message translates to:
  /// **'Unlocks in about {minutes, plural, =1{1 minute} other{{minutes} minutes}} · {done} of {needed}'**
  String homeIncomingUnlocksIn(int minutes, int done, int needed);

  /// No description provided for @homeIncomingConfirmations.
  ///
  /// In en, this message translates to:
  /// **'{done} of {needed} confirmations'**
  String homeIncomingConfirmations(int done, int needed);

  /// No description provided for @homeChartTitle.
  ///
  /// In en, this message translates to:
  /// **'Balance · 90 days'**
  String get homeChartTitle;

  /// No description provided for @homeChartToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get homeChartToday;

  /// No description provided for @homeChartEachCoin.
  ///
  /// In en, this message translates to:
  /// **'Each coin\'s balance'**
  String get homeChartEachCoin;

  /// No description provided for @homeChartNew.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get homeChartNew;

  /// No description provided for @homeChartEmpty.
  ///
  /// In en, this message translates to:
  /// **'Your balance over time shows here after your first transaction.'**
  String get homeChartEmpty;

  /// No description provided for @homeChecklistTitle.
  ///
  /// In en, this message translates to:
  /// **'Secure Your Wallet'**
  String get homeChecklistTitle;

  /// No description provided for @homeChecklistProgress.
  ///
  /// In en, this message translates to:
  /// **'{done} of {total}'**
  String homeChecklistProgress(int done, int total);

  /// No description provided for @homeChecklistVerifySeed.
  ///
  /// In en, this message translates to:
  /// **'Verify Your Recovery Phrase'**
  String get homeChecklistVerifySeed;

  /// No description provided for @homeChecklistAutoBackup.
  ///
  /// In en, this message translates to:
  /// **'Turn On Automatic Backups'**
  String get homeChecklistAutoBackup;

  /// No description provided for @homeChecklistTor.
  ///
  /// In en, this message translates to:
  /// **'Connect Through Tor'**
  String get homeChecklistTor;

  /// No description provided for @homeChecklistPrivateLookups.
  ///
  /// In en, this message translates to:
  /// **'Use Tor for Price and OpenAlias Lookups'**
  String get homeChecklistPrivateLookups;

  /// No description provided for @homeChecklistSecurityKeys.
  ///
  /// In en, this message translates to:
  /// **'Set Up a Security Key'**
  String get homeChecklistSecurityKeys;

  /// No description provided for @verifySeedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Input words {first}, {second} and {third} of your recovery phrase below.'**
  String verifySeedSubtitle(int first, int second, int third);

  /// No description provided for @verifySeedButton.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get verifySeedButton;

  /// No description provided for @verifySeedWrongTitle.
  ///
  /// In en, this message translates to:
  /// **'Those words don\'t match'**
  String get verifySeedWrongTitle;

  /// No description provided for @verifySeedWrongBody.
  ///
  /// In en, this message translates to:
  /// **'Check the recovery phrase you wrote down, then enter the three new words asked for. {count, plural, =1{1 try} other{{count} tries}} left before the app locks.'**
  String verifySeedWrongBody(int count);

  /// No description provided for @verifySeedTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try Again'**
  String get verifySeedTryAgain;

  /// No description provided for @verifySeedUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Your recovery phrase can\'t be read right now. Try again after unlocking the wallet.'**
  String get verifySeedUnavailable;

  /// No description provided for @verifySeedDone.
  ///
  /// In en, this message translates to:
  /// **'Recovery phrase verified'**
  String get verifySeedDone;

  /// No description provided for @homeIncomingTitleMore.
  ///
  /// In en, this message translates to:
  /// **'Incoming (+{count, plural, =1{1 Other} other{{count} Others}})'**
  String homeIncomingTitleMore(int count);

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @connectionSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection Setup'**
  String get connectionSetupTitle;

  /// No description provided for @generateSeedPasswordNote.
  ///
  /// In en, this message translates to:
  /// **'{appName} Wallet asks for your password before showing these words again.'**
  String generateSeedPasswordNote(String appName);

  /// Receive tab showing the next fresh address of a chain whose addresses are not called subaddresses (Bitcoin). Title Case.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get receiveAddressTab;

  /// Receive tab listing the used addresses, which the user can label. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Labeled'**
  String get receiveLabeledTab;

  /// Line above the used-address list on Receive's Labeled tab. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'Optionally label addresses if you want to easily search for transactions involving them.'**
  String get labeledCaption;

  /// Section label over every used address; shown upper-cased. Title Case. kind is subaddress (Monero) or address.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, subaddress{Used Subaddresses} other{Used Addresses}} · {count}'**
  String labeledUsedHeader(String kind, int count);

  /// Section label while Hide Unlabeled is on; shown upper-cased. Title Case.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, subaddress{Labeled Subaddresses} other{Labeled Addresses}} · {count}'**
  String labeledOnlyHeader(String kind, int count);

  /// Toggle beside the used-address list that hides addresses without a label. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Hide Unlabeled'**
  String get labeledHideUnlabeled;

  /// Row title of a used address without a label. Title Case.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, subaddress{Subaddress #{index}} other{Address #{index}}}'**
  String labeledAddressTitle(String kind, int index);

  /// How many transactions an address received, beside its total. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 transaction} other{{count} transactions}}'**
  String labeledTransactionCount(int count);

  /// When an address last received a transaction; time is a timeAgo string. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'Last used {time}'**
  String labeledLastUsed(String time);

  /// Button on a used address that opens the label sheet. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get labeledLabelButton;

  /// Empty-state title on the Labeled tab. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, subaddress{No used subaddresses yet} other{No used addresses yet}}'**
  String labeledEmptyTitle(String kind);

  /// Empty-state body on the Labeled tab. Sentence case.
  ///
  /// In en, this message translates to:
  /// **'Optionally label addresses if you want to easily search for transactions involving them. {kind, select, subaddress{A subaddress shows up here after its first transaction.} other{An address shows up here after its first transaction.}}'**
  String labeledEmptyBody(String kind);

  /// Title of the sheet that sets an address's label. Title Case.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, subaddress{Label Subaddress #{index}} other{Label Address #{index}}}'**
  String labelSheetTitle(String kind, int index);

  /// Field label in the label sheet; shown upper-cased. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get labelSheetField;

  /// Button that saves a label; an empty one removes it. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Save Label'**
  String get labelSheetSave;

  /// Stat label and button on an address's own screen: the button opens History filtered to it. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Transactions'**
  String get addressDetailTransactions;

  /// Stat label: when the address last received a transaction. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Last Transaction'**
  String get addressDetailLastTransaction;

  /// Button on a labeled address's screen. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Edit Label'**
  String get addressDetailEditLabel;

  /// Button on an unlabeled address's screen. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Add Label'**
  String get addressDetailAddLabel;

  /// Section label in History's address filter, over the labeled addresses to pick from; shown upper-cased. Title Case.
  ///
  /// In en, this message translates to:
  /// **'Your Labeled Addresses'**
  String get historyFilterLabeledAddresses;

  /// Relative time under 45 seconds, after Last used. Lower case, as timeago words it.
  ///
  /// In en, this message translates to:
  /// **'a moment ago'**
  String get timeAgoMoment;

  /// Relative time.
  ///
  /// In en, this message translates to:
  /// **'a minute ago'**
  String get timeAgoMinute;

  /// Relative time; count is 2 or more.
  ///
  /// In en, this message translates to:
  /// **'{count} minutes ago'**
  String timeAgoMinutes(int count);

  /// Relative time.
  ///
  /// In en, this message translates to:
  /// **'about an hour ago'**
  String get timeAgoHour;

  /// Relative time; count is 2 or more.
  ///
  /// In en, this message translates to:
  /// **'{count} hours ago'**
  String timeAgoHours(int count);

  /// Relative time.
  ///
  /// In en, this message translates to:
  /// **'a day ago'**
  String get timeAgoDay;

  /// Relative time; count is 2 or more.
  ///
  /// In en, this message translates to:
  /// **'{count} days ago'**
  String timeAgoDays(int count);

  /// Relative time.
  ///
  /// In en, this message translates to:
  /// **'about a month ago'**
  String get timeAgoMonth;

  /// Relative time; count is 2 or more.
  ///
  /// In en, this message translates to:
  /// **'{count} months ago'**
  String timeAgoMonths(int count);

  /// Relative time.
  ///
  /// In en, this message translates to:
  /// **'about a year ago'**
  String get timeAgoYear;

  /// Relative time; count is 2 or more.
  ///
  /// In en, this message translates to:
  /// **'{count} years ago'**
  String timeAgoYears(int count);
}

class _WalletUiLocalizationsDelegate extends LocalizationsDelegate<WalletUiLocalizations> {
  const _WalletUiLocalizationsDelegate();

  @override
  Future<WalletUiLocalizations> load(Locale locale) {
    return SynchronousFuture<WalletUiLocalizations>(lookupWalletUiLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_WalletUiLocalizationsDelegate old) => false;
}

WalletUiLocalizations lookupWalletUiLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return WalletUiLocalizationsEn();
    case 'pt':
      return WalletUiLocalizationsPt();
  }

  throw FlutterError(
    'WalletUiLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
