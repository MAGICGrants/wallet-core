/// The shared Backup screen and the after-restore prompt.
///
/// An app adds [BackupLocalizations.delegate] to its localizationsDelegates,
/// routes to [MetadataBackupScreen] from Settings, and calls
/// [scheduleBackupRestorePrompt] as it leaves the restore screen.
library;

export 'src/l10n/backup_localizations.dart';
export 'src/ui/metadata_backup_screen.dart';
