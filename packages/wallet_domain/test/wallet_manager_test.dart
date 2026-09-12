import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

const _bip39 =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon address';

/// Records the password the manager threads through, so the delegation and the
/// "no password ⇒ no-op" guard can be asserted without a full open.
class _RecordingWallet extends FakeWallet {
  _RecordingWallet(super.symbol);

  int applyCalls = 0;
  String? appliedPassword;

  @override
  Future<void> applyConnectionChange({required String password}) async {
    applyCalls++;
    appliedPassword = password;
  }

  int backgroundSyncCalls = 0;
  String? backgroundSyncPassword;

  /// When set, the call throws; one coin failing to configure background sync
  /// must not stop the others.
  Object? backgroundSyncError;

  @override
  Future<void> applyBackgroundSyncSetting({required String password}) async {
    backgroundSyncCalls++;
    backgroundSyncPassword = password;
    final err = backgroundSyncError;
    if (err != null) throw err;
  }
}

void main() {
  late Directory tmp;
  late MemoryPreferenceStore prefs;
  late MemorySecretStore secrets;

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wallet_manager');
    prefs = MemoryPreferenceStore();
    SharedPreferencesService.store = prefs;
    secrets = MemorySecretStore();
    WalletSecrets.store = secrets;
  });

  tearDown(() {
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void installSpice() =>
      WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
  void installSkylight() =>
      WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));

  WalletManager manager(List<CryptoWallet> coins) => WalletManager(coins: () => coins);

  group('armAppLockRelock', () {
    Future<void> setAppLock(bool on) =>
        SharedPreferencesService.set<bool>(DomainPreferenceKeys.appLockEnabled, on);

    test('with the lock on and a wallet present, drops the password and arms', () async {
      installSkylight();
      await setAppLock(true);
      final m = manager([FakeWallet('XMR')..existing = true])..useGeneratedPassword();
      expect(m.hasPassword, isTrue);

      expect(await m.armAppLockRelock(), isTrue);
      expect(m.hasPassword, isFalse, reason: 'a resumed app must not decrypt anything');
    });

    test('with the lock off, the password survives backgrounding', () async {
      installSkylight();
      await setAppLock(false);
      final m = manager([FakeWallet('XMR')..existing = true])..useGeneratedPassword();

      expect(await m.armAppLockRelock(), isFalse);
      expect(m.hasPassword, isTrue);
    });

    test('no wallet yet: onboarding is never interrupted by a lock screen', () async {
      installSkylight();
      await setAppLock(true);
      final m = manager([FakeWallet('XMR')..existing = false])..useGeneratedPassword();

      expect(await m.armAppLockRelock(), isFalse);
      expect(m.hasPassword, isTrue, reason: 'a half-created wallet must stay usable');
    });

    test('unset preference is treated as off', () async {
      installSpice();
      final m = manager([FakeWallet('XMR')..existing = true])..useGeneratedPassword();

      expect(await m.armAppLockRelock(), isFalse);
      expect(m.hasPassword, isTrue);
    });
  });

  group('coin registry is app-supplied', () {
    test('registers exactly what the app passes', () {
      installSpice();
      final m = manager([FakeWallet('BTC'), FakeWallet('XMR')]);
      expect(m.allWallets.map((w) => w.coinSymbol), unorderedEquals(['BTC', 'XMR']));
      expect(m.getWallet('btc'), isNotNull, reason: 'lookup is case-insensitive');
      expect(m.getWallet('ETH'), isNull);
      m.dispose();
    });

    test('a single-coin app registers one wallet and nothing else', () {
      installSkylight();
      final m = manager([FakeWallet('XMR')]);
      expect(m.allWallets, hasLength(1));
      m.dispose();
    });
  });

  group('testnet visibility', () {
    test('testnet coins are hidden until enabled', () async {
      installSpice();
      final m = manager([FakeWallet('BTC'), FakeWallet('TBTC', testnet: true)]);
      await m.loadPreferences();

      expect(m.allWallets.map((w) => w.coinSymbol), ['BTC']);
      expect(m.getWallet('TBTC'), isNull);

      await m.setTestnetCoinsEnabled(true);
      expect(m.allWallets.map((w) => w.coinSymbol), unorderedEquals(['BTC', 'TBTC']));
      m.dispose();
    });

    test('the setting persists', () async {
      installSpice();
      final m = manager([FakeWallet('TBTC', testnet: true)]);
      await m.setTestnetCoinsEnabled(true);
      expect(prefs.values[DomainPreferenceKeys.testnetCoinsEnabled], isTrue);
      m.dispose();
    });
  });

  group('generateSeed follows the app policy', () {
    test('Spice generates a 15-word BIP39 seed', () {
      installSpice();
      final m = manager([FakeWallet('BTC')]);
      final generated = m.generateSeed();
      expect(generated.seed, isA<Bip39Seed>());
      expect(generated.seed.mnemonic.split(' '), hasLength(15));
      m.dispose();
    });

    test('Skylight generates a 16-word polyseed', () {
      installSkylight();
      final m = manager([
        FakeWallet('XMR', seedFormats: {SeedFormat.polyseed}),
      ]);
      final generated = m.generateSeed();
      expect(generated.seed, isA<PolyseedSeed>());
      expect(generated.seed.mnemonic.split(' '), hasLength(16));
      m.dispose();
    });

    test('a generated seed classifies back to the same format', () {
      // Closes the loop with SeedSource.detect; a generated seed must be
      // recognised by the same code that reads a typed one.
      for (final install in [installSpice, installSkylight]) {
        install();
        final m = manager([FakeWallet('XMR', seedFormats: SeedFormat.values.toSet())]);
        final generated = m.generateSeed();
        expect(SeedSource.detect(generated.seed.mnemonic)?.format, generated.seed.format);
        m.dispose();
        WalletAppConfig.resetForTesting();
      }
    });
  });

  group('restoreAll', () {
    test('requires a password', () async {
      installSpice();
      final m = manager([FakeWallet('BTC')]);
      expect(
        m.restoreAll(seed: const Bip39Seed(_bip39), from: RestorePoint.date(DateTime.utc(2026))),
        throwsStateError,
      );
      m.dispose();
    });

    test('restores every coin that supports the format', () async {
      installSpice();
      final btc = FakeWallet('BTC');
      final eth = FakeWallet('ETH');
      final m = manager([btc, eth])..setWalletPassword('pw');

      await m.restoreAll(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
      );

      expect(btc.restores, hasLength(1));
      expect(eth.restores, hasLength(1));
      m.dispose();
    });

    test('skips coins that cannot derive from the seed rather than failing', () async {
      // A polyseed restore in a multicoin wallet must not blow up on Bitcoin.
      installSkylight();
      final xmr = FakeWallet('XMR', seedFormats: {SeedFormat.polyseed, SeedFormat.bip39});
      final btc = FakeWallet('BTC');
      final m = manager([xmr, btc])..setWalletPassword('pw');

      await m.restoreAll(
        seed: const PolyseedSeed('sixteen words here'),
        from: RestorePoint.date(DateTime.utc(2026)),
      );

      expect(xmr.restores, hasLength(1));
      expect(btc.restores, isEmpty, reason: 'BTC cannot derive from a polyseed');
      m.dispose();
    });

    test('rejects a format the app policy forbids', () async {
      installSpice();
      final m = manager([FakeWallet('BTC')])..setWalletPassword('pw');
      expect(
        m.restoreAll(
          seed: const PolyseedSeed('sixteen words here'),
          from: RestorePoint.date(DateTime.utc(2026)),
        ),
        throwsA(isA<UnsupportedSeedFormatException>()),
      );
      m.dispose();
    });
  });

  group('the seed store persists the original mnemonic on restore', () {
    test('Spice persists the seed so later coins can bootstrap', () async {
      installSpice();
      final m = manager([FakeWallet('BTC')])..setWalletPassword('pw');
      await m.restoreAll(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
      );
      expect(await SeedStore.exists(), isTrue);
      m.dispose();
    });

    test('Skylight persists too — to show a bip39 restore back verbatim', () async {
      installSkylight();
      final m = manager([
        FakeWallet('XMR', seedFormats: {SeedFormat.bip39}),
      ])..setWalletPassword('pw');
      await m.restoreAll(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
      );
      // The native wallet only yields the derived legacy seed, so the original
      // bip39 is kept to display it back on the reveal screen.
      expect(await SeedStore.exists(), isTrue);
      m.dispose();
    });
  });

  group('open orchestration', () {
    test('opens a coin that already has a wallet file', () async {
      installSpice();
      final btc = FakeWallet('BTC', existing: true);
      final m = manager([btc])..setWalletPassword('pw');
      await m.openAll();
      expect(btc.openCount, 1);
      expect(btc.restores, isEmpty);
      m.dispose();
    });

    test('bootstraps a coin with no file from the stored seed', () async {
      installSpice();
      final btc = FakeWallet('BTC', existing: true);
      final m = manager([btc])..setWalletPassword('pw');
      await m.restoreAll(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
      );

      // A coin added in a later release: no file, but the stored seed can
      // bootstrap it without re-prompting the user.
      final eth = FakeWallet('ETH');
      final m2 = manager([eth])..setWalletPassword('pw');
      await m2.openAll();

      expect(eth.restores, hasLength(1));
      m.dispose();
      m2.dispose();
    });

    test('a corrupt wallet file is removed and re-bootstrapped', () async {
      installSpice();
      final btc = FakeWallet('BTC', existing: true);
      final m = manager([btc])..setWalletPassword('pw');
      await m.restoreAll(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
      );

      // Simulate the next open finding an unreadable wallet file. One manager
      // throughout: a CryptoWallet belongs to exactly one manager, and
      // disposing two that share an instance disposes it twice.
      btc.openError = const FormatException('Wallet blob magic mismatch');
      btc.restores.clear();
      await m.openAll();

      expect(btc.deleteFileCount, 1);
      expect(btc.restores, hasLength(1), reason: 're-bootstrapped from the stored seed');
      m.dispose();
    });

    test('one coin failing to open does not stop the others', () async {
      installSpice();
      final bad = FakeWallet('BTC', existing: true)..openError = StateError('boom');
      final good = FakeWallet('ETH', existing: true);
      final m = manager([bad, good])..setWalletPassword('pw');

      await m.openAll();

      expect(good.openCount, 1);
      m.dispose();
    });
  });

  test('pauseSyncAndStoreAll checkpoints every open wallet', () async {
    installSpice();
    final a = FakeWallet('BTC', existing: true);
    final b = FakeWallet('ETH', existing: true);
    final m = manager([a, b])..setWalletPassword('pw');
    await m.openAll();

    await m.pauseSyncAndStoreAll();

    expect(a.pauseStored, isTrue);
    expect(b.pauseStored, isTrue);
    m.dispose();
  });

  test('deleteAll clears wallets, the stored seed and the given app keys', () async {
    installSpice();
    final btc = FakeWallet('BTC');
    final m = manager([btc])..setWalletPassword('pw');
    await m.restoreAll(seed: const Bip39Seed(_bip39), from: RestorePoint.date(DateTime.utc(2026)));
    prefs.values['contacts'] = 'something';

    await m.deleteAll(extraPrefKeys: ['contacts']);

    expect(await SeedStore.exists(), isFalse);
    expect(m.hasPassword, isFalse);
    expect(prefs.values.containsKey('contacts'), isFalse);
    expect(
      secrets.values.containsKey(walletPasswordStorageKey),
      isFalse,
      reason: 'the stored password must not survive a wallet delete',
    );
    m.dispose();
  });

  group('explorer connection', () {
    test('is off by default — an LWS or Electrum server serves its own history', () async {
      installSpice();
      final w = FakeWallet('BTC');
      final m = manager([w]);
      expect(w.supportsExplorerUrl, isFalse);
      expect(w.explorerAddressExample, isEmpty);
      // Probing a coin with no explorer is a programming error, not a runtime
      // condition to handle.
      expect(w.testExplorerConnection(address: 'x', useTor: false), throwsUnimplementedError);
      m.dispose();
    });

    test('round-trips independently of the node connection', () async {
      installSpice();
      final w = FakeExplorerWallet('ETH');
      final m = manager([w]);

      w.setConnection(address: 'rpc.example.com', proxyPort: '', useTor: false, connectionType: '');
      w.setExplorerConnection(address: 'explorer.example.com', proxyPort: '9050', useTor: true);
      await w.persistCurrentConnection();
      await w.persistExplorerConnection();

      final fresh = FakeExplorerWallet('ETH');
      final m2 = manager([fresh]);
      await fresh.loadPersistedConnection();

      expect(fresh.connectionAddress, 'rpc.example.com');
      expect(fresh.explorerAddress, 'explorer.example.com');
      expect(fresh.explorerProxyPort, '9050');
      expect(fresh.explorerUseTor, isTrue);

      m.dispose();
      m2.dispose();
    });

    test('the explorer probe is overridable and does not touch live state', () async {
      installSpice();
      final w = FakeExplorerWallet('ETH');
      final m = manager([w]);
      await w.testExplorerConnection(address: 'probe.example.com', useTor: false);

      expect(w.probed, ['probe.example.com']);
      expect(w.explorerAddress, isEmpty, reason: 'a probe must not mutate state');
      m.dispose();
    });
  });

  test('totalUnlockedFiat skips testnet coins and missing rates', () async {
    installSpice();
    final m = manager([FakeWallet('BTC'), FakeWallet('TBTC', testnet: true)]);
    await m.setTestnetCoinsEnabled(true);
    // No balances loaded, so the total is zero rather than a crash.
    expect(m.totalUnlockedFiat({'BTC': 50000}), 0);
    m.dispose();
  });

  group('applyConnectionChange', () {
    test('delegates to the coin with the manager-held password', () async {
      installSkylight();
      final xmr = _RecordingWallet('XMR');
      final m = manager([xmr])..setWalletPassword('pw');

      await m.applyConnectionChange('XMR');

      expect(xmr.applyCalls, 1);
      expect(xmr.appliedPassword, 'pw');
      m.dispose();
    });

    test('is a no-op when no password is available', () async {
      installSkylight();
      final xmr = _RecordingWallet('XMR');
      // No password set and none stored, so the change cannot proceed.
      final m = manager([xmr]);

      await m.applyConnectionChange('XMR');

      expect(xmr.applyCalls, 0);
      m.dispose();
    });
  });

  group('applyBackgroundSyncSettingAll', () {
    /// The manager only reaches *open* wallets, because the configuration is
    /// written into the wallet file and needs a native handle.
    Future<_RecordingWallet> openWallet(String symbol) async {
      final w = _RecordingWallet(symbol);
      await w.openExisting(password: 'pw');
      return w;
    }

    test('fans out to every open wallet with the manager-held password', () async {
      installSpice();
      final xmr = await openWallet('XMR');
      final btc = await openWallet('BTC');
      final m = manager([xmr, btc])..setWalletPassword('pw');

      await m.applyBackgroundSyncSettingAll();

      // Reaching every coin matters even though only Monero does anything with
      // it: the base's no-op is what lets the manager stay coin-agnostic.
      expect(xmr.backgroundSyncCalls, 1);
      expect(btc.backgroundSyncCalls, 1);
      expect(xmr.backgroundSyncPassword, 'pw');
      m.dispose();
    });

    test('falls back to the stored password, as a background isolate must', () async {
      installSkylight();
      await storeMobileWalletPassword('kept-in-the-keystore');
      final xmr = await openWallet('XMR');
      final m = manager([xmr]);

      await m.applyBackgroundSyncSettingAll();

      expect(xmr.backgroundSyncPassword, 'kept-in-the-keystore');
      m.dispose();
    });

    test('is a no-op when no password is available at all', () async {
      installSkylight();
      final xmr = await openWallet('XMR');
      final m = manager([xmr]);

      await m.applyBackgroundSyncSettingAll();

      expect(xmr.backgroundSyncCalls, 0);
      m.dispose();
    });

    test('an unopened wallet is skipped rather than failing', () async {
      installSkylight();
      // Never opened: there is no native handle to configure, and the setting
      // will be applied by the open path when it does get one.
      // Not `addTearDown(xmr.dispose)`: the manager takes ownership of what it
      // is given and disposes it, and double-dispose is an error.
      final xmr = _RecordingWallet('XMR');
      final m = manager([xmr])..setWalletPassword('pw');

      await m.applyBackgroundSyncSettingAll();

      expect(xmr.backgroundSyncCalls, 0);
      m.dispose();
    });

    test('one coin that throws does not stop the others', () async {
      installSpice();
      final xmr = await openWallet('XMR');
      xmr.backgroundSyncError = Exception('keys file busy');
      final btc = await openWallet('BTC');
      final m = manager([xmr, btc])..setWalletPassword('pw');

      // A wallet that cannot configure background sync still syncs in the
      // foreground; it does not take the settings screen down with it.
      await expectLater(m.applyBackgroundSyncSettingAll(), completes);

      expect(btc.backgroundSyncCalls, 1);
      m.dispose();
    });
  });
}
