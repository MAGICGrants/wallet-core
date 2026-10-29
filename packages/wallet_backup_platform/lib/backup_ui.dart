/// The shared Backup screen and the after-restore "Import Wallet Data?" screen.
///
/// An app adds [BackupLocalizations.delegate] to its localizationsDelegates,
/// routes to [MetadataBackupScreen] from Settings, and calls
/// [scheduleImportWalletData] as it leaves the restore screen.
library;

export 'src/l10n/backup_localizations.dart';
export 'src/ui/import_wallet_data_screen.dart';
export 'src/ui/metadata_backup_screen.dart';
