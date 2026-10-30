import 'dart:typed_data';

import 'package:wallet_backup/wallet_backup.dart' show MemoryLocation;
import 'package:wallet_backup_platform/wallet_backup_platform.dart' show SyncFolderLocation;

/// The sync folder, with a picker that answers [next] (null: cancelled) and
/// files kept in memory.
class FakeSyncFolder extends SyncFolderLocation {
  FakeSyncFolder() : super.base();

  final files = MemoryLocation(SyncFolderLocation.locationId);
  String? next = 'Documents/Skylight Backup';
  String? chosen;
  int picks = 0;

  @override
  String? get folderName => chosen;

  @override
  Future<bool> choose() async {
    picks++;
    if (next == null) return false;
    chosen = next;
    return true;
  }

  @override
  Future<void> forget() async => chosen = null;

  @override
  Future<bool> isAvailable() async => chosen != null;

  @override
  Future<List<String>> list(String folder) => files.list(folder);

  @override
  Future<Uint8List?> read(String folder, String name) => files.read(folder, name);

  @override
  Future<void> create(String folder, String name, Uint8List data) =>
      files.create(folder, name, data);

  @override
  Future<void> deleteFolder(String folder) => files.deleteFolder(folder);
}

const raven =
    'raven tail swear infant grief assist regular lamp duck valid someone little harsh puppy '
    'airport language';
