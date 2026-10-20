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

  test('desktop derives the app dir from the environment, not from path_provider', () async {
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
    // The real folder now exists (and on Linux carries the backup markers).
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    expect(dir.path, isNot(tmp.path));
    expect(dir.path, contains(Platform.isLinux ? 'test_wallet' : 'Test Wallet'));
    if (Platform.isWindows) expect(dir.path, endsWith(iosAppDirName));
  }, skip: (Platform.isLinux || Platform.isWindows) ? false : 'desktop-only path');

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

  // On a macOS host this runs the real CoreFoundation calls (Time Machine's
  // exclusion is the same flag); elsewhere it is a no-op.
  test('excludeFromDeviceBackup sets the flag on Apple platforms only', () {
    expect(excludeFromDeviceBackup(tmp.path), Platform.isIOS || Platform.isMacOS);
  });

  // With no injected root, macOS takes its own branch: an excluded directory
  // under Application Support, and nothing moved out of Documents, which
  // outside the sandbox is the user's own folder.
  test('macOS keeps the app dir under Application Support, out of Time Machine', () async {
    final support = Directory('${tmp.path}/Support')..createSync();
    final docs = Directory('${tmp.path}/Documents')..createSync();
    File('${docs.path}/mine').writeAsStringSync('mine');
    WalletPaths.install(
      linuxDirName: '.test_wallet',
      windowsAppDataDir: 'MAGIC Grants/Test Wallet',
      directories: _NoRoot(support: support, documents: docs),
    );

    final dir = await getAppDir();
    expect(dir.path, '${support.path}/$iosAppDirName');
    expect(dir.existsSync(), isTrue);
    expect(File('${docs.path}/mine').readAsStringSync(), 'mine');
    // Reads the flag getAppDir set, through the system's own tool.
    final excluded = Process.runSync('tmutil', ['isexcluded', dir.path]);
    expect(excluded.stdout as String, contains('[Excluded]'));
  }, skip: Platform.isMacOS ? false : 'macOS-only branch');

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

  // Windows: the wallet's files leave the Roaming folder, which a roaming
  // profile copies to a server, for one under %LOCALAPPDATA% that stays on the
  // computer. The settings and secure-storage plugins keep their files where
  // path_provider points them, in Roaming.
  group('prepareWindowsAppDir', () {
    late Directory roaming;
    late Directory local;

    setUp(() {
      roaming = Directory('${tmp.path}/Roaming/MAGIC Grants/Test Wallet')
        ..createSync(recursive: true);
      local = Directory('${tmp.path}/Local/MAGIC Grants/Test Wallet/$iosAppDirName');
    });

    test('moves the wallet files and leaves the plugins\' files', () async {
      for (final name in [
        'wallet.key',
        'wallet.fhse',
        'master_seed',
        'shared_preferences.json',
        'flutter_secure_storage.dat',
      ]) {
        File('${roaming.path}/$name').writeAsStringSync(name);
      }
      Directory('${roaming.path}/logs').createSync();

      final dir = await prepareWindowsAppDir(roaming: roaming, local: local);

      expect(dir.path, local.path);
      for (final name in ['wallet.key', 'wallet.fhse', 'master_seed']) {
        expect(File('${local.path}/$name').readAsStringSync(), name);
      }
      expect(Directory('${local.path}/logs').existsSync(), isTrue);
      expect(roaming.listSync().map((e) => e.uri.pathSegments.last).toSet(), {
        'shared_preferences.json',
        'flutter_secure_storage.dat',
      });
    });

    test('a fresh install, or one with only plugin files, starts in Local', () async {
      File('${roaming.path}/shared_preferences.json').writeAsStringSync('{}');
      final dir = await prepareWindowsAppDir(roaming: roaming, local: local);
      expect(dir.path, local.path);
      expect(local.existsSync(), isTrue);
      expect(local.listSync(), isEmpty);
    });

    test('once moved, Roaming is not looked at again', () async {
      local.createSync(recursive: true);
      File('${roaming.path}/wallet.key').writeAsStringSync('copied back by hand');
      final dir = await prepareWindowsAppDir(roaming: roaming, local: local);
      expect(dir.path, local.path);
      expect(File('${roaming.path}/wallet.key').existsSync(), isTrue);
    });

    test('picks up a move a crash cut short', () async {
      final staging = Directory('${local.path}.migrating')..createSync(recursive: true);
      File('${staging.path}/wallet.key').writeAsStringSync('moved before the crash');
      File('${roaming.path}/master_seed').writeAsStringSync('not yet moved');

      final dir = await prepareWindowsAppDir(roaming: roaming, local: local);

      expect(dir.path, local.path);
      expect(File('${local.path}/wallet.key').readAsStringSync(), 'moved before the crash');
      expect(File('${local.path}/master_seed').readAsStringSync(), 'not yet moved');
    });

    test('Roaming on another volume (a redirected share): left where it is', () async {
      File('${roaming.path}/wallet.key').writeAsStringSync('key');
      final dir = await prepareWindowsAppDir(
        roaming: roaming,
        local: local,
        sameVolume: (_, _) => false,
      );
      expect(dir.path, roaming.path);
      expect(File('${roaming.path}/wallet.key').existsSync(), isTrue);
      expect(local.existsSync(), isFalse);
    });
  });

  // Linux: no flag like Apple's, so the folder carries the markers backup tools
  // look for.
  group('markExcludedFromLinuxBackups', () {
    test('writes a CACHEDIR.TAG and a .deja-dup-ignore', () async {
      expect(await markExcludedFromLinuxBackups(tmp), isTrue);
      expect(
        File('${tmp.path}/CACHEDIR.TAG').readAsStringSync(),
        startsWith('Signature: 8a477f597d28d172789f06886806bc55\n'),
      );
      expect(File('${tmp.path}/.deja-dup-ignore').existsSync(), isTrue);
    });

    test('repairs a tag without the signature, and leaves a good one alone', () async {
      final tag = File('${tmp.path}/CACHEDIR.TAG')..writeAsStringSync('not a tag');
      await markExcludedFromLinuxBackups(tmp);
      expect(tag.readAsStringSync(), startsWith('Signature: 8a477f597d28d172789f06886806bc55'));

      tag.writeAsStringSync('Signature: 8a477f597d28d172789f06886806bc55\n# edited\n');
      await markExcludedFromLinuxBackups(tmp);
      expect(tag.readAsStringSync(), endsWith('# edited\n'));
    });

    test('a folder that cannot be written to reports it', () async {
      expect(await markExcludedFromLinuxBackups(Directory('${tmp.path}/missing')), isFalse);
    });
  });
}

/// Names no app root, so [getAppDir] makes its own platform decision.
class _NoRoot extends DirectoryProvider {
  const _NoRoot({required this.support, required this.documents});

  final Directory support;
  final Directory documents;

  @override
  Future<Directory> applicationDocuments() async => documents;

  @override
  Future<Directory> applicationSupport() async => support;

  @override
  Future<Directory?> externalStorage() async => null;
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
