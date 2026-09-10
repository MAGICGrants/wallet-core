import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wallet_paths');
    WalletPaths.install(
      linuxDirName: '.test_wallet',
      windowsAppDataDir: 'MAGIC Grants/Test Wallet',
      directories: FixedDirectories(tmp),
    );
  });

  tearDown(() {
    WalletPaths.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test(
    'throws a clear error when install() was never called',
    () async {
      WalletPaths.resetForTesting();
      expect(getAppDir(), throwsStateError);
    },
    // Only Linux and Windows consult the configured naming; elsewhere the app
    // dir is the documents dir and there is nothing to be missing.
    skip: (Platform.isLinux || Platform.isWindows) ? false : 'naming is only used on Linux/Windows',
  );

  // Not skipped anywhere, deliberately. getAppDir() used to resolve the Linux
  // and Windows branches from HOME/%APPDATA% before consulting the provider, so
  // an injected FixedDirectories was ignored on exactly the platform CI runs
  // on: every wallet_domain store test wrote to a $HOME/.skylight_wallet that
  // does not exist there, and 17 of them failed on Linux while passing on
  // macOS. A test double that cannot be heard on one platform is worse than no
  // double at all.
  test('an injected root is honoured on every platform', () async {
    expect((await getAppDir()).path, tmp.path);
  });

  test(
    'desktop derives the app dir from the environment, not from path_provider',
    () async {
      // Regression guard: getAppDir() used to await applicationDocuments()
      // unconditionally and discard it on desktop, taking a platform-channel
      // dependency the desktop path does not need.
      WalletPaths.install(
        linuxDirName: '.test_wallet',
        windowsAppDataDir: 'MAGIC Grants/Test Wallet',
        // A provider that would throw if consulted.
        directories: const _ExplodingDirectories(),
      );
      final dir = await getAppDir();
      expect(dir.path, isNot(tmp.path));
      expect(dir.path, contains('test_wallet'.replaceAll('_', '_')));
    },
    skip: (Platform.isLinux || Platform.isWindows) ? false : 'desktop-only path',
  );

  test('createAppDir is idempotent', () async {
    await createAppDir();
    expect(await (await getAppDir()).exists(), isTrue);
    await createAppDir();
    expect(await (await getAppDir()).exists(), isTrue);
  });

  test('FixedDirectories serves all three roles', () async {
    expect((await WalletPaths.directories.applicationDocuments()).path, tmp.path);
    expect((await WalletPaths.directories.externalStorage())?.path, tmp.path);
    expect((await WalletPaths.directories.appRoot())?.path, tmp.path);
  });

  test('the production provider claims no app root, so the platform decides', () async {
    WalletPaths.resetForTesting();
    expect(await WalletPaths.directories.appRoot(), isNull);
  });

  test('the production provider is restored by resetForTesting', () {
    WalletPaths.resetForTesting();
    expect(WalletPaths.directories, isA<PathProviderDirectories>());
  });

  test('cleanTorDirectoriesOnIOS is a no-op off iOS', () async {
    final torCache = Directory('${tmp.path}/tor_cache')..createSync();
    await cleanTorDirectoriesOnIOS();
    // Only iOS restores documents from backup, so only iOS needs the cleanup.
    expect(torCache.existsSync(), !Platform.isIOS);
  });
}

/// Fails if consulted. Used to prove the desktop path never touches the
/// `path_provider` boundary.
class _ExplodingDirectories extends DirectoryProvider {
  const _ExplodingDirectories();

  @override
  Future<Directory> applicationDocuments() async =>
      throw StateError('applicationDocuments() must not be called on desktop');

  @override
  Future<Directory?> externalStorage() async =>
      throw StateError('externalStorage() must not be called on desktop');
}
