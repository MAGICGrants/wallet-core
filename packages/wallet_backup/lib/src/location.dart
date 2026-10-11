import 'dart:io';
import 'dart:typed_data';

import 'crypto.dart';

/// Somewhere the backup's files can live (plan §2.4): anything that can
/// create, read, list and delete a file.
///
/// Every method is scoped to one [folder], the seed's folder name (§3), so two
/// wallets never share a directory.
abstract class BackupLocation {
  /// Stable identifier, used for settings and status.
  String get id;

  /// Whether the location is usable right now (e.g. iCloud Drive signed in).
  Future<bool> isAvailable();

  /// Names in [folder]; empty if the folder does not exist.
  Future<List<String>> list(String folder);

  /// The file's bytes, or null if it is gone (another device may have just
  /// removed it; that is not an error).
  Future<Uint8List?> read(String folder, String name);

  /// Creates [name]. Create-only: succeeds without writing if the same bytes
  /// are already there, throws [BackupNameConflict] if different bytes are.
  Future<void> create(String folder, String name, Uint8List data);

  Future<void> deleteFolder(String folder);

  /// Whether the provider reports [name] as uploaded, or null when it cannot
  /// say (a local folder; a sync app that only takes files over).
  Future<bool?> isUploaded(String folder, String name) async => null;
}

class BackupNameConflict implements Exception {
  const BackupNameConflict(this.name);

  final String name;

  @override
  String toString() => 'BackupNameConflict($name)';
}

/// A plain directory: Android's Auto Backup folder, or the local copy.
///
/// Writes go to a temporary name, are flushed to disk, then renamed, so a crash
/// never leaves a partial file under a real name.
class FolderLocation extends BackupLocation {
  FolderLocation(this.id, this._root);

  @override
  final String id;

  final Future<Directory> Function() _root;

  Future<Directory> _dir(String folder) async => Directory('${(await _root()).path}/$folder');

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<String>> list(String folder) async {
    final dir = await _dir(folder);
    if (!await dir.exists()) return [];
    return [
      await for (final e in dir.list(followLinks: false))
        if (e is File && !e.uri.pathSegments.last.startsWith('.')) e.uri.pathSegments.last,
    ];
  }

  @override
  Future<Uint8List?> read(String folder, String name) async {
    final f = File('${(await _dir(folder)).path}/$name');
    try {
      return await f.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> create(String folder, String name, Uint8List data) async {
    final dir = await _dir(folder);
    await dir.create(recursive: true);
    final target = File('${dir.path}/$name');
    if (await target.exists()) {
      if (bytesEqual(await target.readAsBytes(), data)) return;
      throw BackupNameConflict(name);
    }
    final tmp = File('${dir.path}/.tmp-${toHex(randomBytes(8))}');
    final raf = await tmp.open(mode: FileMode.writeOnly);
    try {
      await raf.writeFrom(data);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(target.path);
  }

  @override
  Future<void> deleteFolder(String folder) async {
    final dir = await _dir(folder);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Bytes used under every folder, for the Auto Backup size warning.
  Future<int> totalBytes() async {
    final root = await _root();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  /// Removes everything, every folder included.
  Future<void> clear() async {
    final root = await _root();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

/// An in-memory location, for tests: it can refuse writes, lose them, or hold
/// files written by someone else.
class MemoryLocation extends BackupLocation {
  MemoryLocation(this.id);

  @override
  final String id;

  final Map<String, Map<String, Uint8List>> folders = {};
  bool available = true;
  bool failWrites = false;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<List<String>> list(String folder) async {
    _check();
    return (folders[folder] ?? const {}).keys.toList();
  }

  @override
  Future<Uint8List?> read(String folder, String name) async {
    _check();
    return folders[folder]?[name];
  }

  @override
  Future<void> create(String folder, String name, Uint8List data) async {
    _check();
    if (failWrites) throw const FileSystemException('write refused');
    final f = folders[folder] ??= {};
    final existing = f[name];
    if (existing != null) {
      if (bytesEqual(existing, data)) return;
      throw BackupNameConflict(name);
    }
    f[name] = Uint8List.fromList(data);
  }

  @override
  Future<void> deleteFolder(String folder) async => folders.remove(folder);

  void _check() {
    if (!available) throw const FileSystemException('location unavailable');
  }
}
