import 'dart:io';

import 'package:wallet_infra/wallet_infra.dart';

/// The copies a security-key upgrade takes before it re-keys a wallet's files
/// ([WalletManager]), so one cut short can be put back.
///
/// Beside each file the upgrade may write, `<file>.upgrade-bak` holds its
/// copy, or `<file>.upgrade-new` (empty) says it did not exist and is to be
/// deleted. `guard_upgrade` marks a complete set: written after the last copy,
/// deleted after the copies once the upgrade is kept or put back. All of them
/// live in the app's folder, beside the wallet's files.
class GuardUpgradeFiles {
  GuardUpgradeFiles._();

  static const _markerName = 'guard_upgrade';
  static const _copySuffix = '.upgrade-bak';
  static const _absentSuffix = '.upgrade-new';

  static Future<File> _marker() async => File('${(await getAppDir()).path}/$_markerName');

  /// Whether an upgrade began and was neither kept nor put back: the app did
  /// not live to finish it.
  static Future<bool> inProgress() async => (await _marker()).exists();

  /// Copies each of [paths], or notes that it does not exist, then marks the
  /// set complete. Leftovers of a set never marked go first. Only for files
  /// nothing holds open: on Windows an open Monero wallet locks its keys file.
  static Future<void> backUp(Iterable<String> paths) async {
    await discard();
    for (final path in paths.toSet()) {
      final file = File(path);
      if (await file.exists()) {
        await writeFileAtomic(File('$path$_copySuffix'), await file.readAsBytes());
      } else {
        await writeFileAtomic(File('$path$_absentSuffix'), const []);
      }
    }
    await writeFileAtomic(await _marker(), const []);
  }

  /// Puts every file back as it was before [backUp]: each copy over its file,
  /// and a file that did not exist deleted. Each step is a rename or a delete,
  /// so one cut short is finished by running it again. The marker goes last.
  static Future<void> restore() async {
    for (final file in await _files(_copySuffix)) {
      await file.rename(_original(file, _copySuffix));
    }
    for (final file in await _files(_absentSuffix)) {
      final original = File(_original(file, _absentSuffix));
      if (await original.exists()) await original.delete();
      await file.delete();
    }
    final marker = await _marker();
    if (await marker.exists()) await marker.delete();
  }

  /// Deletes the copies, then the marker: the upgrade was kept, or there is
  /// none. The copies are under the old password, so none may outlast it.
  static Future<void> discard() async {
    for (final file in [...await _files(_copySuffix), ...await _files(_absentSuffix)]) {
      await file.delete();
    }
    final marker = await _marker();
    if (await marker.exists()) await marker.delete();
  }

  static String _original(File file, String suffix) =>
      file.path.substring(0, file.path.length - suffix.length);

  static Future<List<File>> _files(String suffix) async {
    final dir = await getAppDir();
    if (!await dir.exists()) return const [];
    return [
      await for (final entry in dir.list(followLinks: false))
        if (entry is File && entry.path.endsWith(suffix)) entry,
    ];
  }
}
