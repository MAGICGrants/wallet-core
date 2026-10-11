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

  test('excludeFromDeviceBackup is a no-op off iOS', () {
    expect(excludeFromDeviceBackup(tmp.path), Platform.isIOS);
  });

  // The one-time move of the iOS app directory out of Documents (which iOS
  // backs up). Runs before any wallet is opened, from whichever isolate starts
  // first; it must never lose or overwrite a file, whatever interrupts it.
  group('moveIntoAppDir', () {
    late Directory docs;
    late Directory target;

    setUp(() {
      docs = Directory('${tmp.path}/Documents')..createSync();
      target = Directory('${tmp.path}/Library/Application Support/$iosAppDirName');
    });

    test('moves every entry, keeps Inbox, and flags the staging directory', () async {
      File('${docs.path}/master_seed').writeAsStringSync('seed');
      File('${docs.path}/wallet.fhse').writeAsStringSync('fhse');
      Directory('${docs.path}/metadata_backup_state').createSync();
      File('${docs.path}/metadata_backup_state/id').writeAsStringSync('device');
      Directory('${docs.path}/Inbox').createSync();
      final flagged = <String>[];

      await moveIntoAppDir(
        from: docs,
        to: target,
        excludeFromBackup: (path) {
          flagged.add(path);
          return true;
        },
      );

      expect(File('${target.path}/master_seed').readAsStringSync(), 'seed');
      expect(File('${target.path}/wallet.fhse').readAsStringSync(), 'fhse');
      expect(File('${target.path}/metadata_backup_state/id').readAsStringSync(), 'device');
      expect(File('${docs.path}/master_seed').existsSync(), isFalse);
      expect(Directory('${docs.path}/Inbox').existsSync(), isTrue);
      expect(Directory('${target.path}.migrating').existsSync(), isFalse);
      expect(flagged, ['${target.path}.migrating']);
    });

    test('picks up where a crash midway left off', () async {
      final staging = Directory('${target.path}.migrating')..createSync(recursive: true);
      File('${staging.path}/wallet').writeAsStringSync('moved before the crash');
      File('${docs.path}/wallet.keys').writeAsStringSync('not yet moved');

      await moveIntoAppDir(from: docs, to: target);

      expect(File('${target.path}/wallet').readAsStringSync(), 'moved before the crash');
      expect(File('${target.path}/wallet.keys').readAsStringSync(), 'not yet moved');
      expect(docs.listSync(), isEmpty);
    });

    test('never overwrites an entry that was already moved', () async {
      final staging = Directory('${target.path}.migrating')..createSync(recursive: true);
      File('${staging.path}/wallet').writeAsStringSync('moved');
      File('${docs.path}/wallet').writeAsStringSync('stray');

      await moveIntoAppDir(from: docs, to: target);

      expect(File('${target.path}/wallet').readAsStringSync(), 'moved');
      expect(File('${docs.path}/wallet').readAsStringSync(), 'stray');
    });

    test('a fresh install gets an empty directory', () async {
      await moveIntoAppDir(from: Directory('${tmp.path}/no_documents'), to: target);
      expect(target.existsSync(), isTrue);
      expect(target.listSync(), isEmpty);
    });

    test('two runs at once both end with every file in place exactly once', () async {
      for (var i = 0; i < 50; i++) {
        File('${docs.path}/f$i').writeAsStringSync('$i');
      }

      await Future.wait([
        moveIntoAppDir(from: docs, to: target),
        moveIntoAppDir(from: docs, to: target),
      ]);

      for (var i = 0; i < 50; i++) {
        expect(File('${target.path}/f$i').readAsStringSync(), '$i');
      }
      expect(docs.listSync(), isEmpty);
      expect(Directory('${target.path}.migrating').existsSync(), isFalse);
    });
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

  @override
  Future<Directory> applicationSupport() async =>
      throw StateError('applicationSupport() must not be called on desktop');
}
