import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'backup_localizations_en.dart';
import 'backup_localizations_pt.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of BackupLocalizations
/// returned by `BackupLocalizations.of(context)`.
///
/// Applications need to include `BackupLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/backup_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: BackupLocalizations.localizationsDelegates,
///   supportedLocales: BackupLocalizations.supportedLocales,
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
/// be consistent with the languages listed in the BackupLocalizations.supportedLocales
/// property.
abstract class BackupLocalizations {
  BackupLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static BackupLocalizations of(BuildContext context) {
    return Localizations.of<BackupLocalizations>(context, BackupLocalizations)!;
  }

  static const LocalizationsDelegate<BackupLocalizations> delegate = _BackupLocalizationsDelegate();

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

  /// No description provided for @backupTitle.
  ///
  /// In en, this message translates to:
  /// **'Backup'**
  String get backupTitle;

  /// No description provided for @backupIntro.
  ///
  /// In en, this message translates to:
  /// **'Who you paid, each payment\'s transaction key, and your address book, encrypted with your recovery phrase. Restore the phrase anywhere and they come back.'**
  String get backupIntro;

  /// No description provided for @backupLegacySeed.
  ///
  /// In en, this message translates to:
  /// **'Backup isn\'t available for 25-word seeds. To use it, create a new wallet with a 16-word seed and send your funds to it.'**
  String get backupLegacySeed;

  /// No description provided for @backupUnsupportedPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Backup isn\'t available for seeds with an offset passphrase yet.'**
  String get backupUnsupportedPassphrase;

  /// No description provided for @backupLocked.
  ///
  /// In en, this message translates to:
  /// **'Unlock your wallet to see its backup.'**
  String get backupLocked;

  /// No description provided for @backupOpening.
  ///
  /// In en, this message translates to:
  /// **'Opening your backup…'**
  String get backupOpening;

  /// No description provided for @backupSummary.
  ///
  /// In en, this message translates to:
  /// **'{payments, plural, =1{1 payment} other{{payments} payments}} and {contacts, plural, =1{1 contact} other{{contacts} contacts}} backed up'**
  String backupSummary(int payments, int contacts);

  /// No description provided for @backupLastChecked.
  ///
  /// In en, this message translates to:
  /// **'Last checked {time}'**
  String backupLastChecked(String time);

  /// No description provided for @backupWhereSaved.
  ///
  /// In en, this message translates to:
  /// **'Where it\'s saved'**
  String get backupWhereSaved;

  /// No description provided for @backupICloud.
  ///
  /// In en, this message translates to:
  /// **'iCloud'**
  String get backupICloud;

  /// No description provided for @backupICloudDescription.
  ///
  /// In en, this message translates to:
  /// **'Syncs to your other Apple devices. Hidden from the Files app.'**
  String get backupICloudDescription;

  /// No description provided for @backupAndroid.
  ///
  /// In en, this message translates to:
  /// **'Android backup'**
  String get backupAndroid;

  /// No description provided for @backupAndroidDescription.
  ///
  /// In en, this message translates to:
  /// **'Android copies it about once a day with your Google account or your phone\'s backup service, and puts it back when you reinstall {appName}.'**
  String backupAndroidDescription(String appName);

  /// No description provided for @backupLws.
  ///
  /// In en, this message translates to:
  /// **'Light wallet server'**
  String get backupLws;

  /// No description provided for @backupComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get backupComingSoon;

  /// No description provided for @backupStatusUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get backupStatusUpToDate;

  /// No description provided for @backupStatusPending.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 change waiting to upload} other{{count} changes waiting to upload}}'**
  String backupStatusPending(int count);

  /// No description provided for @backupStatusAwaiting.
  ///
  /// In en, this message translates to:
  /// **'Handed to iCloud; waiting for it to upload'**
  String get backupStatusAwaiting;

  /// No description provided for @backupStatusUnavailable.
  ///
  /// In en, this message translates to:
  /// **'iCloud Drive is off'**
  String get backupStatusUnavailable;

  /// No description provided for @backupStatusError.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save there; will retry'**
  String get backupStatusError;

  /// No description provided for @backupStatusOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get backupStatusOff;

  /// No description provided for @backupAndroidLarge.
  ///
  /// In en, this message translates to:
  /// **'Android\'s copy is getting close to its 25 MB limit.'**
  String get backupAndroidLarge;

  /// No description provided for @backupFileSection.
  ///
  /// In en, this message translates to:
  /// **'Backup file'**
  String get backupFileSection;

  /// No description provided for @backupExport.
  ///
  /// In en, this message translates to:
  /// **'Save a backup file'**
  String get backupExport;

  /// No description provided for @backupExportSubtitle.
  ///
  /// In en, this message translates to:
  /// **'One file for anywhere else, like Proton Drive or a USB stick. It doesn\'t update itself: save a new one after you send.'**
  String get backupExportSubtitle;

  /// No description provided for @backupExported.
  ///
  /// In en, this message translates to:
  /// **'Backup file saved'**
  String get backupExported;

  /// No description provided for @backupImport.
  ///
  /// In en, this message translates to:
  /// **'Import a backup file'**
  String get backupImport;

  /// No description provided for @backupImportSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Adds what a backup file holds to this wallet.'**
  String get backupImportSubtitle;

  /// No description provided for @backupImported.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Imported 1 new change} other{Imported {count} new changes}}'**
  String backupImported(int count);

  /// No description provided for @backupImportNothingNew.
  ///
  /// In en, this message translates to:
  /// **'Nothing new in that file'**
  String get backupImportNothingNew;

  /// No description provided for @backupImportWrongWallet.
  ///
  /// In en, this message translates to:
  /// **'That file isn\'t a backup of this wallet'**
  String get backupImportWrongWallet;

  /// No description provided for @backupFailed.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong: {error}'**
  String backupFailed(String error);

  /// No description provided for @backupTorNote.
  ///
  /// In en, this message translates to:
  /// **'iCloud and Android backup are run by the operating system and don\'t go through Tor.'**
  String get backupTorNote;

  /// No description provided for @backupUnrecorded.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 sent payment has no backup record: it was sent from another wallet, or before backup was available.} other{{count} sent payments have no backup record: they were sent from another wallet, or before backup was available.}}'**
  String backupUnrecorded(int count);

  /// No description provided for @backupRestoreTitle.
  ///
  /// In en, this message translates to:
  /// **'Last restore'**
  String get backupRestoreTitle;

  /// No description provided for @backupRestoreSummary.
  ///
  /// In en, this message translates to:
  /// **'{payments, plural, =1{Found 1 payment} other{Found {payments} payments}}; {contacts, plural, =1{restored 1 contact} other{restored {contacts} contacts}}.'**
  String backupRestoreSummary(int payments, int contacts);

  /// No description provided for @backupRestoreUnreadable.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 file couldn\'t be read.} other{{count} files couldn\'t be read.}}'**
  String backupRestoreUnreadable(int count);

  /// No description provided for @backupRestoreGaps.
  ///
  /// In en, this message translates to:
  /// **'Some changes made on another device are missing. Open the wallet on that device so it can upload them.'**
  String get backupRestoreGaps;

  /// No description provided for @backupRestoreConflicts.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 payment has two different records; both are kept.} other{{count} payments have two different records; both are kept.}}'**
  String backupRestoreConflicts(int count);

  /// No description provided for @backupDeleteICloud.
  ///
  /// In en, this message translates to:
  /// **'Delete the iCloud copy'**
  String get backupDeleteICloud;

  /// No description provided for @backupDeleteICloudBody.
  ///
  /// In en, this message translates to:
  /// **'Removes this wallet\'s backup from iCloud. The copy on this device stays, and iCloud gets it again if iCloud backup is on.'**
  String get backupDeleteICloudBody;

  /// No description provided for @backupDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get backupDeleteConfirm;

  /// No description provided for @backupCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get backupCancel;

  /// No description provided for @backupDeleted.
  ///
  /// In en, this message translates to:
  /// **'iCloud copy deleted'**
  String get backupDeleted;

  /// No description provided for @backupRestoreFound.
  ///
  /// In en, this message translates to:
  /// **'Restored {payments, plural, =1{1 payment} other{{payments} payments}} and {contacts, plural, =1{1 contact} other{{contacts} contacts}} from your backup'**
  String backupRestoreFound(int payments, int contacts);

  /// No description provided for @backupNoneFoundTitle.
  ///
  /// In en, this message translates to:
  /// **'No backup found'**
  String get backupNoneFoundTitle;

  /// No description provided for @backupNoneFoundBody.
  ///
  /// In en, this message translates to:
  /// **'If you saved a backup file, import it now to get back who you paid and your address book.'**
  String get backupNoneFoundBody;

  /// No description provided for @backupSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get backupSkip;
}

class _BackupLocalizationsDelegate extends LocalizationsDelegate<BackupLocalizations> {
  const _BackupLocalizationsDelegate();

  @override
  Future<BackupLocalizations> load(Locale locale) {
    return SynchronousFuture<BackupLocalizations>(lookupBackupLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'pt'].contains(locale.languageCode);

  @override
  bool shouldReload(_BackupLocalizationsDelegate old) => false;
}

BackupLocalizations lookupBackupLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return BackupLocalizationsEn();
    case 'pt':
      return BackupLocalizationsPt();
  }

  throw FlutterError(
    'BackupLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
