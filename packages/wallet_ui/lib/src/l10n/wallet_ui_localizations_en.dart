// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'wallet_ui_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class WalletUiLocalizationsEn extends WalletUiLocalizations {
  WalletUiLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get restoreWalletTitle => 'Restore Wallet';

  @override
  String get verifySeedTitle => 'Verify Recovery Phrase';

  @override
  String get createNewWalletChoice => 'Create New Wallet';

  @override
  String get restoreExistingWalletChoice => 'Restore Existing Wallet';

  @override
  String get clearnetOnlyChoice => 'Clearnet-Only';

  @override
  String get noTransactions => 'No transactions';

  @override
  String get addressBookNoContacts => 'No contacts yet';

  @override
  String get addressBookNoSearchResults => 'No contacts found';

  @override
  String generateSeedConfirm(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'all $count words',
      zero: 'all the words',
    );
    return 'I have written down $_temp0 and stored them somewhere only I can reach.';
  }

  @override
  String get unlockWalletReason => 'Unlock wallet';

  @override
  String get torUseOrbotLabel => 'Use Orbot/InviZible';

  @override
  String get torUseOrbotLabelIos => 'Use Orbot';

  @override
  String get continueText => 'Continue';

  @override
  String get cancel => 'Cancel';

  @override
  String get close => 'Close';

  @override
  String get back => 'Back';

  @override
  String get unknownError => 'Unknown error.';

  @override
  String get warning => 'Warning';

  @override
  String get amount => 'Amount';

  @override
  String get networkFee => 'Network Fee';

  @override
  String get address => 'Address';

  @override
  String get pending => 'Pending';

  @override
  String get unconfirmed => 'Unconfirmed';

  @override
  String get copy => 'Copy';

  @override
  String get addressCopied => 'Address copied to clipboard';

  @override
  String get copiedToClipboard => 'Copied to clipboard';

  @override
  String get fieldEmptyError => 'This field cannot be empty.';

  @override
  String get settingsLicensesLabel => 'Open-Source Licenses';

  @override
  String get torChoiceTitle => 'Tor Connection Setup';

  @override
  String torChoiceBuiltInDesc(String appName) {
    return 'Bundled with $appName Wallet · recommended';
  }

  @override
  String get torChoiceExternalDesc => 'Orbot, or a daemon you run yourself';

  @override
  String get torChoiceNoTorDesc => 'Servers you connect to can see your IP address';

  @override
  String get torChoiceTestFailed => 'Test failed';

  @override
  String get torChoiceConnected => 'Connected to Tor';

  @override
  String get connectionTypeLws => 'Light Wallet Server';

  @override
  String get connectionTypeNode => 'Monero Node';

  @override
  String get lwsSetupUseTorLabel => 'Use Tor';

  @override
  String get lwsSetupTestConnectionButton => 'Test Connection';

  @override
  String get connectionTestingTitle => 'Testing connection';

  @override
  String get connectionTestingDetail => 'Checking whether the server answers.';

  @override
  String get connectionTestStop => 'Stop';

  @override
  String get connectionResultWorksTitle => 'Connection works';

  @override
  String get connectionReachedOverTor => 'Reached over Tor';

  @override
  String get connectionReachedViaProxy => 'Reached through your proxy';

  @override
  String get connectionReachedDirect => 'Reached directly';

  @override
  String get connectionResultFailedTitle => 'Could not reach this server';

  @override
  String get connectionResultFailedDetail =>
      'Nothing answered. Check the address and port, and whether the server accepts your connection.';

  @override
  String get connectionTestAgain => 'Test Again';

  @override
  String get lwsSetupStartingTor => 'Starting Tor...';

  @override
  String get lwsSetupContinueButton => 'Continue';

  @override
  String get fiatApiSetupTitle => 'Price Display Setup';

  @override
  String get fiatApiSettingsModeLabel => 'Mode';

  @override
  String get fiatApiSettingsModeTorOnly => 'Tor-Only';

  @override
  String get fiatApiSettingsModeDisabled => 'Disabled';

  @override
  String get fiatModeTorOnlyDesc => 'Prices fetched over Tor · recommended';

  @override
  String get fiatModeClearnetDesc => 'Not private, the price server sees your IP address';

  @override
  String get fiatModeDisabledDesc => 'No prices fetched, balances shown in crypto only';

  @override
  String get settingsOpenAliasSettingsLabel => 'OpenAlias Settings';

  @override
  String get openAliasSettingsSheetSubtitle =>
      'How names like name@example.com are looked up when you send.';

  @override
  String get openAliasModeTorOnlyDesc => 'Names looked up over Tor · recommended';

  @override
  String get openAliasModeClearnetDesc =>
      'Not private, DNS servers see your IP address and the name';

  @override
  String get openAliasModeDisabledDesc => 'No lookups, send to addresses only';

  @override
  String get fiatApiSettingsDisplayCurrencyLabel => 'Display Currency';

  @override
  String get settingsFiatApiSettingsLabel => 'Price Display Settings';

  @override
  String get fiatApiSettingsSheetSubtitle =>
      'How prices are fetched, and the currency they are shown in.';

  @override
  String get createWalletTitle => 'Wallet Setup';

  @override
  String get createWalletPasswordTitle => 'Create Wallet Password';

  @override
  String get createWalletPasswordDescription =>
      'Create a password to protect your wallet. This password will be required to unlock your wallet.';

  @override
  String get createWalletPasswordHint => 'Enter your password';

  @override
  String get createWalletConfirmPasswordHint => 'Confirm your password';

  @override
  String get passwordTooShortError => 'Password must be at least 8 characters long.';

  @override
  String get passwordsDoNotMatchError => 'Passwords do not match.';

  @override
  String get generateSeedTitle => 'Write These Down, in Order';

  @override
  String get generateSeedTitleCovered => 'Recovery Phrase';

  @override
  String get generateSeedSubtitleRevealed => 'Securely save these. Do not share them.';

  @override
  String get generateSeedScreenshotNote =>
      'Screenshots are blocked on this screen. Make sure nobody is looking over your shoulder.';

  @override
  String get generateSeedReveal => 'Tap to Reveal';

  @override
  String get generateSeedBirthdayLabel => 'Wallet Birthday';

  @override
  String get generateSeedBirthdayReason => 'Where a future restore starts scanning';

  @override
  String get onboardingPriceNoteRatesOnly =>
      'Only prices are requested. Your addresses and balances are not sent.';

  @override
  String get onboardingPriceNoteTor => 'Prices are fetched over Tor by default.';

  @override
  String get onboardingTorNotePrivacy => 'Connections over Tor can be slower.';

  @override
  String get onboardingTorNoteChangeable => 'You can change this later in Settings.';

  @override
  String get onboardingPasswordNoteLaunch =>
      'You need this password to open your wallet and to view your recovery phrase.';

  @override
  String get onboardingPasswordNoteNotCloud =>
      'This password can\'t be recovered. If you lose it, restore your wallet from your recovery phrase.';

  @override
  String get onboardingPasswordStrong => 'Strong';

  @override
  String get onboardingPasswordMatch => 'Passwords match';

  @override
  String onboardingWalletNoteGenerated(String appName) {
    return '$appName Wallet generates your recovery phrase on this device.';
  }

  @override
  String get onboardingWalletNoteRestore =>
      'When restoring, a scan-from date makes syncing faster.';

  @override
  String get lwsDetailsDescription =>
      'If your Monero light wallet server (LWS) requires registration, you can use these details to add this wallet to that server. Not all servers require registration.';

  @override
  String get restoreWalletSeedLength => 'Number of Words';

  @override
  String get restoreWalletPaste => 'Paste';

  @override
  String get restoreWalletScanFrom => 'Scan From';

  @override
  String get restoreWalletScanFromReason => 'Skip irrelevant history to save time';

  @override
  String get restoreWalletNotSet => 'Not set';

  @override
  String get restoreScanTitle => 'When Did This Wallet First Receive Funds?';

  @override
  String get restoreScanPickMonth => 'Pick a Month';

  @override
  String get restoreScanNotSure => 'I\'m Not Sure';

  @override
  String get restoreScanNotSureDesc =>
      'Scan everything. Slower this first setup but not any slower later. Always complete.';

  @override
  String get restoreScanFromStart => 'Genesis';

  @override
  String get restoreScanDone => 'Done';

  @override
  String restoreWalletBadWord(int position) {
    return 'Word $position isn\'t a BIP39 word.';
  }

  @override
  String restoreWalletDidYouMean(String word) {
    return 'Did you mean $word?';
  }

  @override
  String get restoreWalletChecksumError =>
      'This isn\'t a valid recovery phrase — check the words and their order.';

  @override
  String get restoreWalletRestoreButton => 'Restore';

  @override
  String get navigationBarSettings => 'Settings';

  @override
  String get navigationBarHistory => 'History';

  @override
  String get historyTitle => 'History';

  @override
  String get historyExportCsv => 'Export CSV';

  @override
  String get historyExported => 'History exported';

  @override
  String get historyExportFailed => 'Could not export the history';

  @override
  String get historyFilterType => 'Type';

  @override
  String get historyFilterReset => 'Reset';

  @override
  String get unlockButton => 'Unlock';

  @override
  String get unlockUnableToAuthError => 'Unable to authenticate.';

  @override
  String get unlockWithFaceId => 'Unlock With Face ID';

  @override
  String get unlockWithTouchId => 'Unlock With Touch ID';

  @override
  String get unlockPasswordHint => 'Enter your password';

  @override
  String get unlockIncorrectPasswordError => 'Incorrect password. Please try again.';

  @override
  String get homeSyncing => 'Syncing';

  @override
  String get homeSynced => 'Synced';

  @override
  String get homeTorConnected => 'Tor · connected';

  @override
  String get homeTorConnecting => 'Tor · connecting';

  @override
  String get homeTorDisconnected => 'Tor · disconnected';

  @override
  String get homeTorOff => 'Tor · off';

  @override
  String get homeTorExternalConnected => 'External Tor · connected';

  @override
  String get homeTorExternalConnecting => 'External Tor · connecting';

  @override
  String get homeTorExternalDisconnected => 'External Tor · disconnected';

  @override
  String homeBlocksRemaining(int count) {
    final intl.NumberFormat countNumberFormat = intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString blocks left',
      one: '1 block left',
    );
    return '$_temp0';
  }

  @override
  String get coinHomeActivityTitle => 'Activity';

  @override
  String get coinHomeSwap => 'Swap';

  @override
  String get coinHomeSwapComingSoon => 'Coming soon!';

  @override
  String get coinHomeReceived => 'Received';

  @override
  String get coinHomeSent => 'Sent';

  @override
  String get homeReceive => 'Receive';

  @override
  String get homeSend => 'Send';

  @override
  String get homeFiatApiError => 'Error connecting to price server';

  @override
  String get receiveTitle => 'Receive';

  @override
  String get receivePrimaryAddressWarn =>
      'Unless you know what you\'re doing, please use subaddresses for better privacy.';

  @override
  String get receiveServerNoSubaddressesWarn =>
      'This server does not support subaddresses. For better privacy, consider using a server that supports them.';

  @override
  String get receiveSubaddressUnavailableWarn =>
      'You need to configure Monero to enable subaddresses, which better protect your privacy.';

  @override
  String get receiveMaxSubaddressesReachedWarn =>
      'You have reached the maximum number of subaddresses supported by this server. This is a used address.';

  @override
  String get receiveSubaddressTab => 'Subaddress';

  @override
  String get receivePrimaryTab => 'Primary Address';

  @override
  String get receiveCopyAddress => 'Copy Address';

  @override
  String get receiveEnlargeQr => 'Tap to Enlarge and Brighten';

  @override
  String get receiveShrinkQr => 'Tap to Shrink';

  @override
  String get receiveShareError => 'Could not open the share sheet';

  @override
  String receiveAddressHeading(String coin) {
    return 'Your $coin Address';
  }

  @override
  String get sendTitle => 'Send';

  @override
  String get sendSendButton => 'Send';

  @override
  String get sendTransactionSuccessfullySent => 'Transaction successfully sent!';

  @override
  String get sendOpenAliasResolveError => 'Invalid OpenAlias.';

  @override
  String get sendOpenAliasDisabledError => 'OpenAlias is turned off. Turn it on in Settings.';

  @override
  String get sendContactsButton => 'Contacts';

  @override
  String get sendInsufficientBalanceError => 'Insufficient balance.';

  @override
  String get sendInsufficientBalanceToCoverFeeError =>
      'Insufficient balance to cover the network fee.';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsSectionGeneral => 'General';

  @override
  String get settingsSectionSecurityPrivacy => 'Security and Privacy';

  @override
  String get settingsSectionData => 'Data';

  @override
  String get settingsSectionBehaviour => 'Behavior';

  @override
  String get settingsSectionAbout => 'About';

  @override
  String get settingsSectionWallet => 'Wallet';

  @override
  String get settingsNotifyNewTxsLabel => 'Transaction Notifications';

  @override
  String get settingsNotifyNewTxsDescription =>
      'Show a notification when you receive a transaction. Increase the sync frequency setting to see them sooner.';

  @override
  String get settingsSyncFrequencyLabel => 'Sync Frequency';

  @override
  String get syncFrequencyContinuous => 'Continuous';

  @override
  String get syncFrequencyPeriodic => 'Periodic';

  @override
  String get syncFrequencyOff => 'Off';

  @override
  String get syncFrequencyOffDesc => 'Only syncs while the app is open.';

  @override
  String get settingsLoggingLabel => 'Diagnostic Logs';

  @override
  String get settingsLoggingDescription =>
      'Log wallet operations to a text file in the app\'s data folder for debugging purposes.';

  @override
  String get settingsLoggingDescriptionIos =>
      'Log wallet operations and allow the logs to be exported to a text file.';

  @override
  String get settingsExportLogsLabel => 'Export Logs';

  @override
  String get settingsExportLogsButton => 'Export';

  @override
  String get settingsExportLogsError => 'No logs found to export.';

  @override
  String get settingsExportLogsFailed => 'Could not export the log file';

  @override
  String get settingsThemeLabel => 'Theme';

  @override
  String get settingsThemeSystem => 'System';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsThemeDarkDesc => 'Dark ground, easier at night';

  @override
  String get settingsThemeSystemDesc => 'Follows your phone';

  @override
  String get settingsThemeSheetSubtitle => 'Pick a theme to match your style.';

  @override
  String get settingsLanguageLabel => 'Language';

  @override
  String get settingsLanguageSheetSubtitle => 'Pick your language and localization.';

  @override
  String get revealSeedAuthReason => 'Confirm it\'s you to view your recovery phrase';

  @override
  String get done => 'Done';

  @override
  String get settingsLwsViewKeysButton => 'View';

  @override
  String get settingsDeleteWalletButton => 'Delete Wallet';

  @override
  String get settingsDeleteWalletDialogText =>
      'Are you sure you want to delete your wallet? You will lose access to your funds unless you have backed up your recovery phrase. This will not remove your address book and app settings.';

  @override
  String get settingsDeleteWalletDialogDeleteButton => 'Delete';

  @override
  String get settingsDeleteAddressBookButton => 'Delete Address Book';

  @override
  String get settingsDeleteAddressBookDialogText =>
      'Are you sure you want to delete your address book? If automatic backup is turned on, it will also delete the address book in these automatic backups.';

  @override
  String get settingsDeleteAddressBookDialogDeleteButton => 'Delete';

  @override
  String get settingsAddressBookDeleted => 'Address book deleted';

  @override
  String get txDetailsTitle => 'Transaction Details';

  @override
  String get txDetailsCopyHint => 'tap any value to copy';

  @override
  String get txDetailsHashLabel => 'Hash';

  @override
  String get txDetailsTimeAndDateLabel => 'Time and Date';

  @override
  String get txDetailsConfirmationHeightLabel => 'Confirmation Height';

  @override
  String get txDetailsConfirmationsLabel => 'Confirmations';

  @override
  String get txDetailsViewKeyLabel => 'View Key';

  @override
  String get txDetailsRecipientsLabel => 'Recipients';

  @override
  String get txDetailsReceivedAtLabel => 'Received At';

  @override
  String get txDetailsChangeRecipientLabel => 'Change Recipient';

  @override
  String get txDetailsFailed => 'This transaction failed. The funds were not sent.';

  @override
  String get txDetailsUnknownStatus =>
      'This transaction was not confirmed as sent. Check before sending again.';

  @override
  String get lwsKeysTitle => 'LWS Keys';

  @override
  String get lwsKeysPrimaryAddress => 'Primary Address';

  @override
  String get lwsKeysRestoreHeight => 'Restore Height';

  @override
  String get lwsKeysSecretViewKey => 'Secret View Key';

  @override
  String get lwsKeysWarning =>
      'Screenshots are blocked on this screen. Make sure nobody is looking over your shoulder.';

  @override
  String get scanQrTitle => 'Scan QR Code';

  @override
  String get confirmSendTitle => 'Confirm Send';

  @override
  String get confirmSendDescription =>
      'Transactions are irreversible, so make sure that these details match exactly.';

  @override
  String confirmSendHighFeeWarning(String percent) {
    return 'The network fee is $percent of the amount you are sending.';
  }

  @override
  String get addressBookTitle => 'Address Book';

  @override
  String get addressBookAddContact => 'Add Contact';

  @override
  String get addressBookEditContact => 'Edit Contact';

  @override
  String get addressBookDeleteContact => 'Delete Contact';

  @override
  String addressBookDeleteContactConfirmation(String contactName) {
    return 'Are you sure you want to delete \"$contactName\"?';
  }

  @override
  String get addressBookDelete => 'Delete';

  @override
  String get addressBookSearchHint => 'Search contacts...';

  @override
  String get addressBookNoContactsDescription => 'Add your first contact by tapping the + button';

  @override
  String get addressBookEdit => 'Edit';

  @override
  String get addressBookContactName => 'Contact Name';

  @override
  String get addressBookNameHint => 'Name';

  @override
  String get addressBookUpdate => 'Update';

  @override
  String get scanQrUnexpectedCode => 'That QR isn\'t a valid address or payment code.';

  @override
  String deepLinkCoinNotConfigured(String chain) {
    return 'Please configure your $chain connection first.';
  }

  @override
  String get sendPriorityLow => 'Low';

  @override
  String get sendPriorityNormal => 'Normal';

  @override
  String get sendPriorityHigh => 'High';

  @override
  String get sendToLabel => 'To';

  @override
  String get sendPriorityHeading => 'Priority';

  @override
  String get sendAvailableSuffix => 'available';

  @override
  String get sendSwitchUnit => 'Switch Amount Unit';

  @override
  String get sendNetworkFee => 'Network Fee';

  @override
  String get sendMaxButton => 'MAX';

  @override
  String get sendPasteButton => 'Paste';

  @override
  String get sendScanButton => 'Scan';

  @override
  String get sendPickContactTitle => 'Send to a Contact';

  @override
  String get sendFailedToGetFeesError => 'Failed to get fees.';

  @override
  String get sendNoConnectionError =>
      'Couldn\'t reach the server. Check your connection and try again.';

  @override
  String get torSettingsTitle => 'Tor Settings';

  @override
  String get torSettingsModeBuiltIn => 'Built-in Tor';

  @override
  String get torSettingsModeExternal => 'External Tor';

  @override
  String get torSettingsModeDisabled => 'No Tor';

  @override
  String get torSettingsSocksPortLabel => 'SOCKS Port';

  @override
  String get torSettingsTestConnectionButton => 'Test Connection';

  @override
  String get torDisabledWalletsWarningTitle => 'Disable Tor?';

  @override
  String get torDisabledWalletsWarningBody =>
      'Some wallets are set to connect over Tor. Disabling Tor will disconnect them, and they will stay disconnected until you reconfigure their connection.';

  @override
  String get torDisabledWalletsWarningConfirm => 'Disable Tor';

  @override
  String get connectionRemoteIpNotAllowed =>
      'Connections to remote IP addresses aren\'t allowed. Use a domain name or a local IP address.';

  @override
  String get connectionLocalOverTorNotAllowed =>
      'A local address can\'t be reached through Tor. Turn Tor off, or use the server\'s onion address.';

  @override
  String get connectionOnionNeedsTor =>
      'An onion address can only be reached through Tor. Turn Tor on to use it.';

  @override
  String get connectionPathNotSupported =>
      'This server is reached at its root, so its address can\'t include a path like /wallet. Remove the path.';

  @override
  String get lwsAwaitingApprovalAccount =>
      'Your light wallet server hasn\'t approved this wallet yet. Ask the server\'s operator to approve it so you can see your balance and transactions.';

  @override
  String get lwsAwaitingApprovalRestoreHeight =>
      'Your light wallet server hasn\'t approved scanning from your restore height yet, so older transactions may be missing. Ask the server\'s operator to approve it.';

  @override
  String get connectionTorDisabledWarning =>
      'Tor is disabled, so this connection no longer works. Please reconfigure it.';

  @override
  String get connectionProtocolHttps => 'Removing protocol. Using HTTPS for domains.';

  @override
  String get connectionProtocolHttp => 'Removing protocol. Using HTTP for local addresses.';

  @override
  String get connectionProtocolHttpOnion => 'Removing protocol. Onion addresses use HTTP over Tor.';

  @override
  String get settingsTorSettingsLabel => 'Tor Settings';

  @override
  String get lwsSetupTorDisabledError => 'Tor is disabled. Please go back and enable it.';

  @override
  String get homeIncomingTitle => 'Incoming';

  @override
  String homeIncomingUnlocksIn(int minutes, int done, int needed) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: '1 minute',
    );
    return 'Unlocks in about $_temp0 · $done of $needed';
  }

  @override
  String homeIncomingConfirmations(int done, int needed) {
    return '$done of $needed confirmations';
  }

  @override
  String get homeChartTitle => 'Balance · 90 days';

  @override
  String get homeChartToday => 'Today';

  @override
  String get homeChartEachCoin => 'Each coin\'s balance';

  @override
  String get homeChartNew => 'New';

  @override
  String get homeChartEmpty => 'Your balance over time shows here after your first transaction.';

  @override
  String get homeChecklistTitle => 'Secure Your Wallet';

  @override
  String homeChecklistProgress(int done, int total) {
    return '$done of $total';
  }

  @override
  String get homeChecklistVerifySeed => 'Verify Your Recovery Phrase';

  @override
  String get homeChecklistAutoBackup => 'Turn On Automatic Backups';

  @override
  String get homeChecklistTor => 'Connect Through Tor';

  @override
  String get homeChecklistPrivateLookups => 'Use Tor for Price and OpenAlias Lookups';

  @override
  String get homeChecklistSecurityKeys => 'Set Up a Security Key';

  @override
  String verifySeedSubtitle(int first, int second, int third) {
    return 'Input words $first, $second and $third of your recovery phrase below.';
  }

  @override
  String get verifySeedButton => 'Verify';

  @override
  String get verifySeedWrongTitle => 'Those words don\'t match';

  @override
  String verifySeedWrongBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tries',
      one: '1 try',
    );
    return 'Check the recovery phrase you wrote down, then enter the three new words asked for. $_temp0 left before the app locks.';
  }

  @override
  String get verifySeedTryAgain => 'Try Again';

  @override
  String get verifySeedUnavailable =>
      'Your recovery phrase can\'t be read right now. Try again after unlocking the wallet.';

  @override
  String get verifySeedDone => 'Recovery phrase verified';

  @override
  String homeIncomingTitleMore(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Others',
      one: '1 Other',
    );
    return 'Incoming (+$_temp0)';
  }

  @override
  String get save => 'Save';

  @override
  String get connectionSetupTitle => 'Connection Setup';

  @override
  String generateSeedPasswordNote(String appName) {
    return '$appName Wallet asks for your password before showing these words again.';
  }
}
