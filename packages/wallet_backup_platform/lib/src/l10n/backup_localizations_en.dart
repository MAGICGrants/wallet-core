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
  String get backupSeedWarningBold =>
      'This does NOT back up your recovery phrase, which you still need to do separately or you could lose your funds.';

  @override
  String get backupSeedWarning =>
      'This backs up additional data not stored on the blockchain, like certain transaction data and your address book.';

  @override
  String get backupSecurityNote =>
      'The backup files are secure with quantum resistant encryption. They are encrypted with keys derived from your recovery phrase, so you can restore any backups with it. If you store your backups on a cloud service, they cannot see the contents of the backups, but they can see certain metadata which you may consider sensitive.';

  @override
  String get backupLegacySeed =>
      'Backup isn\'t available for 25-word recovery phrases. To use it, create a new wallet with a 16-word recovery phrase and send your funds to it.';

  @override
  String get backupUnsupportedPassphrase =>
      'Backup isn\'t available yet for recovery phrases with an offset passphrase.';

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
  String get backupICloud => 'iCloud';

  @override
  String get backupICloudDescription =>
      'iCloud backups are performed by your operating system and are not protected with Tor.';

  @override
  String get backupAndroid => 'Android backup';

  @override
  String get backupAndroidDescription =>
      'Android backups are performed by your operating system and are not protected with Tor.';

  @override
  String get backupAndroidShort => 'Android';

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
  String get backupAndroidLarge => 'Android\'s copy is getting close to its 25 MB limit.';

  @override
  String get backupFileSection => 'Backup file';

  @override
  String get backupExport => 'Save a backup file';

  @override
  String get backupExported => 'Backup file saved';

  @override
  String get backupImport => 'Import a backup file';

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
  String get backupDeleteAndroid => 'Delete the Android backup copy';

  @override
  String get backupDeleteAndroidBody =>
      'Removes this wallet\'s files from Android backup on this device, so Android\'s next backup no longer carries them.';

  @override
  String get backupDeletedAndroid => 'Android backup copy deleted';

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
  String get backupEnable => 'Back up payment details';

  @override
  String get backupAutomaticSection => 'Automatic (Recommended)';

  @override
  String get backupManualSection => 'Manual';

  @override
  String get backupFileDescription => 'Manually save a snapshot anywhere you want.';

  @override
  String get backupDeleteLocal => 'Delete the copy on this device';

  @override
  String get backupDeleteLocalTitle => 'Delete the copy on this device?';

  @override
  String get backupDeleteLocalBody =>
      'Turns off iCloud and Android backup and deletes the app\'s working copy on this device. The copies in iCloud and Android backup, and saved backup files, stay until you delete them.';

  @override
  String get backupDeletedLocal => 'Backup on this device deleted';

  @override
  String get importTitle => 'Import wallet data';

  @override
  String get importIntro =>
      'If you have a backup file, you can restore it here. You can change these behaviors later in settings.';

  @override
  String importFromLocation(String where) {
    return 'From $where';
  }

  @override
  String importFromLocationNote(String where) {
    return 'If found, this also turns on automatic $where backups.';
  }

  @override
  String get importFromFile => 'From a backup file';

  @override
  String get importFromFileNote =>
      'This will not turn on automatic backups, which we suggest enabling in settings.';

  @override
  String get importNo => 'Skip';

  @override
  String get importNoNote => 'You can restore from automatic or manual backups later.';

  @override
  String importLooking(String where) {
    return 'Looking in $where…';
  }

  @override
  String get importReading => 'Reading the backup file…';

  @override
  String get importNotFoundTitle => 'No backup found';

  @override
  String get importOk => 'OK';

  @override
  String importNotFound(String where) {
    return 'No backup of this wallet in $where.';
  }

  @override
  String importUnavailable(String where) {
    return 'Couldn\'t reach $where. Check that it\'s on for this device, then try again.';
  }

  @override
  String get importDoneTitle => 'Wallet data imported';

  @override
  String get importScanNote => 'Each payment\'s details appear as the wallet finishes scanning.';

  @override
  String importLocationOn(String where) {
    return 'Backup to $where is on. You can turn it off in Settings > Backup.';
  }

  @override
  String get importFileBackupNote =>
      'Automatic backups are off. Save a backup file from Settings > Backup to keep a copy.';

  @override
  String get importDone => 'Done';
}
