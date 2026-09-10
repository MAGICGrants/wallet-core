import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

void main() {
  late MemoryPreferenceStore store;
  final settings = TorSettingsService.sharedInstance;

  setUp(() {
    store = MemoryPreferenceStore();
    SharedPreferencesService.store = store;
    settings.resetForTesting();
  });

  tearDown(() {
    SharedPreferencesService.resetForTesting();
    settings.resetForTesting();
  });

  group('mode encoding', () {
    test('round-trips every mode', () {
      for (final mode in TorMode.values) {
        expect(
          TorSettingsService.torModeFromString(TorSettingsService.torModeToString(mode)),
          mode,
        );
      }
    });

    test('an unknown value falls back to builtIn, never to disabled', () {
      // A corrupt or future preference must not silently turn Tor off.
      for (final junk in ['', 'BUILTIN', 'off', 'nonsense', 'Disabled']) {
        expect(TorSettingsService.torModeFromString(junk), TorMode.builtIn, reason: junk);
      }
    });

    test('the persisted strings are the ones the apps already wrote', () {
      // Renaming any of these resets the setting for every existing user.
      expect(TorSettingsService.torModeToString(TorMode.builtIn), 'builtIn');
      expect(TorSettingsService.torModeToString(TorMode.external), 'external');
      expect(TorSettingsService.torModeToString(TorMode.disabled), 'disabled');
      expect(InfraPreferenceKeys.torMode, 'torMode');
      expect(InfraPreferenceKeys.torSocksPort, 'torSocksPort');
      expect(InfraPreferenceKeys.torUseOrbot, 'torUseOrbot');
      expect(InfraPreferenceKeys.verboseLoggingEnabled, 'verboseLoggingEnabled');
    });
  });

  group('load and save', () {
    test('defaults when nothing is persisted', () async {
      await settings.loadSettings();
      expect(settings.torMode, TorMode.builtIn);
      expect(settings.socksPort, '9050');
      expect(settings.useOrbot, isFalse);
    });

    test('save then load round-trips', () async {
      await settings.save(torMode: TorMode.external, socksPort: '9150', useOrbot: true);
      settings.resetForTesting();
      await settings.loadSettings();

      expect(settings.torMode, TorMode.external);
      expect(settings.socksPort, '9150');
      expect(settings.useOrbot, isTrue);
    });

    test('omitted fields are left untouched', () async {
      await settings.save(torMode: TorMode.builtIn, socksPort: '9150', useOrbot: true);
      await settings.save(torMode: TorMode.disabled);

      expect(settings.torMode, TorMode.disabled);
      expect(settings.socksPort, '9150');
      expect(settings.useOrbot, isTrue);
      expect(store.values[InfraPreferenceKeys.torSocksPort], '9150');
    });

    test('a partially written preference set still loads', () async {
      store.values[InfraPreferenceKeys.torMode] = 'external';
      await settings.loadSettings();
      expect(settings.torMode, TorMode.external);
      expect(settings.socksPort, '9050');
    });
  });

  group('getProxy', () {
    test('disabled yields no proxy', () async {
      await settings.save(torMode: TorMode.disabled);
      expect(await settings.getProxy(), isNull);
    });

    test('external points at loopback on the configured port', () async {
      await settings.save(torMode: TorMode.external, socksPort: '9150');
      final proxy = await settings.getProxy();
      expect(proxy, isNotNull);
      expect(proxy!.port, 9150);
      expect(proxy.host.address, '127.0.0.1');
    });

    test('a non-numeric external port throws rather than connecting to 0', () async {
      await settings.save(torMode: TorMode.external, socksPort: 'not-a-port');
      expect(settings.getProxy(), throwsFormatException);
    });
  });
}
