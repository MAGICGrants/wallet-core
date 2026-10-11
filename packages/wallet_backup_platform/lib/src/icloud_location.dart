import 'package:flutter/services.dart';
import 'package:wallet_backup/wallet_backup.dart';

/// The app's own iCloud Drive container (plan §2.4): no picker, no setup.
///
/// Files sit outside the container's Documents folder, so the Files app does
/// not show them; iCloud syncs them to the user's other Apple devices and
/// uploads each one separately. Needs iCloud Drive on. The Swift half is
/// `ios/Classes/WalletBackupPlatformPlugin.swift`.
///
/// iCloud is run by the operating system, so it does not follow the app's Tor
/// setting.
class ICloudLocation extends BackupLocation {
  ICloudLocation(this.container);

  static const locationId = 'icloud';
  static const _channel = MethodChannel('org.magicgrants.wallet_backup_platform/icloud');

  /// The container identifier, e.g. `iCloud.org.magicgrants.skylightwallet`.
  /// It must match the app's entitlements and Info.plist.
  final String container;

  @override
  String get id => locationId;

  Map<String, Object?> _args([Map<String, Object?> more = const {}]) => {
    'container': container,
    ...more,
  };

  Future<T?> _call<T>(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      if (e.code == 'conflict') throw BackupNameConflict(e.message ?? '');
      throw ICloudException(e.code, e.message ?? '');
    }
  }

  @override
  Future<bool> isAvailable() async => await _call<bool>('available', _args()) ?? false;

  @override
  Future<List<String>> list(String folder) async =>
      (await _call<List<Object?>>('list', _args({'folder': folder})) ?? const []).cast<String>();

  @override
  Future<Uint8List?> read(String folder, String name) =>
      _call<Uint8List>('read', _args({'folder': folder, 'name': name}));

  @override
  Future<void> create(String folder, String name, Uint8List data) =>
      _call<void>('create', _args({'folder': folder, 'name': name, 'data': data}));

  @override
  Future<void> deleteFolder(String folder) =>
      _call<void>('deleteFolder', _args({'folder': folder}));

  /// Keeps [path] (a directory) out of the iPhone's own iCloud and Finder
  /// backups. Used for the backup's device state, so a phone restored from a
  /// backup starts a new device id rather than writing as the old phone.
  static Future<void> excludeFromBackup(String container, String path) => ICloudLocation(
    container,
  )._call<void>('excludeFromBackup', {'container': container, 'path': path});

  @override
  Future<bool?> isUploaded(String folder, String name) =>
      _call<bool>('isUploaded', _args({'folder': folder, 'name': name}));
}

class ICloudException implements Exception {
  const ICloudException(this.code, this.message);

  /// `unavailable` (iCloud Drive off or signed out), `timeout`, `io`.
  final String code;
  final String message;

  @override
  String toString() => code == 'unavailable' ? 'iCloud Drive is off' : 'iCloud: $message';
}
