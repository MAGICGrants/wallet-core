import 'dart:async';
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
import 'sync_folder_location.dart';

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
/// The backup is opt-in: off until the user turns it on in Settings > Backup,
/// and each location below is off until the user turns that on too. Until
/// then nothing is written anywhere.
///
/// Locations by platform:
/// - **iOS**: the app's iCloud container ([ICloudLocation]). Each app has its
///   own container, so Skylight and Spice never share a backup through iCloud.
/// - **Android**: Auto Backup. The files go to `<app dir>/metadata_backup/`,
///   the one folder the app's backup rules include, and Android copies it to
///   the user's Google Drive (or the phone's own backup service) about once a
///   day. Files go in only while the location is on. Turning it off stops
///   adding them; what is there stays, and Android keeps carrying it. So does a
///   copy Android puts back with the app's files (a new phone, or the app
///   reinstalled), unread while the location is off. Only "Delete the Android
///   Backup Copy" in Settings > Backup removes them; turning the location on
///   reads them.
///   Auto Backup is for restoring, not syncing: Android keeps a separate copy
///   per device and puts it back only when the app is installed, so two
///   phones in use never see each other's changes.
/// - **Sync folder, on every platform**: a folder the user chooses
///   ([SyncFolderLocation]) and pairs with a folder sync app (Syncthing and
///   the like), or one on a network drive. Files are written to it right away
///   and it is watched, so devices sharing it pick up each other's changes as
///   the sync app brings them.
/// - **Everywhere**: the local copy (`<app dir>/metadata_backup_local/`, not
///   backed up by Android), kept only while a location is on, and the
///   single-file export.
class MetadataBackupSetup {
  MetadataBackupSetup._();

  static const autoBackupLocationId = 'android_auto_backup';

  /// Warn once Android's copy passes this; Auto Backup stops at 25 MB without
  /// telling anyone.
  static const autoBackupWarnBytes = 20 * 1000 * 1000;

  static MetadataBackupService? _service;
  static MetadataBackupConfig? _config;
  static SyncFolderLocation? _syncFolder;

  static MetadataBackupService? get service => _service;

  /// The sync folder location, once installed.
  static SyncFolderLocation? get syncFolder => _syncFolder;

  /// Whether a location that backs up by itself (iCloud, Android Auto Backup,
  /// a sync folder) is on: what the security checklist's backup step asks. A
  /// saved backup file does not count: it is a copy the user made once, not a
  /// backup that keeps up.
  ///
  /// Null where there is nothing to turn on: no service, a device with no such
  /// location, or a seed the backup cannot key (25 words, an offset
  /// passphrase).
  static Future<bool?> automaticBackupOn() async {
    final service = _service;
    if (service == null || service.locations.isEmpty) return null;
    switch (service.availability) {
      case BackupAvailability.legacySeed || BackupAvailability.unsupportedPassphrase:
        return null;
      case BackupAvailability.closed || BackupAvailability.opening || BackupAvailability.open:
        break;
    }
    if (!await service.isEnabled()) return false;
    for (final c in service.locations) {
      if (await service.isLocationEnabled(c.location.id)) return true;
    }
    return false;
  }

  /// Forgets the installed service, so each test installs its own.
  @visibleForTesting
  static void resetForTesting() {
    if (identical(MetadataBackup.instance, _service)) MetadataBackup.instance = null;
    _service = null;
    _config = null;
    _syncFolder = null;
    androidForTesting = null;
    syncFolderForTesting = null;
  }

  /// Sets up Android's location whatever the host, for tests of its screens.
  @visibleForTesting
  static bool? androidForTesting;

  /// Stands in for the platform's sync folder, for tests of its screens.
  @visibleForTesting
  static SyncFolderLocation? syncFolderForTesting;

  static MetadataBackupConfig get config =>
      _config ?? (throw StateError('MetadataBackupSetup.install was not called'));

  static MetadataBackupService install(MetadataBackupConfig config) {
    final existing = _service;
    if (existing != null) return existing;
    _config = config;
    final syncFolder = _syncFolder = syncFolderForTesting ?? SyncFolderLocation.forPlatform();
    unawaited(syncFolder.load());

    final locations = <BackupLocationConfig>[
      if (Platform.isIOS)
        BackupLocationConfig(location: ICloudLocation(config.iCloudContainer), delayPayments: true),
      if (androidForTesting ?? Platform.isAndroid)
        BackupLocationConfig(
          location: FolderLocation(
            autoBackupLocationId,
            () async => Directory('${(await getAppDir()).path}/metadata_backup'),
          ),
          onDevice: true,
        ),
      // Payments held back like iCloud's: the sync app sees when files land.
      BackupLocationConfig(location: syncFolder, delayPayments: true, retryUnreadable: true),
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
  /// backups, so restoring a phone from one starts a new device id.
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
    // To the second, so a second save the same day never suggests replacing
    // the first.
    return '${config.exportFileStem}-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}.bin';
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
    final bytes = await pickFile();
    if (bytes == null) return null;
    return service.importBundle(bytes);
  }

  /// Lets the user pick a backup file and reads it, without importing it.
  /// Null when cancelled. Throws [FormatException] for a file too large to be
  /// a backup.
  static Future<Uint8List?> pickFile() async {
    final picked = await openFile();
    if (picked == null) return null;
    if (await picked.length() > maxImportBytes) throw const FormatException('file too large');
    return picked.readAsBytes();
  }
}
