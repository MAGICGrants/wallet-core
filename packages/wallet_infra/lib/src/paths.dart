import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'logging.dart';
import 'storage/backup_exclusion.dart';

/// Supplies platform directories.
///
/// Injected because `path_provider` is a plugin: under `flutter test` there is
/// no platform channel, so anything calling it directly is untestable. Every
/// store in `wallet_domain` sits on top of these paths, so leaving the boundary
/// unmockable would make the whole domain layer need a device.
abstract class DirectoryProvider {
  const DirectoryProvider();

  Future<Directory> applicationDocuments();

  /// iOS's `Library/Application Support`, under which [getAppDir] lives there.
  /// Defaults to [applicationDocuments], so test doubles need not supply it.
  Future<Directory> applicationSupport() => applicationDocuments();

  /// Android's external storage, where logs are written. Null everywhere else.
  Future<Directory?> externalStorage();

  /// Replaces [getAppDir]'s entire platform decision when non-null.
  ///
  /// Needed because the Linux and Windows branches of [getAppDir] derive their
  /// path from `HOME` / `%APPDATA%` and never consult this provider at all; so
  /// injecting [FixedDirectories] silently did nothing there. Every store test
  /// wrote to the real `$HOME/.skylight_wallet`, which does not exist on a CI
  /// runner, and 17 `wallet_domain` tests failed on Linux while passing on
  /// macOS. A provider whose contract is "serve everything from here" has to be
  /// able to say so on every platform.
  ///
  /// Null in production, so the desktop paths keep deriving from the
  /// environment and keep not touching `path_provider`.
  Future<Directory?> appRoot() async => null;
}

/// Production implementation, backed by `path_provider`.
class PathProviderDirectories extends DirectoryProvider {
  const PathProviderDirectories();

  @override
  Future<Directory> applicationDocuments() => getApplicationDocumentsDirectory();

  @override
  Future<Directory> applicationSupport() => getApplicationSupportDirectory();

  @override
  Future<Directory?> externalStorage() async =>
      Platform.isAndroid ? getExternalStorageDirectory() : null;
}

// `FixedDirectories` lives in `package:wallet_infra/testing.dart`.

/// Where this app keeps its files.
///
/// Deliberately separate from `wallet_domain`'s `WalletAppConfig`, which
/// composes it: `wallet_infra` sits *below* the domain layer and cannot depend
/// on it. `WalletAppConfig.install()` calls [install] with its own values, so
/// apps still configure one object.
class WalletPaths {
  WalletPaths._();

  static DirectoryProvider directories = const PathProviderDirectories();

  static String? _linuxDirName;
  static String? _windowsAppDataDir;

  /// [linuxDirName] is the hidden directory under `$HOME`, e.g.
  /// `.skylight_wallet`. [windowsAppDataDir] is the subpath under `%APPDATA%`,
  /// e.g. `MAGIC Grants/Skylight Wallet`.
  static void install({
    required String linuxDirName,
    required String windowsAppDataDir,
    DirectoryProvider? directories,
  }) {
    _linuxDirName = linuxDirName;
    _windowsAppDataDir = windowsAppDataDir;
    if (directories != null) WalletPaths.directories = directories;
  }

  static void resetForTesting() {
    _linuxDirName = null;
    _windowsAppDataDir = null;
    directories = const PathProviderDirectories();
  }

  static String get _linux =>
      _linuxDirName ?? (throw StateError('WalletPaths.install() was not called'));

  static String get _windows =>
      _windowsAppDataDir ?? (throw StateError('WalletPaths.install() was not called'));
}

/// Root directory for this app's wallet files, caches and logs.
///
/// Desktop platforms get an app-specific directory because the documents
/// directory is shared with the user's own files. Android uses the sandboxed
/// documents directory directly; its backup rules include only the metadata
/// backup's folder. iOS and macOS use a directory kept out of the device's
/// backups (iCloud, computer backups, Time Machine) ([iosAppDirName]); see
/// [excludeFromDeviceBackup] for why.
Future<Directory> getAppDir() async {
  // An explicit root wins on every platform. This is the only thing a test can
  // say that the desktop branches below will hear.
  final root = await WalletPaths.directories.appRoot();
  if (root != null) return root;

  // Resolve the desktop cases first. They derive the path from environment
  // variables, so touching the provider here would take a platform-channel
  // dependency on a value that is then discarded.
  if (Platform.isLinux) {
    final homeDir = Platform.environment['HOME'];
    if (homeDir == null) throw Exception('HOME environment variable is not set');
    return Directory('$homeDir/${WalletPaths._linux}');
  }

  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData == null) throw Exception('APPDATA environment variable is not set');
    return Directory('$appData/${WalletPaths._windows}');
  }

  if (Platform.isIOS) return _iosAppDir();
  if (Platform.isMacOS) return _macAppDir();

  return WalletPaths.directories.applicationDocuments();
}

/// The app directory's name under `Library/Application Support` on iOS and
/// macOS.
///
/// Everything in it is left out of iCloud, computer and Time Machine backups,
/// matching
/// Android, whose rules back up only the metadata backup. A phone restored or
/// migrated from a backup therefore starts without a wallet and is restored
/// from the recovery phrase, which the this-device-only keystore already made
/// the only way back on another phone. The metadata backup itself goes to the
/// app's iCloud Drive container on iOS, not through device backups, so it is
/// unaffected.
const iosAppDirName = 'wallet';

/// Builds before this one kept the app directory in Documents, which iOS backs
/// up. [moveIntoAppDir] moves it once; this suffix names the staging directory
/// it fills before renaming it into place.
const _stagingSuffix = '.migrating';

/// Entries Documents keeps: iOS manages `Inbox` (files opened in the app).
const _staysInDocuments = {'Inbox', '.Trash'};

Future<Directory>? _iosAppDirOnce;

Future<Directory> _iosAppDir() async {
  try {
    return await (_iosAppDirOnce ??= _prepareIosAppDir());
  } catch (_) {
    // Not cached: the next caller tries again.
    _iosAppDirOnce = null;
    rethrow;
  }
}

Future<Directory>? _macAppDirOnce;

/// macOS: the same excluded directory under Application Support as iOS, but
/// nothing is moved into it. Earlier macOS builds kept a typed-password wallet
/// in Documents, which this build does not migrate; and an app run without the
/// sandbox would see the user's own Documents there, which must never be moved.
Future<Directory> _macAppDir() async {
  try {
    return await (_macAppDirOnce ??= () async {
      final support = await WalletPaths.directories.applicationSupport();
      final appDir = Directory(p.join(support.path, iosAppDirName));
      await appDir.create(recursive: true);
      if (!excludeFromDeviceBackup(appDir.path)) {
        log(LogLevel.error, '[Paths] The wallet directory is not excluded from device backups');
      }
      return appDir;
    }());
  } catch (_) {
    _macAppDirOnce = null;
    rethrow;
  }
}

Future<Directory> _prepareIosAppDir() async {
  final support = await WalletPaths.directories.applicationSupport();
  final appDir = Directory(p.join(support.path, iosAppDirName));
  if (!await appDir.exists()) {
    await moveIntoAppDir(
      from: await WalletPaths.directories.applicationDocuments(),
      to: appDir,
      excludeFromBackup: excludeFromDeviceBackup,
    );
  }
  // Every time, not only after the move: cheap, and it repairs a flag that a
  // restore or an earlier failure left unset.
  if (!excludeFromDeviceBackup(appDir.path)) {
    log(LogLevel.error, '[Paths] The wallet directory is not excluded from device backups');
  }
  return appDir;
}

/// Moves every entry of [from] into [to], which must not exist yet, without a
/// half-moved [to] ever being visible.
///
/// Entries are renamed into a staging directory beside [to], and the staging
/// directory is then renamed onto [to] in one step. Rename only, never copy and
/// delete: within one volume each rename is atomic, so every entry is in
/// exactly one place at every moment. Safe to run again after a crash at any
/// point (it picks up where it stopped), and from two isolates at once (both
/// fill the same staging directory; whichever renames it first wins, and the
/// other finds [to] in place). An entry whose name is already in staging is
/// left where it is and logged, never overwritten.
@visibleForTesting
Future<void> moveIntoAppDir({
  required Directory from,
  required Directory to,
  bool Function(String path)? excludeFromBackup,
}) async {
  final staging = Directory('${to.path}$_stagingSuffix');
  await staging.create(recursive: true);
  excludeFromBackup?.call(staging.path);

  bool exists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

  // Pass after pass until one moves nothing: a listing taken while another
  // isolate is moving entries out of the same directory may skip some.
  for (var moved = await from.exists(); moved;) {
    moved = false;
    await for (final entity in from.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (_staysInDocuments.contains(name)) continue;
      final destination = p.join(staging.path, name);
      if (exists(destination)) {
        // Moved by another isolate already, unless it is still here too: then
        // it is a second entry of that name, which must not overwrite the first.
        if (exists(entity.path)) {
          log(LogLevel.warn, '[Paths] $name is already in the new app directory; left in place');
        }
        continue;
      }
      try {
        await entity.rename(destination);
        moved = true;
      } on FileSystemException {
        // Another isolate moved it first; anything else is a real failure.
        if (exists(entity.path)) rethrow;
      }
    }
  }

  try {
    await staging.rename(to.path);
  } on FileSystemException {
    // Another isolate put its (the same) staging directory in place first.
    if (!await to.exists()) rethrow;
    try {
      await staging.delete(); // only if empty; never anything with files in it
    } on FileSystemException {
      // Left for the next run.
    }
  }
}

Future<void> createAppDir() async {
  final appDir = await getAppDir();
  if (!await appDir.exists()) {
    await appDir.create(recursive: true);
  }
}

/// Removes Tor's cache and state directories on iOS.
///
/// Builds before the app directory left Documents had them restored from
/// backups, where a Tor state directory refers to a device that no longer
/// exists. Tor keeps them under [getAppDir], where they now live.
Future<void> cleanTorDirectoriesOnIOS() async {
  if (!Platform.isIOS) return;

  final appDir = await getAppDir();

  for (final name in ['tor_cache', 'tor_state']) {
    final dir = Directory('${appDir.path}/$name');
    if (!await dir.exists()) continue;
    try {
      await dir.delete(recursive: true);
      log(LogLevel.info, 'Deleted $name directory');
    } catch (e) {
      log(LogLevel.error, 'Failed to delete $name directory: $e');
    }
  }
}
