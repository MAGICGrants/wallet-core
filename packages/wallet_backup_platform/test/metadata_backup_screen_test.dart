import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_backup/wallet_backup.dart' show MetadataBackupService;
import 'package:wallet_backup_platform/backup_ui.dart';
import 'package:wallet_backup_platform/wallet_backup_platform.dart';
import 'package:wallet_ui/wallet_ui.dart' show BrandButton, BrandSwitch;
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Settings > Backup, with the real service (no platform locations on the
/// test host): the manual backup file, and what is kept on this device.

const raven =
    'raven tail swear infant grief assist regular lamp duck valid someone little harsh puppy '
    'airport language';

void main() {
  late Directory tmp;

  setUp(() async {
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    tmp = await Directory.systemTemp.createTemp('metadata_backup_screen_test');
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
  });

  tearDown(() async {
    MetadataBackupSetup.resetForTesting();
    WalletSecrets.resetForTesting();
    await tmp.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  late MetadataBackupService service;
  final i18n = lookupBackupLocalizations(const Locale('en'));

  /// The copy on this device (`MetadataBackupSetup`'s local root).
  Directory localCopy() => Directory('${tmp.path}/metadata_backup_local');
  Future<bool> isEmptyDir(Directory dir) async => !await dir.exists() || await dir.list().isEmpty;

  /// Built and opened outside the fake clock, as the app does at unlock.
  Future<void> openScreen(
    WidgetTester tester, {
    Future<bool> Function()? exportFile,
    Future<Uint8List?> Function()? pickFile,
    bool enabledBefore = false,
  }) async {
    service = (await tester.runAsync(() async {
      final service = MetadataBackupSetup.install(
        const MetadataBackupConfig(
          appName: 'Skylight',
          iCloudContainer: 'iCloud.org.magicgrants.test',
          exportFileStem: 'skylight-backup',
        ),
      );
      await service.open(const PolyseedSeed(raven), wallets: const []);
      if (enabledBefore) await service.setEnabled(true);
      return service;
    }))!;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: BackupLocalizations.localizationsDelegates,
        supportedLocales: BackupLocalizations.supportedLocales,
        home: MetadataBackupScreen(exportFile: exportFile, pickFile: pickFile),
      ),
    );
    await settle(tester);
  }

  /// Settles until the screen is idle again: its buttons are disabled while a
  /// save, import or delete is under way.
  Future<void> waitIdle(WidgetTester tester) async {
    bool idle() =>
        tester.widget<BrandButton>(find.widgetWithText(BrandButton, i18n.backupExport)).onPressed !=
        null;
    for (var i = 0; i < 40; i++) {
      await settle(tester);
      if (idle()) return;
    }
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await waitIdle(tester);
  }

  testWidgets('nothing on: the places, the file, the reminders, and nothing kept', (tester) async {
    await openScreen(tester);

    expect(service.enabled, isFalse);
    expect(find.textContaining(i18n.backupSeedWarningBold, findRichText: true), findsOneWidget);
    expect(find.text(i18n.backupSecurityNote), findsOneWidget);
    expect(find.text(i18n.backupLws), findsOneWidget);
    expect(find.text(i18n.backupComingSoon), findsOneWidget);
    expect(find.text(i18n.backupExport), findsOneWidget);
    expect(find.text(i18n.backupImport), findsOneWidget);

    await tester.runAsync(service.close);
  });

  testWidgets('Android: a copy put back while it is off stays until deleted from its card', (
    tester,
  ) async {
    MetadataBackupSetup.androidForTesting = true;
    await openScreen(tester);
    expect(find.text(i18n.backupAndroid), findsOneWidget);
    expect(find.text(i18n.backupDeleteAndroid), findsNothing, reason: 'nothing there yet');

    // Android restored the app's files, this wallet's backup among them.
    final restored = File('${tmp.path}/metadata_backup/${service.folderName}/restored');
    await tester.runAsync(() async {
      await restored.create(recursive: true);
      await restored.writeAsBytes([1]);
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: BackupLocalizations.localizationsDelegates,
        supportedLocales: BackupLocalizations.supportedLocales,
        home: const MetadataBackupScreen(),
      ),
    );
    await settle(tester);
    expect(service.enabled, isFalse, reason: 'nothing turned on, nothing read');
    expect(find.text(i18n.backupDeleteAndroid), findsOneWidget);

    await tapText(tester, i18n.backupDeleteAndroid);
    await tester.tap(find.text(i18n.backupDeleteConfirm));
    await waitIdle(tester);
    expect(await tester.runAsync(restored.exists), isFalse);
    expect(find.text(i18n.backupDeleteAndroid), findsNothing);
    expect(service.enabled, isFalse);

    await tester.runAsync(service.close);
  });

  testWidgets('Android: saving a file, cancelled or not, leaves the copy it restored', (
    tester,
  ) async {
    MetadataBackupSetup.androidForTesting = true;
    var save = false;
    await openScreen(tester, exportFile: () async => save);
    final restored = File('${tmp.path}/metadata_backup/${service.folderName}/restored');
    await tester.runAsync(() async {
      await restored.create(recursive: true);
      await restored.writeAsBytes([1]);
    });

    await tapText(tester, i18n.backupExport);
    expect(service.enabled, isFalse, reason: 'the cancelled save stopped the copy it started');
    expect(await tester.runAsync(restored.exists), isTrue);

    save = true;
    await tapText(tester, i18n.backupExport);
    expect(service.enabled, isFalse, reason: 'no location on: the saved file is all that is left');
    expect(await tester.runAsync(restored.exists), isTrue, reason: 'Android backup was never on');

    await tester.runAsync(service.close);
  });

  testWidgets('Android: turning it off keeps its files and deletes only the copy here', (
    tester,
  ) async {
    MetadataBackupSetup.androidForTesting = true;
    await openScreen(tester);
    final kept = File('${tmp.path}/metadata_backup/${service.folderName}/kept');
    await tester.runAsync(() async {
      await kept.create(recursive: true);
      await kept.writeAsBytes([1]);
    });

    // On, then off: the only switch on this host is Android's.
    await tester.tap(find.byType(BrandSwitch));
    await waitIdle(tester);
    expect(
      await tester.runAsync(
        () => service.isLocationEnabled(MetadataBackupSetup.autoBackupLocationId),
      ),
      isTrue,
    );
    await tester.tap(find.byType(BrandSwitch));
    await waitIdle(tester);
    expect(
      await tester.runAsync(kept.exists),
      isTrue,
      reason: 'off stops adding, and deletes nothing of Android backup',
    );
    expect(service.enabled, isFalse, reason: 'the last location off: the copy here goes');
    expect(await tester.runAsync(() => isEmptyDir(localCopy())), isTrue);
    expect(find.text(i18n.backupDeleteAndroid), findsOneWidget);

    await tapText(tester, i18n.backupDeleteAndroid);
    await tester.tap(find.text(i18n.backupDeleteConfirm));
    await waitIdle(tester);
    expect(await tester.runAsync(kept.exists), isFalse);

    await tester.runAsync(service.close);
  });

  test('saved files are named to the second, so a later save never suggests replacing one', () {
    MetadataBackupSetup.install(
      const MetadataBackupConfig(
        appName: 'Skylight',
        iCloudContainer: 'iCloud.org.magicgrants.test',
        exportFileStem: 'skylight-backup',
      ),
    );
    expect(
      MetadataBackupSetup.exportFileName(DateTime(2026, 10, 20, 9, 5, 7)),
      'skylight-backup-20261020-090507.bin',
    );
  });

  testWidgets('saving a file uses a copy for that step alone', (tester) async {
    var enabledWhileSaving = false;
    await openScreen(
      tester,
      exportFile: () async {
        enabledWhileSaving = service.enabled;
        return true;
      },
    );

    await tapText(tester, i18n.backupExport);
    expect(enabledWhileSaving, isTrue);
    expect(service.enabled, isFalse, reason: 'the saved file is all that is left');
    expect(await tester.runAsync(() => isEmptyDir(localCopy())), isTrue);
    expect(find.textContaining(i18n.backupSeedWarningBold, findRichText: true), findsOneWidget);
    expect(find.text(i18n.backupSecurityNote), findsOneWidget);

    await tester.runAsync(service.close);
  });

  testWidgets('a cancelled save leaves nothing behind', (tester) async {
    var enabledWhileSaving = false;
    await openScreen(
      tester,
      exportFile: () async {
        enabledWhileSaving = service.enabled;
        return false;
      },
    );
    expect(service.enabled, isFalse);

    await tapText(tester, i18n.backupExport);
    expect(enabledWhileSaving, isTrue);
    expect(service.enabled, isFalse);

    await tester.runAsync(service.close);
  });

  testWidgets('importing a file applies it to the address book and keeps no copy', (tester) async {
    // A file from an earlier install of the same wallet, with one contact.
    final bundle = (await tester.runAsync(() async {
      final earlier = MetadataBackupService(
        localRoot: () async => Directory('${tmp.path}/earlier'),
        observeLifecycle: false,
        readContacts: () async => [
          json.encode(const Contact(id: 'c1', name: 'Alice', addresses: {}).toJson()),
        ],
        applyContactChanges: (_) async {},
      );
      await earlier.open(const PolyseedSeed(raven), wallets: const []);
      await earlier.setEnabled(true);
      final bytes = await earlier.exportBundle();
      await earlier.close();
      SharedPreferencesService.store = MemoryPreferenceStore();
      return bytes;
    }))!;
    await openScreen(tester, pickFile: () async => bundle);
    expect(service.enabled, isFalse);

    await tapText(tester, i18n.backupImport);
    expect(service.enabled, isFalse);
    expect(await tester.runAsync(() => isEmptyDir(localCopy())), isTrue);
    final contacts = (await tester.runAsync(readEncodedContacts))!;
    expect(contacts.map((c) => (json.decode(c) as Map<String, dynamic>)['name']), ['Alice']);

    await tester.runAsync(service.close);
  });

  testWidgets(
    'a copy kept with no location on, as earlier versions did, goes on opening',
    timeout: const Timeout(Duration(seconds: 60)),
    (tester) async {
      await openScreen(tester, enabledBefore: true);
      expect(service.enabled, isFalse);
      expect(await tester.runAsync(() => isEmptyDir(localCopy())), isTrue);

      await tester.runAsync(service.close);
    },
  );
}
