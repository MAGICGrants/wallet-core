import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

void main() {
  late MemoryPreferenceStore store;

  setUp(() {
    store = MemoryPreferenceStore();
    SharedPreferencesService.store = store;
  });

  tearDown(SharedPreferencesService.resetForTesting);

  group('round trip', () {
    test('stores and reads each supported type', () async {
      await SharedPreferencesService.set<bool>('b', true);
      await SharedPreferencesService.set<String>('s', 'x');
      await SharedPreferencesService.set<int>('i', 7);
      await SharedPreferencesService.set<double>('d', 1.5);

      expect(await SharedPreferencesService.get<bool>('b'), isTrue);
      expect(await SharedPreferencesService.get<String>('s'), 'x');
      expect(await SharedPreferencesService.get<int>('i'), 7);
      expect(await SharedPreferencesService.get<double>('d'), 1.5);
    });

    test('remove deletes the key', () async {
      await SharedPreferencesService.set<int>('i', 1);
      await SharedPreferencesService.remove('i');
      expect(await SharedPreferencesService.get<int>('i'), isNull);
    });
  });

  group('typed reads', () {
    test('an absent key is null', () async {
      expect(await SharedPreferencesService.get<int>('nope'), isNull);
    });

    test('reading with the wrong type is null, not a crash', () async {
      await SharedPreferencesService.set<String>('s', 'not an int');
      expect(await SharedPreferencesService.get<int>('s'), isNull);
      expect(await SharedPreferencesService.get<String>('s'), 'not an int');
    });

    test('List<String> round-trips', () async {
      // The inherited implementation switched on the type literal and had no
      // List<String> branch, so it silently returned null for these.
      await SharedPreferencesService.set<List<String>>('l', ['a', 'b']);
      expect(await SharedPreferencesService.get<List<String>>('l'), ['a', 'b']);

      // The shape `shared_preferences` actually returns: it
      // decodes a list off the platform channel untyped and casts inside
      // `getStringList`, so a reader testing `value is List<String>` matched
      // nothing on a device while passing against a fake that kept the type.
      SharedPreferencesService.store = MemoryPreferenceStore()..values['raw'] = <dynamic>['a', 'b'];
      expect(await SharedPreferencesService.get<List<String>>('raw'), ['a', 'b']);

      // A list that is not all strings is still a miss, not a partial read.
      SharedPreferencesService.store = MemoryPreferenceStore()..values['mixed'] = <dynamic>['a', 1];
      expect(await SharedPreferencesService.get<List<String>>('mixed'), isNull);
    });

    test('a false bool is returned, not treated as absent', () async {
      await SharedPreferencesService.set<bool>('b', false);
      expect(await SharedPreferencesService.get<bool>('b'), isFalse);
    });

    test('zero and empty string are returned, not treated as absent', () async {
      await SharedPreferencesService.set<int>('i', 0);
      await SharedPreferencesService.set<String>('s', '');
      expect(await SharedPreferencesService.get<int>('i'), 0);
      expect(await SharedPreferencesService.get<String>('s'), '');
    });
  });

  test('the production store is restored by resetForTesting', () {
    SharedPreferencesService.resetForTesting();
    expect(SharedPreferencesService.store, isA<SharedPreferencesStore>());
  });

  test('the logging setting can be wired to preferences', () async {
    // The concrete reason this boundary is injectable: log() consults the
    // user's logging setting on every info record, so a plugin-backed store
    // would make every logging test need a device.
    await SharedPreferencesService.set<bool>(SettingsKeys.loggingEnabled, true);
    WalletLog.isLoggingOn = () async =>
        await SharedPreferencesService.get<bool>(SettingsKeys.loggingEnabled) ?? false;
    final sink = MemoryLogSink();
    WalletLog.sink = sink;

    await log(LogLevel.info, 'visible');
    expect(sink.records, hasLength(1));

    await SharedPreferencesService.set<bool>(SettingsKeys.loggingEnabled, false);
    await log(LogLevel.info, 'hidden');
    expect(sink.records, hasLength(1));

    WalletLog.resetForTesting();
  });

  group('Sync Frequency', () {
    setUp(() {
      SharedPreferencesService.store = MemoryPreferenceStore();
      syncFrequencyPlatform = 'android';
    });
    tearDown(() {
      SharedPreferencesService.resetForTesting();
      syncFrequencyPlatform = Platform.operatingSystem;
    });

    test('periodic by default, so something runs without the user', () async {
      expect(await loadSyncFrequency(), SyncFrequency.periodic);
      expect(await unattendedRunsEnabled(), isTrue);
    });

    test('off runs nothing; continuous and periodic both run', () async {
      for (final f in SyncFrequency.values) {
        await saveSyncFrequency(f);
        expect(await loadSyncFrequency(), f);
        expect(await unattendedRunsEnabled(), f != SyncFrequency.off, reason: f.name);
      }
    });

    test('iOS offers no Continuous, and a stored one reads as Periodic', () async {
      syncFrequencyPlatform = 'ios';
      expect(SyncFrequency.available, [SyncFrequency.periodic, SyncFrequency.off]);
      await saveSyncFrequency(SyncFrequency.continuous);
      expect(await loadSyncFrequency(), SyncFrequency.periodic);
    });

    test('desktop has no background runs, whatever is stored', () async {
      syncFrequencyPlatform = 'linux';
      await saveSyncFrequency(SyncFrequency.periodic);
      expect(await loadSyncFrequency(), SyncFrequency.off);
      expect(await unattendedRunsEnabled(), isFalse);
    });

    group('migrating the old toggles', () {
      Future<SyncFrequency> migrate(Map<String, bool> old, {bool existingInstall = true}) async {
        for (final e in old.entries) {
          await SharedPreferencesService.set<bool>(e.key, e.value);
        }
        await migrateLegacySyncSettings(existingInstall: existingInstall);
        return loadSyncFrequency();
      }

      test('Continuous Sync on becomes Continuous', () async {
        expect(
          await migrate({'foregroundSyncEnabled': true, 'backgroundSyncEnabled': true}),
          SyncFrequency.continuous,
        );
      });

      test('Background Sync on becomes Periodic', () async {
        expect(await migrate({'backgroundSyncEnabled': true}), SyncFrequency.periodic);
      });

      test('notifications on alone become Periodic', () async {
        expect(await migrate({SettingsKeys.notificationsEnabled: true}), SyncFrequency.periodic);
      });

      test('an existing install with everything off stays off', () async {
        expect(await migrate({'backgroundSyncEnabled': false}), SyncFrequency.off);
        expect(await unattendedRunsEnabled(), isFalse);
      });

      test('a fresh install gets Periodic, and keeps it once it has a wallet', () async {
        expect(await migrate({}, existingInstall: false), SyncFrequency.periodic);
        // The next launch, now with a wallet, must not read as "existing, all off".
        expect(await migrate({}), SyncFrequency.periodic);
      });

      test('a choice already made is never overwritten', () async {
        await saveSyncFrequency(SyncFrequency.off);
        expect(await migrate({'foregroundSyncEnabled': true}), SyncFrequency.off);
      });

      test('the old toggles are removed', () async {
        await migrate({'backgroundSyncEnabled': true, 'foregroundSyncEnabled': true});
        expect(await SharedPreferencesService.get<bool>('backgroundSyncEnabled'), isNull);
        expect(await SharedPreferencesService.get<bool>('foregroundSyncEnabled'), isNull);
      });
    });
  });
}
