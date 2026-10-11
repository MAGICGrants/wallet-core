import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wallet_backup/wallet_backup.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'icloud_location.dart';

/// What an app supplies to the metadata backup.
class MetadataBackupConfig {
  const MetadataBackupConfig({
    required this.appName,
    required this.iCloudContainer,
    required this.exportFileStem,
  });

  /// The app's name, in the few strings that say who does what.
  final String appName;

  /// The app's iCloud container (iOS), e.g. `iCloud.org.magicgrants.skylightwallet`.
  final String iCloudContainer;

  /// The start of an exported file's name, e.g. `skylight-backup`.
  final String exportFileStem;
}

/// Installs the metadata backup for an app. UI isolate only: background
/// isolates leave [MetadataBackup.instance] null, so they never write a backup.
///
/// Locations by platform:
/// - **iOS**: the app's iCloud container ([ICloudLocation]), on by default.
/// - **Android**: Auto Backup. The files go to `<app dir>/metadata_backup/`,
///   the one folder the app's backup rules include, and Android copies it to
///   the user's Google Drive (or the phone's own backup service) about once a
///   day. On by default.
/// - **Everywhere**: the local copy (`<app dir>/metadata_backup_local/`, not
///   backed up by Android) and the single-file export.
class MetadataBackupSetup {
  MetadataBackupSetup._();

  static const autoBackupLocationId = 'android_auto_backup';

  /// Warn once Android's copy passes this; Auto Backup stops at 25 MB without
  /// telling anyone (plan §2.6).
  static const autoBackupWarnBytes = 20 * 1000 * 1000;

  static MetadataBackupService? _service;
  static MetadataBackupConfig? _config;

  static MetadataBackupService? get service => _service;

  static MetadataBackupConfig get config =>
      _config ?? (throw StateError('MetadataBackupSetup.install was not called'));

  static MetadataBackupService install(MetadataBackupConfig config) {
    final existing = _service;
    if (existing != null) return existing;
    _config = config;

    final locations = <BackupLocationConfig>[
      if (Platform.isIOS)
        BackupLocationConfig(
          location: ICloudLocation(config.iCloudContainer),
          defaultEnabled: true,
          delayPayments: true,
        ),
      if (Platform.isAndroid)
        BackupLocationConfig(
          location: FolderLocation(
            autoBackupLocationId,
            () async => Directory('${(await getAppDir()).path}/metadata_backup'),
          ),
          defaultEnabled: true,
          onDevice: true,
        ),
    ];
    final service = MetadataBackupService(
      localRoot: () async => Directory('${(await getAppDir()).path}/metadata_backup_local'),
      stateRoot: () => _stateRoot(config),
      locations: locations,
    );
    MetadataBackup.instance = service;
    return _service = service;
  }

  static bool _stateExcluded = false;

  /// The device state's directory. On iOS it is excluded from the phone's own
  /// backups, so restoring a phone from one starts a new device id (plan §4.1).
  /// Android's backup rules include only the Auto Backup folder, so there it
  /// is never backed up anyway.
  static Future<Directory> _stateRoot(MetadataBackupConfig config) async {
    final dir = Directory('${(await getAppDir()).path}/metadata_backup_state');
    if (Platform.isIOS && !_stateExcluded) {
      await dir.create(recursive: true);
      try {
        await ICloudLocation.excludeFromBackup(config.iCloudContainer, dir.path);
        _stateExcluded = true;
      } catch (e) {
        log(LogLevel.warn, '[Backup] Could not exclude the device state from backups: $e');
      }
    }
    return dir;
  }

  /// A file name for an export: the app's stem and today's date.
  static String exportFileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${config.exportFileStem}-${now.year}${two(now.month)}${two(now.day)}.bin';
  }

  /// Saves the whole backup as one file. On a phone it goes through the share
  /// sheet (Files, Proton Drive, a mail draft); on a desktop OS, a save dialog.
  /// Returns false when the user cancelled.
  static Future<bool> exportFile({Rect? sharePositionOrigin}) async {
    final service = _service;
    if (service == null) throw StateError('backup not installed');
    final bytes = await service.exportBundle();
    final name = exportFileName(DateTime.now());

    if (Platform.isAndroid || Platform.isIOS) {
      final dir = await Directory((await getTemporaryDirectory()).path).createTemp('backup');
      final file = File('${dir.path}/$name');
      try {
        await file.writeAsBytes(bytes, flush: true);
        final result = await SharePlus.instance.share(
          ShareParams(files: [XFile(file.path)], sharePositionOrigin: sharePositionOrigin),
        );
        return result.status != ShareResultStatus.dismissed;
      } finally {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    }

    final location = await getSaveLocation(suggestedName: name);
    if (location == null) return false;
    await File(location.path).writeAsBytes(bytes, flush: true);
    return true;
  }

  /// Larger than any real backup: thousands of 64 KiB files.
  static const maxImportBytes = 256 * 1024 * 1024;

  /// Lets the user pick a backup file and merges it in. Null when cancelled.
  /// Throws [FormatException] for a file that is not a backup of this wallet.
  static Future<ImportResult?> importFile() async {
    final service = _service;
    if (service == null) throw StateError('backup not installed');
    final picked = await openFile();
    if (picked == null) return null;
    if (await picked.length() > maxImportBytes) throw const FormatException('file too large');
    final Uint8List bytes = await picked.readAsBytes();
    return service.importBundle(bytes);
  }
}
