import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// Native view-key background sync; the scan/check split, at the layer where
/// the decision is made.
///
/// The property under test is not "which password was passed", but that an
/// unattended run of a Monero node wallet **cannot spend**, because the file it
/// opened has no spend key in it: `setupBackgroundSync(CustomPassword)` writes a
/// second keys file with `forget_spend_key()` applied, and a wallet opened from
/// it reports the null spend key. Passing a different password is the mechanism;
/// this is the guarantee, and the reason the feature exists.
///
/// The other half is the mode split. LWSF hardcodes a `ReusePassword` answer to
/// `getBackgroundSyncType` and implements none of the mechanism, so calling
/// `setupBackgroundSync` in LWS mode would report success while doing nothing;
/// implying a protection that is not there. Several tests here exist only to say
/// that the call is never made in that mode.
///
/// The FFI seam here is `FakeMoneroBackend`. What monero_c actually does with
/// these calls needs a real library via `native.yml`, because every binding but
/// `setupBackgroundSync` is `@Deprecated("TODO")` in `impls/monero.dart`;
/// monero.dart's marker for "generated, never exercised".

const _legacy25 =
    'sequence atlas unveil summon pebbles tuesday beer rudely snake rockets '
    'different fuselage woven tagged bested dented pastry unusual sober '
    'hidden ritual older okay dolphin okay';
const _password = 'the-wallet-password';

void main() {
  late Directory tmp;
  late FakeMoneroBackend backend;
  late MoneroWallet wallet;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('monero_background_sync');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));
    WalletLog.sink = MemoryLogSink();
    backend = FakeMoneroBackend();
    wallet = MoneroWallet(backend: backend);
  });

  tearDown(() {
    wallet.dispose();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void connect(String type) => wallet.setConnection(
    address: type == 'node' ? 'node.example.com:18081' : 'lws.example.com:18090',
    proxyPort: '',
    useTor: false,
    connectionType: type,
  );

  Future<String> pathFor(String type) => wallet.walletPathForType(type);

  Future<void> enableBackgroundSync({bool enabled = true}) =>
      SharedPreferencesService.set<bool>(SettingsKeys.backgroundSyncEnabled, enabled);

  /// Opens the main wallet for [type], as the app does on unlock.
  Future<void> openMain(String type) async {
    connect(type);
    backend.existingWalletPaths.add(await pathFor(type));
    await wallet.openExisting(password: _password);
  }

  /// Fresh wallet object over the same backend and the same files; a second
  /// isolate, which is what a background run actually is.
  MoneroWallet nextRun() {
    final next = MoneroWallet(backend: backend);
    addTearDown(next.dispose);
    return next;
  }

  /// Whatever `setupBackgroundSync` wrote, made real on disk. The fake has no
  /// filesystem, and `_backgroundOpenTarget` checks that the file exists before
  /// trusting the stored password.
  Future<void> materialiseBackgroundFiles() async {
    for (final path in backend.backgroundWalletPaths) {
      await File(path).writeAsString('background cache');
      await File('$path.keys').writeAsString('background keys');
    }
  }

  /// The whole sequence: configure on an ordinary open, then a second wallet
  /// object over the same files that takes the unattended path.
  Future<MoneroWallet> backgroundRun() async {
    await enableBackgroundSync();
    await openMain('node');
    await materialiseBackgroundFiles();

    final run = nextRun();
    run.markUnattended();
    connectOn(run, 'node');
    await run.openExisting(password: _password);
    expect(run.isBackgroundWallet, isTrue, reason: 'the run under test must be view-only');
    return run;
  }

  group('the mode split — a scan is not a check', () {
    test('node mode is a scan, LWS mode is a check', () {
      connect('node');
      expect(wallet.backgroundSyncMode, BackgroundSyncMode.scan);

      connect('lws');
      expect(wallet.backgroundSyncMode, BackgroundSyncMode.check);
    });

    test('an unconfigured wallet has nothing to advance', () {
      expect(wallet.backgroundSyncMode, BackgroundSyncMode.none);
    });

    test('LWS mode never calls setupBackgroundSync, even with the setting on', () async {
      await enableBackgroundSync();
      await openMain('lws');

      // LWSF answers `getBackgroundSyncType` with a hardcoded `ReusePassword`
      // and implements nothing behind it. A call here would report success, do
      // nothing, and leave the UI free to claim a view-only background sync.
      expect(backend.backgroundSyncSetups, isEmpty);
      expect(await WalletSecrets.store.read(wallet.backgroundCachePasswordKey), isNull);
    });
  });

  group('setup, and what it costs', () {
    test('node mode with the setting on writes a custom-password background cache', () async {
      await enableBackgroundSync();
      await openMain('node');

      final setup = backend.backgroundSyncSetups.single;
      expect(setup.type, MoneroBackgroundSyncType.customPassword);
      expect(setup.walletPassword, _password);
      expect(setup.cachePassword, isNotEmpty);
    });

    test('the cache password is its own secret, not the wallet password', () async {
      await enableBackgroundSync();
      await openMain('node');

      final stored = await WalletSecrets.store.read(wallet.backgroundCachePasswordKey);
      // wallet2 throws outright when the two match. More to the point, the whole
      // arrangement is two secrets with two exposure profiles: one readable with
      // nobody present, one gated behind authentication. One secret used for
      // both is the posture this replaces.
      expect(stored, isNotNull);
      expect(stored, isNot(_password));
      expect(stored!.length, 32, reason: '128 bits, hex — genWalletPassword()');
    });

    test('nothing is set up while the user has background sync off', () async {
      await openMain('node');

      // Off by default, and not free: while the type is CustomPassword every
      // store() on the main wallet writes a second full cache as well.
      expect(backend.backgroundSyncSetups, isEmpty);
    });

    test('turning the setting off tears the configuration back down', () async {
      await enableBackgroundSync();
      await openMain('node');
      expect(await WalletSecrets.store.read(wallet.backgroundCachePasswordKey), isNotNull);

      await enableBackgroundSync(enabled: false);
      final second = nextRun();
      connectOn(second, 'node');
      backend.existingWalletPaths.add(await pathFor('node'));
      await second.openExisting(password: _password);

      expect(
        backend.backgroundSyncSetups.last.type,
        MoneroBackgroundSyncType.off,
        reason: 'Off is what makes wallet2 delete the background files',
      );
      // Two secrets, two lifetimes: a password kept for a cache that no longer
      // exists is a live key with nothing to protect.
      expect(await WalletSecrets.store.read(second.backgroundCachePasswordKey), isNull);
    });

    test('flipping the setting on takes effect without a reopen', () async {
      // The gap this hook closes. The setting has two effects and only one is
      // scheduling; the other is written into the wallet file, so nothing would
      // reach an already-open wallet until the next launch, and a wake-up in
      // between would fall back to syncing the real wallet while the UI said
      // background sync was on.
      await openMain('node');
      expect(backend.backgroundSyncSetups, isEmpty);

      await enableBackgroundSync();
      await wallet.applyBackgroundSyncSetting(password: _password);

      expect(backend.backgroundSyncSetups.single.type, MoneroBackgroundSyncType.customPassword);
      expect(await WalletSecrets.store.read(wallet.backgroundCachePasswordKey), isNotNull);
    });

    test('flipping it off takes effect without a reopen either', () async {
      await enableBackgroundSync();
      await openMain('node');
      backend.backgroundSyncSetups.clear();

      await enableBackgroundSync(enabled: false);
      await wallet.applyBackgroundSyncSetting(password: _password);

      expect(backend.backgroundSyncSetups.single.type, MoneroBackgroundSyncType.off);
      expect(await WalletSecrets.store.read(wallet.backgroundCachePasswordKey), isNull);
    });

    test('applying an unchanged setting does nothing at all', () async {
      await enableBackgroundSync();
      await openMain('node');
      backend.backgroundSyncSetups.clear();

      await wallet.applyBackgroundSyncSetting(password: _password);
      await wallet.applyBackgroundSyncSetting(password: _password);

      // Not idempotent in wallet2 for CustomPassword: a repeat call deletes and
      // rewrites both files and resets the cache, discarding what it scanned.
      expect(backend.backgroundSyncSetups, isEmpty);
    });

    test('an unattended run never reconfigures anything', () async {
      final run = await backgroundRun();
      await enableBackgroundSync(enabled: false);
      backend.backgroundSyncSetups.clear();

      await run.applyBackgroundSyncSetting(password: _password);

      // It holds no wallet password worth the name, and
      // `setup_background_sync` refuses to run from an existing background cache.
      expect(backend.backgroundSyncSetups, isEmpty);
    });

    test('an LWS wallet is a no-op, not a teardown', () async {
      // LWSF answers `getBackgroundSyncType` with a hardcoded `ReusePassword`,
      // which is neither `off` nor `customPassword`; so a naive comparison
      // would fire the teardown branch on every call.
      await openMain('lws');
      backend.backgroundSyncTypes[await pathFor('lws')] = MoneroBackgroundSyncType.reusePassword;

      await wallet.applyBackgroundSyncSetting(password: _password);

      expect(backend.backgroundSyncSetups, isEmpty);
    });

    test('setup runs once, not on every open', () async {
      await enableBackgroundSync();
      await openMain('node');
      expect(backend.backgroundSyncSetups, hasLength(1));

      final second = nextRun();
      connectOn(second, 'node');
      backend.existingWalletPaths.add(await pathFor('node'));
      await second.openExisting(password: _password);

      // `setup_background_sync` is not idempotent for CustomPassword: wallet2
      // short-circuits an unchanged call for the other two types and never for
      // this one, so a second call deletes and rewrites both files and resets
      // the background cache; discarding whatever it had scanned.
      expect(backend.backgroundSyncSetups, hasLength(1));
    });
  });

  group('the unattended run', () {
    test('opens the background cache, with the background password', () async {
      await enableBackgroundSync();
      await openMain('node');
      await materialiseBackgroundFiles();
      final cachePassword = await WalletSecrets.store.read(wallet.backgroundCachePasswordKey);
      backend.reset();
      backend.existingWalletPaths.add(await pathFor('node'));
      backend.backgroundWalletPaths.add(MoneroWallet.backgroundPathFor(await pathFor('node')));
      backend.existingWalletPaths.add(MoneroWallet.backgroundPathFor(await pathFor('node')));

      final run = nextRun();
      run.markUnattended();
      connectOn(run, 'node');
      // A background run has no user to ask, so it is handed the wallet password
      // out of the keystore the same way the app is, and must not use it.
      await run.openExisting(password: _password);

      final open = backend.opens.single;
      expect(open.path, endsWith('.background'));
      expect(open.password, cachePassword);
      expect(open.password, isNot(_password));
      expect(run.isBackgroundWallet, isTrue);
    });

    test('holds no spendable key', () async {
      final run = await backgroundRun();

      // Not an inference from which password was passed. A background keys file
      // is written with `forget_spend_key()` applied: there is no encrypted
      // spend key in it to decrypt, so this reads back as the null key. It is
      // how Cake detects a view-only wallet, and it is the guarantee the whole
      // mechanism exists to provide.
      expect(await run.readSecretSpendKey(), FakeMoneroBackend.nullSpendKey);
      expect(BigInt.parse(await run.readSecretSpendKey(), radix: 16), BigInt.zero);
    });

    test('never asks for a transaction key', () async {
      backend.transactions = [
        _tx('aaa', direction: txDirectionIncoming),
        _tx('bbb', direction: txDirectionOutgoing, confirmations: 12),
      ];
      final run = await backgroundRun();

      await run.refreshTxHistory();

      // `WalletImpl::getTxKey` refuses the call on a background wallet and
      // writes the refusal onto the wallet's *global* error status; once per
      // transaction, clobbering whatever else was there, on a status that
      // `openExisting` and the restore paths both throw on.
      expect(backend.txKeyRequests, isEmpty);
      expect(run.readTxHistory().map((t) => t.key).toSet(), {''});
    });

    test('does not write its approximate numbers to the display snapshot', () async {
      final run = await backgroundRun();
      run.setCachePassword('cache-password');
      await run.loadCache();
      backend.unlockedBalanceValue = BigInt.from(5);
      backend.balanceValue = BigInt.from(5);
      await run.loadUnlockedBalance();
      await run.loadTotalBalance();

      await run.persistWalletSnapshot();
      await run.persistCache();

      // An output received *during* a view-only scan has no computable key
      // image, so a spend of it is not seen until the main wallet merges the
      // cache; the balance is high, not wrong-by-a-bug. The snapshot is what
      // the next cold start puts on screen before any sync, so it may only ever
      // come from the real wallet.
      final fresh = nextRun();
      fresh.setCachePassword('cache-password');
      await fresh.loadCache();
      connectOn(fresh, 'node');
      await fresh.loadPersistedSnapshot();
      expect(fresh.unlockedBalanceBaseUnits, isNull);
    });

    test('falls back to the main wallet when there is no cache yet', () async {
      // The first run after the setting is switched on, before any open has
      // written the files. Syncing the real wallet is the correct fallback; the
      // alternative is a wake-up that does nothing at all.
      await enableBackgroundSync();
      final run = nextRun();
      run.markUnattended();
      connectOn(run, 'node');
      backend.existingWalletPaths.add(await pathFor('node'));

      await run.openExisting(password: _password);

      expect(backend.opens.single.path, isNot(endsWith('.background')));
      expect(run.isBackgroundWallet, isFalse);
    });

    test('an LWS run opens the ordinary wallet', () async {
      await enableBackgroundSync();
      final run = nextRun();
      run.markUnattended();
      connectOn(run, 'lws');
      backend.existingWalletPaths.add(await pathFor('lws'));

      await run.openExisting(password: _password);

      expect(backend.opens.single.password, _password);
      expect(run.isBackgroundWallet, isFalse);
      expect(backend.backgroundSyncSetups, isEmpty);
    });

    test('refuses to sync when the file it opened is not a background wallet', () async {
      // The failure that must not be silent. If this path ever opened a
      // fully-keyed wallet believing otherwise, the run would be scanning with a
      // spendable key and nobody present, the exact posture being removed.
      await enableBackgroundSync();
      await openMain('node');
      await materialiseBackgroundFiles();
      final backgroundPath = MoneroWallet.backgroundPathFor(await pathFor('node'));
      backend.existingWalletPaths.add(backgroundPath);
      // Present on disk, present to the backend, but not a background wallet.
      backend.backgroundWalletPaths.remove(backgroundPath);

      final run = nextRun();
      run.markUnattended();
      connectOn(run, 'node');

      await expectLater(run.openExisting(password: _password), throwsA(isA<StateError>()));
      expect(run.isBackgroundWallet, isFalse);
    });

    test('marking a wallet unattended after it is open is refused', () async {
      await openMain('node');
      wallet.markUnattended();

      // The flag chooses the file and the password, so setting it afterwards
      // would leave a fully-keyed wallet open while claiming otherwise.
      expect(wallet.unattended, isFalse);
    });
  });

  group('two secrets, two lifetimes', () {
    test('deleting the wallet removes the background cache password', () async {
      await enableBackgroundSync();
      await openMain('node');
      expect(await WalletSecrets.store.read(wallet.backgroundCachePasswordKey), isNotNull);

      await wallet.delete();

      expect(await WalletSecrets.store.read(wallet.backgroundCachePasswordKey), isNull);
    });

    test('deleting the wallet removes the background cache files', () async {
      await enableBackgroundSync();
      await openMain('node');
      final nodePath = await pathFor('node');
      for (final p in [
        nodePath,
        '$nodePath.keys',
        MoneroWallet.backgroundPathFor(nodePath),
        '${MoneroWallet.backgroundPathFor(nodePath)}.keys',
      ]) {
        await File(p).writeAsString('x');
      }

      await wallet.deleteFiles();

      // The main keys file carries the key the background cache is encrypted
      // with. A main file removed without them leaves an orphaned copy of this
      // wallet's view key and the transactions it saw, with nothing that will
      // ever open it again to notice.
      expect(await File(MoneroWallet.backgroundPathFor(nodePath)).exists(), isFalse);
      expect(await File('${MoneroWallet.backgroundPathFor(nodePath)}.keys').exists(), isFalse);
    });

    test('switching away from node mode tears the configuration down', () async {
      await enableBackgroundSync();
      connect('node');
      await wallet.restoreFromSeed(
        seed: const MoneroLegacySeed(_legacy25),
        from: const RestorePoint.height(2800000),
        password: _password,
      );
      await File(await pathFor('node')).writeAsString('wallet');
      backend.existingWalletPaths.add(await pathFor('node'));
      await File(await pathFor('lws')).writeAsString('wallet');
      backend.existingWalletPaths.add(await pathFor('lws'));
      backend.backgroundSyncSetups.clear();

      connect('lws');
      await wallet.applyConnectionChange(password: _password);

      // The background files belong to the node-mode wallet file and LWSF
      // neither writes nor reads them, so left in place they are an orphaned
      // copy of this wallet's view key.
      expect(backend.backgroundSyncSetups.first.type, MoneroBackgroundSyncType.off);
    });
  });
}

void connectOn(MoneroWallet w, String type) => w.setConnection(
  address: type == 'node' ? 'node.example.com:18081' : 'lws.example.com:18090',
  proxyPort: '',
  useTor: false,
  connectionType: type,
);

NativeTxInfo _tx(
  String hash, {
  required int direction,
  int confirmations = 10,
  String txKey = '',
}) => NativeTxInfo(
  direction: direction,
  hash: hash,
  amount: BigInt.from(1000),
  fee: BigInt.from(10),
  timestamp: 1700000000,
  blockHeight: 2900000,
  confirmations: confirmations,
  subaddrAccount: 0,
  subaddrIndex: '0',
  isPending: false,
  isFailed: false,
  paymentId: '',
  txKey: txKey,
);
