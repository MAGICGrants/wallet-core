import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:wallet_backup/wallet_backup.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// A folder the user chooses, on every platform. The backup writes its files
/// there and watches it for files other devices add, which a folder sync app
/// (Syncthing and the like) brings, or which sit there already when the
/// folder is on a network drive (NAS).
///
/// - **Android:** a folder from the system picker (the Storage Access
///   Framework), kept with a persisted grant. The app needs no permission for
///   it; a sync app needs its own. The Kotlin half is
///   `android/src/main/kotlin/.../SyncFolderChannel.kt`.
/// - **iOS:** a folder from the Files picker, kept as a bookmark. Every read
///   and write is coordinated, as folders of other apps' file providers need.
///   The Swift half is `ios/Classes/SyncFolder.swift`.
/// - **macOS:** a folder from the open panel, kept as a security-scoped
///   bookmark (`macos/Classes`), then read and written as plain files.
/// - **Windows and Linux:** a path.
///
/// One folder per app, for every wallet in it: each wallet's files go in a
/// subfolder named from its seed. Two apps pointed at the same folder share
/// the backup of a seed they both hold. Turning the location off forgets the
/// folder ([forget]); its files stay.
abstract class SyncFolderLocation extends BackupLocation {
  /// For a stand-in in tests; [SyncFolderLocation.forPlatform] otherwise.
  SyncFolderLocation.base();

  factory SyncFolderLocation.forPlatform() {
    if (Platform.isAndroid || Platform.isIOS) return _ChannelSyncFolder();
    if (Platform.isMacOS) return _MacSyncFolder();
    return _PathSyncFolder();
  }

  static const locationId = 'sync_folder';

  /// Preference key of the chosen folder: `{"ref": ..., "name": ...}`.
  static const prefKey = 'metadataBackup.syncFolder';

  @override
  String get id => locationId;

  /// The chosen folder as the user knows it ("Documents/Skylight Backup", a
  /// path), or null when none is chosen.
  String? get folderName => _name;

  /// The platform's handle on the folder: a tree URI on Android, a bookmark
  /// on iOS and macOS, a path elsewhere.
  String? _ref;
  String? _name;
  Future<void>? _loading;

  /// Reads the folder chosen earlier, if any: at startup, and before first
  /// use (every call after the first returns at once).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final raw = await SharedPreferencesService.get<String>(prefKey);
    if (raw == null) return;
    try {
      final saved = json.decode(raw) as Map<String, dynamic>;
      _ref = saved['ref'] as String?;
      _name = saved['name'] as String?;
    } on FormatException {
      await SharedPreferencesService.remove(prefKey);
    }
  }

  Future<void> _save(String ref, String name) async {
    _ref = ref;
    _name = name;
    await SharedPreferencesService.set<String>(prefKey, json.encode({'ref': ref, 'name': name}));
  }

  Future<void> _clear() async {
    _ref = null;
    _name = null;
    await SharedPreferencesService.remove(prefKey);
  }

  /// Asks the user for a folder. True when one was chosen: it replaces the old
  /// one, whose access is given up. False when cancelled, changing nothing.
  Future<bool> choose();

  /// Forgets the folder and gives up access to it. Its files stay.
  Future<void> forget();
}

/// A sync folder that could not be used.
class SyncFolderException implements Exception {
  const SyncFolderException(this.code, this.message);

  /// `unavailable` (no folder, or it cannot be reached), `renamed` (the
  /// folder's app stored a file under another name), `io`.
  final String code;
  final String message;

  @override
  String toString() => 'Sync folder: ${message.isEmpty ? code : message}';
}

/// Android and iOS: every operation goes through the native half.
class _ChannelSyncFolder extends SyncFolderLocation {
  _ChannelSyncFolder() : super.base();

  static const _channel = MethodChannel('org.magicgrants.wallet_backup_platform/folder');
  static const _changes = EventChannel('org.magicgrants.wallet_backup_platform/folder_changes');

  Future<T?> _call<T>(String method, [Map<String, Object?> args = const {}]) async {
    final ref = _ref;
    if (ref == null) throw const SyncFolderException('unavailable', 'No folder chosen');
    try {
      return await _channel.invokeMethod<T>(method, {'ref': ref, ...args});
    } on PlatformException catch (e) {
      if (e.code == 'conflict') throw BackupNameConflict(e.message ?? '');
      if (e.code == 'too_large') throw BackupFileTooLarge(e.message ?? '');
      throw SyncFolderException(e.code, e.message ?? '');
    }
  }

  @override
  Future<bool> choose() async {
    await load();
    final Map<String, Object?>? picked;
    try {
      picked = await _channel.invokeMapMethod<String, Object?>('choose', {'current': _ref});
    } on PlatformException catch (e) {
      throw SyncFolderException(e.code, e.message ?? '');
    }
    if (picked == null) return false;
    final old = _ref;
    final ref = picked['ref']! as String;
    await _save(ref, picked['name']! as String);
    if (old != null && old != ref) await _release(old);
    return true;
  }

  @override
  Future<void> forget() async {
    final old = _ref;
    await _clear();
    if (old != null) await _release(old);
  }

  Future<void> _release(String ref) async {
    try {
      await _channel.invokeMethod<void>('release', {'ref': ref});
    } on PlatformException catch (e) {
      log(LogLevel.warn, '[Backup] Could not release the old sync folder: ${e.code}');
    }
  }

  @override
  Future<bool> isAvailable() async {
    await load();
    if (_ref == null) return false;
    final Map<Object?, Object?>? r;
    try {
      r = await _call<Map<Object?, Object?>>('available');
    } on SyncFolderException catch (e) {
      log(LogLevel.warn, '[Backup] Sync folder unavailable: ${e.code}');
      return false;
    }
    // iOS renews a bookmark that has gone stale (the folder moved).
    final renewed = r?['ref'] as String?;
    if (renewed != null && renewed != _ref) await _save(renewed, _name ?? '');
    return r?['available'] == true;
  }

  @override
  Future<List<String>> list(String folder) async =>
      (await _call<List<Object?>>('list', {'folder': folder}) ?? const []).cast<String>();

  @override
  Future<Uint8List?> read(String folder, String name) =>
      _call<Uint8List>('read', {'folder': folder, 'name': name});

  @override
  Future<void> create(String folder, String name, Uint8List data) =>
      _call<void>('create', {'folder': folder, 'name': name, 'data': data});

  @override
  Future<void> deleteFolder(String folder) => _call<void>('deleteFolder', {'folder': folder});

  @override
  Stream<void> watch(String folder) {
    final ref = _ref;
    if (ref == null) return const Stream.empty();
    return _changes.receiveBroadcastStream({'ref': ref, 'folder': folder}).map((_) {});
  }
}

/// macOS: the folder is opened from its bookmark once per launch, then used
/// like any other path.
class _MacSyncFolder extends _PathSyncFolder {
  static const _channel = MethodChannel('org.magicgrants.wallet_backup_platform/folder');

  /// The path of the bookmark opened in this launch.
  String? _opened;

  @override
  String? get _path => _opened;

  @override
  Future<(String, String)?> _pick() async {
    final path = await getDirectoryPath(initialDirectory: _opened);
    if (path == null) return null;
    final String? ref;
    try {
      ref = await _channel.invokeMethod<String>('bookmark', {'path': path});
    } on PlatformException catch (e) {
      throw SyncFolderException(e.code, e.message ?? '');
    }
    if (ref == null) return null;
    final old = _opened;
    if (old != null && old != path) await _channel.invokeMethod<void>('release', {'path': old});
    _opened = path;
    return (ref, path);
  }

  @override
  Future<void> forget() async {
    final path = _opened;
    _opened = null;
    await _clear();
    if (path != null) {
      await _channel.invokeMethod<void>('release', {'path': path});
    }
  }

  @override
  Future<bool> isAvailable() async {
    await load();
    final ref = _ref;
    if (ref == null) return false;
    if (_opened == null) {
      try {
        final r = await _channel.invokeMapMethod<String, Object?>('open', {'ref': ref});
        _opened = r?['path'] as String?;
        final renewed = r?['ref'] as String?;
        if (renewed != null && renewed != ref) await _save(renewed, _opened ?? _name ?? '');
      } on PlatformException catch (e) {
        log(LogLevel.warn, '[Backup] Could not open the sync folder: ${e.code}');
        return false;
      }
    }
    return super.isAvailable();
  }
}

/// Windows and Linux: a path, and the folder read and written as plain files.
class _PathSyncFolder extends SyncFolderLocation {
  _PathSyncFolder() : super.base();

  String? get _path => _ref;

  late final _files = FolderLocation(SyncFolderLocation.locationId, () async {
    final path = _path;
    if (path == null) throw const SyncFolderException('unavailable', 'No folder chosen');
    return Directory(path);
  });

  /// Asks for a folder: its reference and the name shown for it, or null
  /// when cancelled.
  Future<(String, String)?> _pick() async {
    final path = await getDirectoryPath(initialDirectory: _path);
    return path == null ? null : (path, path);
  }

  @override
  Future<bool> choose() async {
    await load();
    final picked = await _pick();
    if (picked == null) return false;
    await _save(picked.$1, picked.$2);
    return true;
  }

  @override
  Future<void> forget() => _clear();

  @override
  Future<bool> isAvailable() async {
    await load();
    final path = _path;
    return path != null && await Directory(path).exists();
  }

  @override
  Future<List<String>> list(String folder) => _files.list(folder);

  @override
  Future<Uint8List?> read(String folder, String name) => _files.read(folder, name);

  @override
  Future<void> create(String folder, String name, Uint8List data) =>
      _files.create(folder, name, data);

  @override
  Future<void> deleteFolder(String folder) => _files.deleteFolder(folder);

  @override
  Stream<void> watch(String folder) async* {
    final path = _path;
    if (path == null) return;
    final dir = Directory('$path/$folder');
    await dir.create(recursive: true);
    yield* dir.watch().map((_) {});
  }
}
