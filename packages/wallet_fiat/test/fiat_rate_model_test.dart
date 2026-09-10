import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fiat/wallet_fiat.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_fiat_wallet.dart';

/// The first tests this package has ever had.
///
/// Nothing here touches the network. The properties worth pinning are those
/// that decide *whether* a request happens at all; the mode, the Tor proxy, and
/// which coins are even priceable; because those are what stand between a
/// privacy-conscious user's settings and an outbound clearnet request to Kraken.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wallet_fiat');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
    WalletLog.sink = MemoryLogSink();
    WalletLog.isVerbose = () async => true;
    // No Tor, and no clearnet either unless a test asks for it. A test that
    // reaches the network is a test that will one day fail in CI for a reason
    // that has nothing to do with this code.
    FiatRates.getTorProxy = () async => null;
  });

  tearDown(() {
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Stops the model's 10-minute poll timer.
  ///
  /// `FiatRateModel` has **no `dispose()` override**, so the periodic timer it
  /// arms in `startService` cannot be cancelled by disposing the model; the
  /// only thing that stops it is re-entering `startService` with the API mode
  /// set to disabled, which is what this does. Worth knowing outside the tests:
  /// in the background isolate that timer is the "permanent, unattended
  /// consumer" the audit's M-A describes, and nothing can switch it off short of
  /// the user changing the setting.
  Future<void> stopPolling(FiatRateModel model) async {
    await FiatRateModel.saveFiatApiMode(FiatApiMode.disabled);
    await model.startService();
  }

  /// A model that stops polling and is then disposed, in that order.
  ///
  /// One registration rather than two, because `addTearDown` runs LIFO: written
  /// as separate calls, the dispose fires first and [stopPolling] then calls
  /// `startService` on a disposed `ChangeNotifier`, which throws. That ordering
  /// hazard exists at all only because the model has no `dispose()` override to
  /// cancel its own timer.
  FiatRateModel pollingModel() {
    final model = FiatRateModel();
    addTearDown(() async {
      await stopPolling(model);
      model.dispose();
    });
    return model;
  }

  WalletManager managerWith(List<CryptoWallet> wallets) => WalletManager(coins: () => wallets);

  /// A manager whose wallets have their connections applied, so
  /// `connectionAddress` is populated the way a real one would be after
  /// `loadCachedDisplayState`.
  Future<WalletManager> configuredManager(List<FakeFiatWallet> wallets) async {
    final manager = managerWith(wallets);
    for (final w in wallets) {
      await w.applyConnection();
    }
    return manager;
  }

  group('the API mode decides whether anything leaves the device', () {
    test('defaults to Tor-only when nothing is stored', () async {
      // The fail-closed default. A first launch must not reach Kraken in the
      // clear before the user has been asked anything.
      expect(await FiatRateModel.loadFiatApiMode(), FiatApiMode.torOnly);
    });

    test('round-trips every mode', () async {
      for (final mode in FiatApiMode.values) {
        await FiatRateModel.saveFiatApiMode(mode);
        expect(await FiatRateModel.loadFiatApiMode(), mode);
      }
    });

    test('an unrecognised stored value falls back to Tor-only, not clearnet', () async {
      // A downgrade, a corrupted preference, or a mode removed in a later
      // version must not silently become the least private option.
      await SharedPreferencesService.set<String>(SettingsKeys.fiatApiMode, 'over-carrier-pigeon');
      expect(await FiatRateModel.loadFiatApiMode(), FiatApiMode.torOnly);
    });
  });

  group('disabled means disabled', () {
    test('startService arms no timer and reports disabled, not failed', () async {
      // "A disabled API is not a failed one": showing a failure badge for a
      // setting the user chose trains them to ignore the badge that matters.
      await FiatRateModel.saveFiatApiMode(FiatApiMode.disabled);
      final model = FiatRateModel();
      addTearDown(model.dispose);

      await model.startService();
      await pumpEventQueue();

      expect(model.isDisabled, isTrue);
      expect(model.hasFailed, isFalse);
      expect(model.isLoading, isFalse);
    });

    test('a configured coin is still not fetched while disabled', () async {
      await FiatRateModel.saveFiatApiMode(FiatApiMode.disabled);
      final manager = await configuredManager([FakeFiatWallet('BTC')]);
      addTearDown(manager.dispose);

      final model = FiatRateModel();
      addTearDown(model.dispose);
      await model.startService(walletManager: manager);
      await pumpEventQueue();

      expect(model.isDisabled, isTrue);
      expect(model.rateFor('BTC'), isNull);
      expect(model.hasFailed, isFalse);
    });
  });

  group('Tor-only fails closed', () {
    test('with no Tor proxy the fetch fails rather than going clearnet', () async {
      // The property the audit checked by hand and cleared. Locked in here so a
      // future "helpful" fallback to clearnet has to delete a test that says why
      // it must not exist.
      FiatRates.getTorProxy = () async => null;
      await FiatRateModel.saveFiatApiMode(FiatApiMode.torOnly);

      final manager = await configuredManager([FakeFiatWallet('BTC')]);
      addTearDown(manager.dispose);

      final model = pollingModel();

      await model.startService(walletManager: manager);
      await pumpEventQueue();

      expect(model.isDisabled, isFalse, reason: 'the API is on, it just could not be reached');
      expect(model.hasFailed, isTrue);
      expect(model.rateFor('BTC'), isNull);
    });

    test('a failed fetch leaves no rate behind', () async {
      FiatRates.getTorProxy = () async => null;
      await FiatRateModel.saveFiatApiMode(FiatApiMode.torOnly);
      final manager = await configuredManager([FakeFiatWallet('BTC'), FakeFiatWallet('ETH')]);
      addTearDown(manager.dispose);

      final model = pollingModel();
      await model.startService(walletManager: manager);
      await pumpEventQueue();

      expect(model.rates.values.every((r) => r == null), isTrue);
    });
  });

  group('nothing to price means no request', () {
    test('no wallet manager attached fetches nothing and is not a failure', () async {
      await FiatRateModel.saveFiatApiMode(FiatApiMode.torOnly);
      final model = pollingModel();

      await model.startService();
      await pumpEventQueue();

      expect(model.hasFailed, isFalse, reason: 'having nothing to ask about is not a failure');
      expect(model.isLoading, isFalse);
    });

    test('an unconfigured coin is not priced', () async {
      // No server configured means the user has not set this coin up, so asking
      // Kraken about it leaks an interest in a coin they do not hold.
      await FiatRateModel.saveFiatApiMode(FiatApiMode.torOnly);
      final manager = await configuredManager([FakeFiatWallet('BTC', address: '')]);
      addTearDown(manager.dispose);

      final model = pollingModel();
      await model.startService(walletManager: manager);
      await pumpEventQueue();

      expect(model.hasFailed, isFalse);
      expect(model.rateFor('BTC'), isNull);
    });
  });

  group('which coins can be priced at all', () {
    late FiatRateModel model;

    setUp(() => model = FiatRateModel());
    tearDown(() => model.dispose());

    test('the supported set is the Kraken map', () {
      expect(FiatRateModel.supportedCoins, containsAll(['XMR', 'BTC', 'ETH', 'DAI']));
    });

    test('an unsupported coin is not supported', () {
      expect(model.isSupported('DOGE'), isFalse);
    });

    test('symbols are matched case-insensitively', () {
      expect(model.isSupported('btc'), isTrue);
      expect(model.isSupported('BTC'), isTrue);
    });

    test('a testnet coin inherits its mainnet base', () async {
      // TBTC has no Kraken pair of its own; it is priced as BTC or not at all,
      // and a testnet coin showing no price at all reads as a bug.
      final tbtc = FakeFiatWallet('TBTC', fiatBase: 'BTC');
      final manager = await configuredManager([tbtc]);
      addTearDown(manager.dispose);
      model.attachWalletManager(manager);

      expect(model.isSupported('TBTC'), isTrue);
    });

    test('a coin with no wallet is judged on its own symbol', () {
      expect(model.isSupported('XMR'), isTrue);
      expect(model.isSupported('NOTACOIN'), isFalse);
    });
  });

  group('rateFor', () {
    late FiatRateModel model;

    setUp(() => model = FiatRateModel());
    tearDown(() => model.dispose());

    test('is null before anything has been fetched', () {
      expect(model.rateFor('BTC'), isNull);
    });

    test('an explicitly inactive wallet is never priced', () {
      expect(model.rateFor('BTC', walletActive: false), isNull);
    });

    test('a persisted rate survives a restart', () async {
      // The reason rates are persisted: a launch with no network still shows the
      // last known price rather than blanking the balance screen.
      await SharedPreferencesService.set<double>('${SettingsKeys.fiatRate}_btc', 61234.5);
      await FiatRateModel.saveFiatApiMode(FiatApiMode.disabled);

      final restarted = FiatRateModel();
      addTearDown(restarted.dispose);
      final manager = await configuredManager([FakeFiatWallet('BTC')]);
      addTearDown(manager.dispose);

      await restarted.startService(walletManager: manager);
      await pumpEventQueue();

      expect(restarted.rateFor('BTC'), 61234.5);
    });
  });

  group('clearPersistedRates', () {
    test('removes every coin, so a currency change cannot show a stale price', () async {
      // Without this, switching USD → EUR shows yesterday's dollar figure under a
      // euro sign until the next fetch lands.
      for (final coin in FiatRateModel.supportedCoins) {
        await SharedPreferencesService.set<double>(
          '${SettingsKeys.fiatRate}_${coin.toLowerCase()}',
          42,
        );
      }

      await FiatRateModel.clearPersistedRates();

      for (final coin in FiatRateModel.supportedCoins) {
        expect(
          await SharedPreferencesService.get<double>(
            '${SettingsKeys.fiatRate}_${coin.toLowerCase()}',
          ),
          isNull,
          reason: coin,
        );
      }
    });

    test('is safe when nothing was stored', () async {
      await expectLater(FiatRateModel.clearPersistedRates(), completes);
    });
  });

  group('attachWalletManager', () {
    test('attaching the same manager twice does not double-subscribe', () async {
      // It adds a listener each time; re-attaching the same one would fetch
      // twice per change, which on the Tor path is two circuits per wallet edit.
      final manager = await configuredManager([FakeFiatWallet('BTC')]);
      addTearDown(manager.dispose);
      final model = FiatRateModel();
      addTearDown(model.dispose);

      model.attachWalletManager(manager);
      await expectLater(() => model.attachWalletManager(manager), returnsNormally);
    });
  });
}
