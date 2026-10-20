import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_backup/wallet_backup.dart';
import 'package:wallet_backup_platform/backup_ui.dart';
import 'package:wallet_backup_platform/wallet_backup_platform.dart' show ICloudLocation;
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// "Import wallet data?" after a restore, against real services over an
/// in-memory iCloud: the backup is turned on only when an import succeeds.

const raven =
    'raven tail swear infant grief assist regular lamp duck valid someone little harsh puppy '
    'airport language';
const abandon =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

/// One install: its own files and address book, sharing [cloud].
class Install {
  Install(this.root, MemoryLocation cloud, {FolderLocation? onDevice}) {
    service = MetadataBackupService(
      localRoot: () async => Directory('${root.path}/local'),
      locations: [
        BackupLocationConfig(location: cloud),
        if (onDevice != null) BackupLocationConfig(location: onDevice, onDevice: true),
      ],
      paymentUploadDelay: Duration.zero,
      observeLifecycle: false,
      readContacts: () async => contacts,
      applyContactChanges: (changes) async => contacts = applyContactChanges(contacts, changes),
    );
  }

  final Directory root;
  late final MetadataBackupService service;
  List<String> contacts = [];

  List<String> get names => [
    for (final c in contacts) Contact.fromJson(json.decode(c) as Map<String, dynamic>).name,
  ];
}

/// An iCloud stand-in that counts every look, to show when none happens.
class CountingLocation extends MemoryLocation {
  CountingLocation() : super(ICloudLocation.locationId);

  int looks = 0;

  @override
  Future<bool> isAvailable() {
    looks++;
    return super.isAvailable();
  }

  @override
  Future<List<String>> list(String folder) {
    looks++;
    return super.list(folder);
  }
}

/// True when [dir] is missing or empty: nothing kept on this device.
Future<bool> isEmptyDir(Directory dir) async => !await dir.exists() || await dir.list().isEmpty;

void main() {
  late Directory tmp;
  late MemoryLocation cloud;

  setUp(() async {
    SharedPreferencesService.store = MemoryPreferenceStore();
    tmp = await Directory.systemTemp.createTemp('import_wallet_data_test');
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    cloud = MemoryLocation(ICloudLocation.locationId);
  });

  tearDown(() async => tmp.delete(recursive: true));

  /// An earlier install that backed up one contact to iCloud. Returns its
  /// backup file. Leaves the switches off again, as on a new phone.
  Future<Uint8List> earlierInstall(SeedSource seed) async {
    final a = Install(Directory('${tmp.path}/old'), cloud)
      ..contacts = [json.encode(const Contact(id: 'c1', name: 'Alice', addresses: {}).toJson())];
    await a.service.open(seed, wallets: const []);
    await a.service.setEnabled(true, locations: [ICloudLocation.locationId]);
    final bundle = await a.service.exportBundle();
    await a.service.close();
    SharedPreferencesService.store = MemoryPreferenceStore();
    return bundle;
  }

  /// The phone being restored. Built in real time (runAsync): the service's
  /// futures must not belong to the test's fake-time zone, or its file work
  /// would wait on frames that never come.
  Future<Install> restoredInstall(WidgetTester tester, {FolderLocation? onDevice}) async {
    return (await tester.runAsync(() async {
      final b = Install(Directory('${tmp.path}/new'), cloud, onDevice: onDevice);
      await b.service.open(const PolyseedSeed(raven), wallets: const [], restored: true);
      return b;
    }))!;
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    Install b, {
    Future<Uint8List?> Function()? pickFile,
  }) async {
    tester.view.physicalSize = const Size(1600, 2600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: BackupLocalizations.localizationsDelegates,
        supportedLocales: BackupLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ImportWalletDataScreen(service: b.service, pickFile: pickFile),
                  ),
                ),
                child: const Text('home'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('home'));
    await tester.pumpAndSettle();
    expect(find.text('Import wallet data'), findsOneWidget);
  }

  /// Lets real file and storage work run between frames until [done].
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(done(), isTrue, reason: 'timed out');
    await tester.pump();
  }

  bool shows(String text) => find.textContaining(text).evaluate().isNotEmpty;

  testWidgets('from iCloud with a backup there: imports, and only then turns backup on', (
    tester,
  ) async {
    await tester.runAsync(() => earlierInstall(const PolyseedSeed(raven)));
    final b = await restoredInstall(tester);
    await pumpScreen(tester, b);

    await tester.tap(find.text('From iCloud'));
    await settle(tester, () => shows('Wallet data imported'));

    expect(shows('Restored 0 payments and 1 contact'), isTrue);
    expect(shows('Backup to iCloud is on'), isTrue);
    expect(b.names, ['Alice']);
    expect(b.service.enabled, isTrue);
    expect(await tester.runAsync(() => b.service.isLocationEnabled('icloud')), isTrue);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    await tester.runAsync(b.service.close);
  });

  testWidgets('nothing in iCloud: a pop-up, OK, the same screen, and nothing turned on', (
    tester,
  ) async {
    final b = await restoredInstall(tester);
    await pumpScreen(tester, b);

    await tester.tap(find.text('From iCloud'));
    await settle(tester, () => shows('No backup found'));
    expect(find.text('No backup found'), findsOneWidget);
    expect(find.text('No backup of this wallet in iCloud.'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('No backup found'), findsNothing);
    expect(find.text('From iCloud'), findsOneWidget);

    expect(b.service.enabled, isFalse);
    expect(await tester.runAsync(() => b.service.isLocationEnabled('icloud')), isFalse);
    expect(cloud.folders, isEmpty, reason: 'nothing uploaded');
    expect(await tester.runAsync(() => Directory('${tmp.path}/new').exists()), isFalse);
    await tester.runAsync(b.service.close);
  });

  testWidgets('iCloud unreachable: the pop-up says so and nothing is turned on', (tester) async {
    final b = await restoredInstall(tester);
    cloud.available = false;
    await pumpScreen(tester, b);

    await tester.tap(find.text('From iCloud'));
    await settle(tester, () => shows("Couldn't reach iCloud"));
    expect(find.textContaining("Couldn't reach iCloud"), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(b.service.enabled, isFalse);
    await tester.runAsync(b.service.close);
  });

  testWidgets('from backup file: imports with backup on and every location off', (tester) async {
    final bundle = (await tester.runAsync(() => earlierInstall(const PolyseedSeed(raven))))!;
    final filesBefore = cloud.folders.values.single.length;
    final b = await restoredInstall(tester);
    await pumpScreen(tester, b, pickFile: () async => bundle);

    await tester.tap(find.text('From a backup file'));
    await settle(tester, () => shows('Wallet data imported'));

    expect(shows('Automatic backups are off'), isTrue);
    expect(b.names, ['Alice']);
    expect(b.service.enabled, isTrue);
    expect(await tester.runAsync(() => b.service.isLocationEnabled('icloud')), isFalse);
    expect(cloud.folders.values.single, hasLength(filesBefore), reason: 'nothing uploaded');
    await tester.runAsync(b.service.close);
  });

  testWidgets('a backup file of another wallet: an error, and backup stays off', (tester) async {
    final other = (await tester.runAsync(() => earlierInstall(const Bip39Seed(abandon))))!;
    final b = await restoredInstall(tester);
    await pumpScreen(tester, b, pickFile: () async => other);

    await tester.tap(find.text('From a backup file'));
    await settle(tester, () => shows("That file isn't a backup of this wallet"));

    expect(find.text('From a backup file'), findsOneWidget);
    expect(b.service.enabled, isFalse);
    expect(await tester.runAsync(() => isEmptyDir(Directory('${tmp.path}/new/local'))), isTrue);
    await tester.runAsync(b.service.close);
  });

  testWidgets('a backup file of another wallet leaves the copy Android restored', (tester) async {
    final other = (await tester.runAsync(() => earlierInstall(const Bip39Seed(abandon))))!;
    final auto = FolderLocation('auto', () async => Directory('${tmp.path}/new/auto'));
    final b = await restoredInstall(tester, onDevice: auto);
    final restored = File('${tmp.path}/new/auto/${b.service.folderName}/restored');
    await tester.runAsync(() async {
      await restored.create(recursive: true);
      await restored.writeAsBytes([1]);
    });
    await pumpScreen(tester, b, pickFile: () async => other);

    await tester.tap(find.text('From a backup file'));
    await settle(tester, () => shows("That file isn't a backup of this wallet"));

    expect(b.service.enabled, isFalse);
    expect(await tester.runAsync(restored.exists), isTrue);
    await tester.runAsync(b.service.close);
  });

  testWidgets('a cancelled file pick changes nothing', (tester) async {
    final b = await restoredInstall(tester);
    await pumpScreen(tester, b, pickFile: () async => null);
    await tester.tap(find.text('From a backup file'));
    await tester.pumpAndSettle();
    expect(find.text('From a backup file'), findsOneWidget);
    expect(b.service.enabled, isFalse);
    await tester.runAsync(b.service.close);
  });

  testWidgets('No: closes and leaves the backup off', (tester) async {
    final b = await restoredInstall(tester);
    await pumpScreen(tester, b);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(b.service.enabled, isFalse);
    await tester.runAsync(b.service.close);
  });

  group('after a restore (scheduleImportWalletData)', () {
    Future<Install> opened(WidgetTester tester, MemoryLocation location, SeedSource seed) async =>
        (await tester.runAsync(() async {
          final b = Install(Directory('${tmp.path}/new'), location);
          await b.service.open(seed, wallets: const [], restored: true);
          return b;
        }))!;

    Future<void> restoreAndSchedule(WidgetTester tester, MetadataBackupService service) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: BackupLocalizations.localizationsDelegates,
          supportedLocales: BackupLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => scheduleImportWalletData(context, service: service),
                child: const Text('restored'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('restored'));
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    testWidgets('a legacy 25-word seed: no screen, and no location is looked at', (tester) async {
      final icloud = CountingLocation();
      final b = await opened(tester, icloud, MoneroLegacySeed(List.filled(25, 'abbey').join(' ')));
      await restoreAndSchedule(tester, b.service);

      expect(b.service.availability, BackupAvailability.legacySeed);
      expect(find.byType(ImportWalletDataScreen), findsNothing);
      expect(icloud.looks, 0);
      expect(b.service.enabled, isFalse);
      await tester.runAsync(b.service.close);
    });

    testWidgets('a polyseed: the screen, and nothing looked at until the user picks', (
      tester,
    ) async {
      final icloud = CountingLocation();
      final b = await opened(tester, icloud, const PolyseedSeed(raven));
      await restoreAndSchedule(tester, b.service);

      expect(find.byType(ImportWalletDataScreen), findsOneWidget);
      expect(icloud.looks, 0);
      await tester.runAsync(b.service.close);
    });
  });
}
