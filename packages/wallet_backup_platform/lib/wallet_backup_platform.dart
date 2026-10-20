/// The metadata backup's platform side: the iCloud location, Android's Auto
/// Backup folder, and saving or importing a backup file. An app calls
/// [MetadataBackupSetup.install] in `main()`, on the UI isolate. See README.md.
library;

export 'src/icloud_location.dart';
export 'src/setup.dart';
