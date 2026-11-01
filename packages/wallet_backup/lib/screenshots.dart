/// Store screenshots: a metadata backup that reports itself on and up to date
/// without keeping one.
///
/// A separate entry point, like `package:wallet_domain/screenshots.dart`: what
/// it reports is invented, so application code must never import it. An app's
/// screenshot test installs [SampleMetadataBackupService] through
/// `MetadataBackupSetup.serviceForTesting` before the app starts.
///
/// ```dart
/// import 'package:wallet_backup/screenshots.dart';
/// ```
library;

export 'src/screenshots/sample_backup_service.dart';
