import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'logging.dart';
import 'storage/backup_exclusion.dart';
import 'storage/owner_only.dart';

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
  /// `.skylight_wallet`. [windowsAppDataDir] is the subpath under
  /// `%LOCALAPPDATA%` (and, for builds before it, `%APPDATA%`), e.g.
  /// `MAGIC Grants/Skylight Wallet`.
  static void install({
    required String linuxDirName,
    required String windowsAppDataDir,
    DirectoryProvider? directories,
  }) {
    _linuxDirName = linuxDirName;
    _windowsAppDataDir = windowsAppDataDir;
    if (directories != null) WalletPaths.directories = directories;
    // The desktop folders are resolved once per name.
    _linuxAppDirOnce = null;
    _windowsAppDirOnce = null;
  }

  static void resetForTesting() {
    _linuxDirName = null;
    _windowsAppDataDir = null;
    directories = const PathProviderDirectories();
    _linuxAppDirOnce = null;
    _windowsAppDirOnce = null;
  }

  static String get _linux =>
      _linuxDirName ?? (throw StateError('WalletPaths.install() was not called'));

  static String get _windows =>
      _windowsAppDataDir ?? (throw StateError('WalletPaths.install() was not called'));
}

/// Root directory for this app's wallet files, caches and logs.
///
/// Everything in it is sensitive and kept out of backups wherever the platform
/// allows: the wallet files, the seed store, the security-key file and, on
/// Linux and Windows, `wallet.key`. A copy that outlives the moment security
/// keys are set up still opens with whatever opened it then (the keystore's
/// password, or the typed one), so none should leave the device. The recovery
/// phrase restores the wallet on a new device instead.
///
/// - Android: the sandboxed documents directory; its backup rules include only
///   the metadata backup's folder.
/// - iOS and macOS: a directory kept out of iCloud, computer and Time Machine
///   backups ([iosAppDirName], [excludeFromDeviceBackup]).
/// - Windows: under `%LOCALAPPDATA%`, which stays on this computer
///   ([prepareWindowsAppDir]).
/// - Linux: a hidden directory in the home folder, private to its owner
///   ([restrictToOwner]) and marked for backup tools to skip
///   ([markExcludedFromLinuxBackups]). Phones' sandboxes, the Mac app's
///   container and Windows' profile folders are the owner's already.
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
    return _linuxAppDir(Directory('$homeDir/${WalletPaths._linux}'));
  }

  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (appData == null || localAppData == null) {
      throw Exception('APPDATA or LOCALAPPDATA environment variable is not set');
    }
    return _windowsAppDir(
      roaming: Directory('$appData/${WalletPaths._windows}'),
      local: Directory('$localAppData/${WalletPaths._windows}/$iosAppDirName'),
    );
  }

  if (Platform.isIOS) return _iosAppDir();
  if (Platform.isMacOS) return _macAppDir();

  return WalletPaths.directories.applicationDocuments();
}

/// The app directory's name under `Library/Application Support` on iOS and
/// macOS, and under `%LOCALAPPDATA%\<company>\<product>` on Windows, whose
/// folder is also path_provider's cache folder for plugins.
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

/// Entries the Windows Roaming folder keeps: path_provider gives the same
/// folder to the settings and secure-storage plugins, which look for their
/// files there.
const _windowsPluginFiles = {'shared_preferences.json', 'flutter_secure_storage.dat'};

Future<Directory>? _windowsAppDirOnce;

Future<Directory> _windowsAppDir({required Directory roaming, required Directory local}) async {
  try {
    return await (_windowsAppDirOnce ??= prepareWindowsAppDir(roaming: roaming, local: local));
  } catch (_) {
    // Not cached: the next caller tries again, and the move picks up where it
    // stopped.
    _windowsAppDirOnce = null;
    rethrow;
  }
}

/// Windows: the app directory under `%LOCALAPPDATA%` ([local]), which stays on
/// this computer. `%APPDATA%` ([roaming]) is copied to a server with a roaming
/// profile and can be redirected to a network share, and the wallet's files
/// must not leave the machine. Neither is in File History, Windows Backup or
/// OneDrive's folders by default.
///
/// Builds before this kept them in [roaming], the folder path_provider also
/// gives the settings and secure-storage plugins; [moveIntoAppDir] moves this
/// app's entries once, by rename, and leaves the plugins' files. A [roaming]
/// folder on another volume (redirected to a share) cannot be moved that way:
/// it stays in use, and is logged.
@visibleForTesting
Future<Directory> prepareWindowsAppDir({
  required Directory roaming,
  required Directory local,
  bool Function(String a, String b)? sameVolume,
}) async {
  if (await local.exists()) return local;
  final staging = Directory('${local.path}$_stagingSuffix');
  final hasOld =
      await roaming.exists() &&
      await roaming
          .list(followLinks: false)
          .any((e) => !_windowsPluginFiles.contains(p.basename(e.path)));
  if (!hasOld && !await staging.exists()) {
    await local.create(recursive: true);
    return local;
  }
  if (!(sameVolume ?? _sameVolume)(roaming.path, local.path)) {
    log(
      LogLevel.warn,
      '[Paths] The wallet folder is on another volume than %LOCALAPPDATA%; left in %APPDATA%',
    );
    return roaming;
  }
  await local.parent.create(recursive: true);
  await moveIntoAppDir(from: roaming, to: local, keep: _windowsPluginFiles);
  log(LogLevel.info, '[Paths] Moved the wallet folder from %APPDATA% to %LOCALAPPDATA%');
  return local;
}

bool _sameVolume(String a, String b) =>
    p.rootPrefix(p.absolute(a)).toLowerCase() == p.rootPrefix(p.absolute(b)).toLowerCase();

/// The signature line backup tools match in a `CACHEDIR.TAG`
/// (https://bford.info/cachedir/).
const _cacheDirTagSignature = 'Signature: 8a477f597d28d172789f06886806bc55';

const _cacheDirTag = '''$_cacheDirTagSignature
# Kept out of backups on purpose. This folder holds an encrypted wallet whose
# copies must not outlive its security keys; the recovery phrase restores it.
# For information about cache directory tags, see https://bford.info/cachedir/
''';

Future<Directory>? _linuxAppDirOnce;

Future<Directory> _linuxAppDir(Directory dir) async {
  try {
    return await (_linuxAppDirOnce ??= () async {
      await dir.create(recursive: true);
      // Before anything is written in it: from here on, everything the app
      // makes is the owner's only.
      restrictToOwner(dir);
      if (!await markExcludedFromLinuxBackups(dir)) {
        log(LogLevel.error, '[Paths] The wallet directory is not marked for backups to skip');
      }
      return dir;
    }());
  } catch (_) {
    _linuxAppDirOnce = null;
    rethrow;
  }
}

/// Linux: marks [dir] for backup tools to skip, as far as they let an app ask.
/// Déjà Dup (GNOME's and Ubuntu's built-in backup, 42.1 and later) skips a
/// folder holding a `CACHEDIR.TAG` or a `.deja-dup-ignore`; borg, restic and
/// tar skip a `CACHEDIR.TAG` folder when asked to leave out caches. Nothing on
/// Linux stops a tool that copies the whole home folder regardless. Returns
/// whether both markers are in place.
@visibleForTesting
Future<bool> markExcludedFromLinuxBackups(Directory dir) async {
  try {
    final tag = File(p.join(dir.path, 'CACHEDIR.TAG'));
    if (!await tag.exists() || !(await tag.readAsString()).startsWith(_cacheDirTagSignature)) {
      await tag.writeAsString(_cacheDirTag, flush: true);
    }
    final ignore = File(p.join(dir.path, '.deja-dup-ignore'));
    if (!await ignore.exists()) await ignore.writeAsString('', flush: true);
    return true;
  } catch (e) {
    log(LogLevel.error, '[Paths] Could not mark ${dir.path} for backups to skip: $e');
    return false;
  }
}

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
///
/// Entries named in [keep] stay in [from].
@visibleForTesting
Future<void> moveIntoAppDir({
  required Directory from,
  required Directory to,
  bool Function(String path)? excludeFromBackup,
  Set<String> keep = _staysInDocuments,
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
      if (keep.contains(name)) continue;
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
