// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'backup_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class BackupLocalizationsEn extends BackupLocalizations {
  BackupLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get backupTitle => 'Backup';

  @override
  String get backupIntro =>
      'Who you paid, each payment\'s transaction key, and your address book, encrypted with your recovery phrase. Restore the phrase anywhere and they come back.';

  @override
  String get backupLegacySeed =>
      'Backup isn\'t available for 25-word seeds. To use it, create a new wallet with a 16-word seed and send your funds to it.';

  @override
  String get backupUnsupportedPassphrase =>
      'Backup isn\'t available for seeds with an offset passphrase yet.';

  @override
  String get backupLocked => 'Unlock your wallet to see its backup.';

  @override
  String get backupOpening => 'Opening your backup…';

  @override
  String backupSummary(int payments, int contacts) {
    String _temp0 = intl.Intl.pluralLogic(
      payments,
      locale: localeName,
      other: '$payments payments',
      one: '1 payment',
    );
    String _temp1 = intl.Intl.pluralLogic(
      contacts,
      locale: localeName,
      other: '$contacts contacts',
      one: '1 contact',
    );
    return '$_temp0 and $_temp1 backed up';
  }

  @override
  String backupLastChecked(String time) {
    return 'Last checked $time';
  }

  @override
  String get backupWhereSaved => 'Where it\'s saved';

  @override
  String get backupICloud => 'iCloud';

  @override
  String get backupICloudDescription =>
      'Syncs to your other Apple devices. Hidden from the Files app.';

  @override
  String get backupAndroid => 'Android backup';

  @override
  String backupAndroidDescription(String appName) {
    return 'Android copies it about once a day with your Google account or your phone\'s backup service, and puts it back when you reinstall $appName.';
  }

  @override
  String get backupLws => 'Light wallet server';

  @override
  String get backupComingSoon => 'Coming soon';

  @override
  String get backupStatusUpToDate => 'Up to date';

  @override
  String backupStatusPending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes waiting to upload',
      one: '1 change waiting to upload',
    );
    return '$_temp0';
  }

  @override
  String get backupStatusAwaiting => 'Handed to iCloud; waiting for it to upload';

  @override
  String get backupStatusUnavailable => 'iCloud Drive is off';

  @override
  String get backupStatusError => 'Couldn\'t save there; will retry';

  @override
  String get backupStatusOff => 'Off';

  @override
  String get backupAndroidLarge => 'Android\'s copy is getting close to its 25 MB limit.';

  @override
  String get backupFileSection => 'Backup file';

  @override
  String get backupExport => 'Save a backup file';

  @override
  String get backupExportSubtitle =>
      'One file for anywhere else, like Proton Drive or a USB stick. It doesn\'t update itself: save a new one after you send.';

  @override
  String get backupExported => 'Backup file saved';

  @override
  String get backupImport => 'Import a backup file';

  @override
  String get backupImportSubtitle => 'Adds what a backup file holds to this wallet.';

  @override
  String backupImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Imported $count new changes',
      one: 'Imported 1 new change',
    );
    return '$_temp0';
  }

  @override
  String get backupImportNothingNew => 'Nothing new in that file';

  @override
  String get backupImportWrongWallet => 'That file isn\'t a backup of this wallet';

  @override
  String backupFailed(String error) {
    return 'Something went wrong: $error';
  }

  @override
  String get backupTorNote =>
      'iCloud and Android backup are run by the operating system and don\'t go through Tor.';

  @override
  String backupUnrecorded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count sent payments have no backup record: they were sent from another wallet, or before backup was available.',
      one:
          '1 sent payment has no backup record: it was sent from another wallet, or before backup was available.',
    );
    return '$_temp0';
  }

  @override
  String get backupRestoreTitle => 'Last restore';

  @override
  String backupRestoreSummary(int payments, int contacts) {
    String _temp0 = intl.Intl.pluralLogic(
      payments,
      locale: localeName,
      other: 'Found $payments payments',
      one: 'Found 1 payment',
    );
    String _temp1 = intl.Intl.pluralLogic(
      contacts,
      locale: localeName,
      other: 'restored $contacts contacts',
      one: 'restored 1 contact',
    );
    return '$_temp0; $_temp1.';
  }

  @override
  String backupRestoreUnreadable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files couldn\'t be read.',
      one: '1 file couldn\'t be read.',
    );
    return '$_temp0';
  }

  @override
  String get backupRestoreGaps =>
      'Some changes made on another device are missing. Open the wallet on that device so it can upload them.';

  @override
  String backupRestoreConflicts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count payments have two different records; both are kept.',
      one: '1 payment has two different records; both are kept.',
    );
    return '$_temp0';
  }

  @override
  String get backupDeleteICloud => 'Delete the iCloud copy';

  @override
  String get backupDeleteICloudBody =>
      'Removes this wallet\'s backup from iCloud. The copy on this device stays, and iCloud gets it again if iCloud backup is on.';

  @override
  String get backupDeleteConfirm => 'Delete';

  @override
  String get backupCancel => 'Cancel';

  @override
  String get backupDeleted => 'iCloud copy deleted';

  @override
  String backupRestoreFound(int payments, int contacts) {
    String _temp0 = intl.Intl.pluralLogic(
      payments,
      locale: localeName,
      other: '$payments payments',
      one: '1 payment',
    );
    String _temp1 = intl.Intl.pluralLogic(
      contacts,
      locale: localeName,
      other: '$contacts contacts',
      one: '1 contact',
    );
    return 'Restored $_temp0 and $_temp1 from your backup';
  }

  @override
  String get backupNoneFoundTitle => 'No backup found';

  @override
  String get backupNoneFoundBody =>
      'If you saved a backup file, import it now to get back who you paid and your address book.';

  @override
  String get backupSkip => 'Skip';
}
