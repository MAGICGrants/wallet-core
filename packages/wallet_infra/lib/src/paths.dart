import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'logging.dart';

/// Supplies platform directories.
///
/// Injected because `path_provider` is a plugin: under `flutter test` there is
/// no platform channel, so anything calling it directly is untestable. Every
/// store in `wallet_domain` sits on top of these paths, so leaving the boundary
/// unmockable would make the whole domain layer need a device.
abstract class DirectoryProvider {
  const DirectoryProvider();

  Future<Directory> applicationDocuments();

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
/// directory is shared with the user's own files; mobile uses the sandboxed
/// documents directory directly.
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

  return WalletPaths.directories.applicationDocuments();
}

Future<void> createAppDir() async {
  final appDir = await getAppDir();
  if (!await appDir.exists()) {
    await appDir.create(recursive: true);
  }
}

/// Removes Tor's cache and state directories on iOS.
///
/// iOS restores the documents directory from backup, and a restored Tor state
/// directory refers to a device that no longer exists.
Future<void> cleanTorDirectoriesOnIOS() async {
  if (!Platform.isIOS) return;

  final documentsDir = await WalletPaths.directories.applicationDocuments();

  for (final name in ['tor_cache', 'tor_state']) {
    final dir = Directory('${documentsDir.path}/$name');
    if (!await dir.exists()) continue;
    try {
      await dir.delete(recursive: true);
      log(LogLevel.info, 'Deleted $name directory');
    } catch (e) {
      log(LogLevel.error, 'Failed to delete $name directory: $e');
    }
  }
}
