/// Seed-keyed metadata backup for Monero wallets: payment destinations,
/// transaction keys and the address book, as many small sealed files.
///
/// Implements the implementation plan in ai-audit-resources'
/// research-projects/2026-10-09-trezor-suite-sync-vs-lws-metadata. Pure Dart;
/// the platform locations (iCloud) live in `wallet_backup_platform`.
library;

export 'src/backup_file.dart';
export 'src/backup_service.dart';
export 'src/bundle.dart';
export 'src/crypto.dart' show XChaCha20Poly1305, AuthenticationFailed;
export 'src/keys.dart';
export 'src/location.dart';
export 'src/merge.dart';
export 'src/monero_address.dart';
export 'src/naming.dart';
export 'src/padding.dart';
export 'src/records.dart';
