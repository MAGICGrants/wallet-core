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

/// A keystore that refuses every write, as macOS does a release build that is
/// not team-signed.
class _RefusingSecretStore extends MemorySecretStore {
  @override
  Future<void> write(String key, String value) async => throw StateError('keystore refused');
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
    // App Lock is always on: the old on/off switch no longer decides anything.
    test('with a wallet present, drops the password and arms', () async {
      installSkylight();
      WalletSecrets.holdsWalletPassword = true;
      final m = manager([FakeWallet('XMR')..existing = true])..useGeneratedPassword();
      expect(m.hasPassword, isTrue);

      expect(await m.armAppLockRelock(), isTrue);
      expect(m.hasPassword, isFalse, reason: 'a resumed app must not decrypt anything');
    });

    test('an old "App Lock off" changes nothing: it still locks', () async {
      installSkylight();
      WalletSecrets.holdsWalletPassword = true;
      await SharedPreferencesService.set<bool>(DomainPreferenceKeys.legacyAppLockEnabled, false);
      final m = manager([FakeWallet('XMR')..existing = true])..useGeneratedPassword();

      expect(await m.armAppLockRelock(), isTrue);
      expect(m.hasPassword, isFalse);
    });

    test('no wallet yet: onboarding is never interrupted by a lock screen', () async {
      installSkylight();
      final m = manager([FakeWallet('XMR')..existing = false])..useGeneratedPassword();

      expect(await m.armAppLockRelock(), isFalse);
      expect(m.hasPassword, isTrue, reason: 'a half-created wallet must stay usable');
    });

    test('Linux and Windows keep the typed password: it cannot be read back', () async {
      installSpice();
      WalletSecrets.holdsWalletPassword = false;
      final m = manager([FakeWallet('BTC')..existing = true])..setWalletPassword('typed');

      expect(await m.armAppLockRelock(), isTrue);
      expect(m.hasPassword, isTrue, reason: 'App Lock checks it again, the wallet stays open');
    });
  });

  group('unlockWithRecoveryPhrase: App Lock without the device', () {
    const otherBip39 =
        'legal winner thank year wave sausage worth useful legal winner thank yellow';

    Future<WalletManager> restored() async {
      installSpice();
      WalletSecrets.holdsWalletPassword = true;
      final m = manager([FakeWallet('BTC')])..useGeneratedPassword();
      await m.restoreAll(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
      );
      return m;
    }

    test('the right phrase brings the password back from the keystore', () async {
      final m = await restored();
      final password = m.passwordForGuard;
      m.clearPassword();

      expect(await m.unlockWithRecoveryPhrase(_bip39), isTrue);
      expect(m.passwordForGuard, password);
      m.dispose();
    });

    test('spacing and case do not matter', () async {
      final m = await restored();
      m.clearPassword();

      expect(
        await m.unlockWithRecoveryPhrase('  ${_bip39.toUpperCase().replaceAll(' ', '  ')}\n'),
        isTrue,
      );
      m.dispose();
    });

    test('another wallet\'s phrase, or no phrase, loads nothing', () async {
      final m = await restored();
      m.clearPassword();

      expect(await m.unlockWithRecoveryPhrase(otherBip39), isFalse);
      expect(await m.unlockWithRecoveryPhrase('not a phrase'), isFalse);
      expect(await m.unlockWithRecoveryPhrase(''), isFalse);
      expect(m.hasPassword, isFalse, reason: 'a wrong phrase must not load the keystore copy');
      m.dispose();
    });

    test('with the password still in memory it is checked against it', () async {
      final m = await restored();
      expect(await m.unlockWithRecoveryPhrase(otherBip39), isFalse);
      expect(m.hasPassword, isTrue);
      expect(await m.unlockWithRecoveryPhrase(_bip39), isTrue);
      m.dispose();
    });

    test('Linux and Windows have no keystore copy: nothing to open with', () async {
      installSpice();
      WalletSecrets.holdsWalletPassword = false;
      final m = manager([FakeWallet('BTC')])..setWalletPassword('typed');
      await m.restoreAll(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
      );
      m.clearPassword();

      expect(await m.unlockWithRecoveryPhrase(_bip39), isFalse);
      m.dispose();
    });
  });

  test('a launch decrypts nothing before App Lock, even with a keystore copy', () async {
    installSkylight();
    WalletSecrets.holdsWalletPassword = true;
    await storeKeystoreWalletPassword('kept');
    await SharedPreferencesService.set<bool>(DomainPreferenceKeys.legacyAppLockEnabled, false);
    final m = manager([FakeWallet('XMR', existing: true)]);

    await m.loadCachedDisplayState();
    expect(m.hasPassword, isFalse, reason: 'the unlock screen loads it');
    m.dispose();
  });

  // The spend wallet locked: the password and every spending key leave memory.
  // A coin that can keep watching does, view-only; any other closes.
  group('the spend wallet locks and unlocks', () {
    Future<WalletManager> openWith(List<_LockableWallet> coins) async {
      installSkylight();
      WalletSecrets.holdsWalletPassword = true;
      final m = manager(coins)..setWalletPassword('pw');
      addTearDown(m.dispose);
      await m.openAll();
      AppSession.markUnlocked();
      return m;
    }

    test('lockSpend: password gone, watchers view-only, the rest closed', () async {
      final watcher = _LockableWallet('BTC');
      final closer = _LockableWallet('XMR', keeps: false);
      final m = await openWith([watcher, closer]);

      await m.lockSpend();
      expect(AppSession.isUnlocked, isFalse);
      expect(m.hasPassword, isFalse);
      expect((watcher.isViewOnly, watcher.isLoaded), (true, true));
      expect((closer.isViewOnly, closer.isLoaded), (false, false));
      expect(m.isSpendLocked, isTrue);
    });

    test('unlockSpend: watchers take their keys back, closed ones open again', () async {
      final watcher = _LockableWallet('BTC');
      final closer = _LockableWallet('XMR', keeps: false);
      final m = await openWith([watcher, closer]);
      await m.lockSpend();
      final opensBefore = closer.openCount;

      m.setWalletPassword('pw');
      await m.unlockSpend();
      expect(watcher.events, ['enter', 'leave pw']);
      expect(watcher.isViewOnly, isFalse);
      expect(closer.isLoaded, isTrue);
      expect(closer.openCount, opensBefore + 1);
      expect(m.isSpendLocked, isFalse);
    });

    test('a watcher that cannot take its keys back is closed and opened again', () async {
      final watcher = _LockableWallet('BTC')..leaveSucceeds = false;
      final m = await openWith([watcher]);
      await m.lockSpend();
      final opensBefore = watcher.openCount;

      m.setWalletPassword('pw');
      await m.unlockSpend();
      expect(watcher.isViewOnly, isFalse);
      expect(watcher.isLoaded, isTrue);
      expect(watcher.openCount, opensBefore + 1);
    });

    test('no password, no unlock', () async {
      final watcher = _LockableWallet('BTC');
      final m = await openWith([watcher]);
      await m.lockSpend();
      await m.unlockSpend();
      expect(watcher.isViewOnly, isTrue);
    });

    test('App Lock locks the spend wallet with security keys off', () async {
      final watcher = _LockableWallet('BTC');
      final m = await openWith([watcher]);
      expect(await m.armAppLockRelock(), isTrue);
      expect(watcher.isViewOnly, isTrue);
      expect(m.hasPassword, isFalse);
    });

    test('Linux and Windows: App Lock keeps the wallet open, keys and all', () async {
      final watcher = _LockableWallet('BTC');
      installSpice();
      WalletSecrets.holdsWalletPassword = false;
      final m = manager([watcher])..setWalletPassword('typed');
      addTearDown(m.dispose);
      await m.openAll();

      expect(await m.armAppLockRelock(), isTrue);
      expect(watcher.isViewOnly, isFalse);
      expect(watcher.isLoaded, isTrue);
      expect(m.hasPassword, isTrue);
    });
  });

  // On Android the Continuous Sync service may hold view-only copies of the
  // same files; the app asks it to let go before opening its own.
  group('claimWalletFiles', () {
    tearDown(() => WalletManager.claimWalletFiles = null);

    test('is asked before every open with the password', () async {
      installSkylight();
      final w = FakeWallet('BTC', existing: true);
      var claims = 0;
      WalletManager.claimWalletFiles = () async {
        expect(w.openCount, 0, reason: 'nothing opens before the claim');
        claims++;
      };
      final m = manager([w])..setWalletPassword('pw');
      addTearDown(m.dispose);
      await m.openAll();
      expect((claims, w.openCount), (1, 1));
    });

    test('never in an unattended run, which is the other holder', () async {
      installSkylight();
      var claims = 0;
      WalletManager.claimWalletFiles = () async => claims++;
      final m = manager([FakeWallet('BTC', existing: true)..markUnattended()]);
      addTearDown(m.dispose);
      await m.openAll();
      expect(claims, 0);
    });

    test('a claim that fails does not stop the open', () async {
      installSkylight();
      final w = FakeWallet('BTC', existing: true);
      WalletManager.claimWalletFiles = () async => throw StateError('no service');
      final m = manager([w])..setWalletPassword('pw');
      addTearDown(m.dispose);
      await m.openAll();
      expect(w.openCount, 1);
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

    test('a keystore that refuses the password stops it before any file is written', () async {
      installSpice();
      WalletSecrets.holdsWalletPassword = true;
      WalletSecrets.store = _RefusingSecretStore();
      final btc = FakeWallet('BTC');
      final m = manager([btc])..useGeneratedPassword();

      await expectLater(
        m.restoreAll(seed: const Bip39Seed(_bip39), from: RestorePoint.date(DateTime.utc(2026))),
        throwsStateError,
      );

      // Nothing is encrypted under a password no one holds.
      expect(btc.restores, isEmpty);
      expect(await SeedStore.exists(), isFalse);
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

    test('a fresh seed starts at a zero balance; a restored one at none', () async {
      // Monero's node mode loads no stats until the first scan finishes, so a
      // new wallet with no balance sat on a skeleton (fiat with it) for the
      // whole scan. A seed generated this session has received nothing.
      installSpice();
      final fresh = FakeWallet('BTC')..deferStats = true;
      final m = manager([fresh])..setWalletPassword('pw');
      await m.restoreAll(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
        freshSeed: true,
      );
      expect(fresh.unlockedBalanceBaseUnits, BigInt.zero);
      expect(fresh.totalBalanceBaseUnits, BigInt.zero);
      m.dispose();

      // A typed seed may hold funds the scan has not reached; zero would lie.
      final restored = FakeWallet('BTC')..deferStats = true;
      final m2 = manager([restored])..setWalletPassword('pw');
      await m2.restoreAll(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
      );
      expect(restored.unlockedBalanceBaseUnits, isNull);
      expect(restored.totalBalanceBaseUnits, isNull);
      m2.dispose();
    });

    test('a fresh seed leaves skipped coins without a balance', () async {
      installSkylight();
      final xmr = FakeWallet('XMR', seedFormats: {SeedFormat.polyseed, SeedFormat.bip39});
      final btc = FakeWallet('BTC');
      final m = manager([xmr, btc])..setWalletPassword('pw');
      await m.restoreAll(
        seed: const PolyseedSeed('sixteen words here'),
        from: RestorePoint.date(DateTime.utc(2026)),
        freshSeed: true,
      );
      expect(xmr.unlockedBalanceBaseUnits, BigInt.zero);
      expect(btc.unlockedBalanceBaseUnits, isNull, reason: 'BTC was never created');
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

  group('the typed desktop password stays out of the keystore', () {
    // `holdsWalletPassword` is pinned in each test: the default follows the
    // host, which may be a Mac (holds it) or Linux (does not).
    Future<void> restoreWith(WalletManager m) =>
        m.restoreAll(seed: const Bip39Seed(_bip39), from: RestorePoint.date(DateTime.utc(2026)));

    test('restoring writes no copy of it', () async {
      installSpice();
      WalletSecrets.holdsWalletPassword = false;
      final m = manager([FakeWallet('BTC')])..setWalletPassword('typed');

      await restoreWith(m);

      expect(secrets.values.containsKey(walletPasswordStorageKey), isFalse);
      m.dispose();
    });

    test('a copy an earlier build stored is never loaded', () async {
      installSpice();
      WalletSecrets.holdsWalletPassword = false;
      await storeKeystoreWalletPassword('typed');
      final btc = FakeWallet('BTC', existing: true);
      final m = manager([btc]);

      await m.loadCachedDisplayState();
      expect(m.hasPassword, isFalse, reason: 'nothing may decrypt before the unlock');
      await m.openAll();
      expect(btc.openCount, 0);
      expect(await m.loadStoredPassword(), isFalse);
      m.dispose();
    });

    test('unlocking checks it against the stored seed', () async {
      installSpice();
      WalletSecrets.holdsWalletPassword = false;
      final m = manager([FakeWallet('BTC')])..setWalletPassword('typed');
      await restoreWith(m);
      m.clearPassword();

      expect(await m.unlockWithTypedPassword('wrong'), isFalse);
      expect(m.hasPassword, isFalse);
      expect(await m.unlockWithTypedPassword('typed'), isTrue);
      expect(m.hasPassword, isTrue);
      m.dispose();
    });

    test('the first right unlock deletes a copy an earlier build stored', () async {
      installSpice();
      WalletSecrets.holdsWalletPassword = false;
      final m = manager([FakeWallet('BTC')])..setWalletPassword('typed');
      await restoreWith(m);
      m.clearPassword();
      await storeKeystoreWalletPassword('typed');

      await m.unlockWithTypedPassword('wrong');
      expect(secrets.values[walletPasswordStorageKey], 'typed', reason: 'kept until proven');
      await m.unlockWithTypedPassword('typed');
      expect(secrets.values.containsKey(walletPasswordStorageKey), isFalse);
      m.dispose();
    });

    test('a wallet with no seed store unlocks as before, its open being the check', () async {
      installSkylight();
      WalletSecrets.holdsWalletPassword = false;
      final m = manager([FakeWallet('XMR', existing: true)]);

      expect(await m.unlockWithTypedPassword('typed'), isTrue);
      m.dispose();
    });

    test('restoring with a generated password is refused', () async {
      installSpice();
      WalletSecrets.holdsWalletPassword = false;
      final btc = FakeWallet('BTC');
      final m = manager([btc])..useGeneratedPassword();

      await expectLater(restoreWith(m), throwsStateError);
      expect(btc.restores, isEmpty, reason: 'nobody could open a wallet encrypted with it');
      expect(await SeedStore.exists(), isFalse);
      m.dispose();
    });

    test('mobile still keeps its generated password in the keystore', () async {
      installSpice();
      WalletSecrets.holdsWalletPassword = true;
      final m = manager([FakeWallet('BTC')])..useGeneratedPassword();

      await restoreWith(m);

      expect(secrets.values[walletPasswordStorageKey], isNotNull);
      final fresh = manager([FakeWallet('BTC', existing: true)]);
      expect(await fresh.loadStoredPassword(), isTrue);
      m.dispose();
      fresh.dispose();
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
      // Background isolates run only on mobile, the platforms that keep the
      // password in the keystore.
      WalletSecrets.holdsWalletPassword = true;
      await storeKeystoreWalletPassword('kept-in-the-keystore');
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

  group('AppSession: the one "past every lock" flag', () {
    setUp(AppSession.resetForTesting);
    tearDown(AppSession.resetForTesting);

    test('finishing onboarding unlocks it', () async {
      installSpice();
      final m = manager([FakeWallet('BTC')])..setWalletPassword('pw');
      expect(AppSession.isUnlocked, isFalse);

      await m.restoreAll(
        seed: const Bip39Seed(_bip39),
        from: RestorePoint.date(DateTime.utc(2026)),
      );
      expect(AppSession.isUnlocked, isTrue);
      m.dispose();
    });

    test('an App Lock relock locks it; with no wallet yet it stays as it was', () async {
      installSkylight();
      final none = manager([FakeWallet('XMR')..existing = false])..useGeneratedPassword();
      AppSession.markUnlocked();
      expect(await none.armAppLockRelock(), isFalse);
      expect(AppSession.isUnlocked, isTrue);

      final m = manager([FakeWallet('XMR')..existing = true])..useGeneratedPassword();
      expect(await m.armAppLockRelock(), isTrue);
      expect(AppSession.isUnlocked, isFalse);
    });

    test('a full lock and deleting the wallet lock it', () async {
      installSpice();
      final m = manager([FakeWallet('BTC')..existing = true])..setWalletPassword('pw');
      AppSession.markUnlocked();
      await m.fullyLock();
      expect(AppSession.isUnlocked, isFalse);

      AppSession.markUnlocked();
      await m.deleteAll();
      expect(AppSession.isUnlocked, isFalse);
      m.dispose();
    });
  });
}

/// A coin that can stay open view-only when the spend wallet locks, or not.
class _LockableWallet extends FakeWallet {
  _LockableWallet(super.symbol, {this.keeps = true}) : super(existing: true);

  final bool keeps;
  bool leaveSucceeds = true;
  final events = <String>[];

  @override
  Future<bool> enterViewOnlyMode() async {
    events.add('enter');
    return keeps;
  }

  @override
  Future<bool> leaveViewOnlyMode(String password) async {
    events.add('leave $password');
    return leaveSucceeds;
  }
}
