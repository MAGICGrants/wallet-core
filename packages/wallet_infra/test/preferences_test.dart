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

  test('verbose logging can be wired to preferences', () async {
    // The concrete reason this boundary is injectable: log() consults the
    // user's verbose setting on every info record, so a plugin-backed store
    // would make every logging test need a device.
    await SharedPreferencesService.set<bool>('verboseLoggingEnabled', true);
    WalletLog.isVerbose = () async =>
        await SharedPreferencesService.get<bool>('verboseLoggingEnabled') ?? false;
    final sink = MemoryLogSink();
    WalletLog.sink = sink;

    await log(LogLevel.info, 'visible');
    expect(sink.records, hasLength(1));

    await SharedPreferencesService.set<bool>('verboseLoggingEnabled', false);
    await log(LogLevel.info, 'hidden');
    expect(sink.records, hasLength(1));

    WalletLog.resetForTesting();
  });
}
