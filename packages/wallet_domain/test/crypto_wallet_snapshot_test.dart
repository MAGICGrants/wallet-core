import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

/// The snapshot and teardown half: `loadAllStats`,
/// `loadCachedStats` (now `loadPersistedSnapshot` + cache hydration), and
/// `delete` / `clearPersistedState`.
///
/// What these have in common: the balance and transaction list are
/// linkable metadata and live in an **encrypted** cache, where Skylight kept
/// them in plaintext SharedPreferences. So the assertions are as much about
/// what is *not* written, and about what is removed on delete, as about the
/// round trip.

TxDetails _tx(String hash, {int timestamp = 1000, int height = 100, int confirmations = 3}) =>
    TxDetails(
      index: 0,
      direction: txDirectionIncoming,
      hash: hash,
      amountBaseUnits: BigInt.from(1500000000000),
      feeBaseUnits: BigInt.zero,
      recipients: const [],
      accountIndex: 0,
      subaddrIndexList: const [0],
      timestamp: timestamp,
      height: height,
      confirmations: confirmations,
      key: '',
    );

void main() {
  late Directory tmp;
  late MemoryPreferenceStore prefs;
  late MemorySecretStore secrets;

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('snapshot');
    prefs = MemoryPreferenceStore();
    SharedPreferencesService.store = prefs;
    secrets = MemorySecretStore();
    WalletSecrets.store = secrets;
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
  });

  tearDown(() {
    CryptoWallet.resetInjectablesForTesting();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<FakeWallet> readyWallet({String? cachePassword = 'cache-pw'}) async {
    final wallet = FakeWallet('XMR');
    addTearDown(wallet.dispose);
    await wallet.openExisting(password: 'pw');
    wallet.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);
    wallet.connected = true;
    if (cachePassword != null) {
      wallet.setCachePassword(cachePassword);
      await wallet.loadCache();
    }
    wallet.lifecycle.clear();
    return wallet;
  }

  group('a session that starts with no server configured', () {
    // The guard below reads the address once, at hydration. A launch that comes
    // up with no server configured therefore skips the cached display for the
    // whole session, however the connection is set afterwards.
    test('the cached balance and history are skipped, and adding a server later '
        'does not bring them back', () async {
      final first = await readyWallet();
      first.setBalancesForTesting(
        total: BigInt.from(4000000000000),
        unlocked: BigInt.from(4000000000000),
      );
      first.history = [_tx('a'), _tx('b')];
      await first.loadTxHistory(persistCount: false);
      await first.persistWalletSnapshot();
      await first.persistCache();

      // The launch that lost its server: cache hydration runs, but
      // `loadPersistedSnapshot` returns on the empty-address guard.
      final second = FakeWallet('XMR');
      addTearDown(second.dispose);
      second.setCachePassword('cache-pw');
      await second.loadCache();
      await second.loadPersistedSnapshot();

      expect(second.totalBalanceBaseUnits, isNull, reason: 'nothing to show');
      expect(second.txHistory, isEmpty);

      // The user re-enters their node. Nothing re-runs the snapshot load: it is
      // called once, from the manager's open path, and that already happened.
      second.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);

      expect(second.totalBalanceBaseUnits, isNull, reason: 'still nothing, for the whole session');
      expect(second.txHistory, isEmpty);

      // Only the next launch, with the address now persisted, paints it.
      final third = FakeWallet('XMR');
      addTearDown(third.dispose);
      third.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);
      third.setCachePassword('cache-pw');
      await third.loadCache();
      await third.loadPersistedSnapshot();

      expect(third.totalBalanceBaseUnits, BigInt.from(4000000000000));
      expect(third.txHistory.map((t) => t.hash), ['a', 'b']);
    });
  });

  group('the snapshot round trip', () {
    test('a balance and history survive a restart and show before any sync', () async {
      final first = await readyWallet();
      first.setBalancesForTesting(
        total: BigInt.parse('9007199254740993'),
        unlocked: BigInt.from(1500000000000),
      );
      first.history = [_tx('a'), _tx('b')];
      await first.loadTxHistory(persistCount: false);
      await first.persistWalletSnapshot();
      await first.persistCache();

      // A second instance, nothing synced, nothing connected yet.
      final second = FakeWallet('XMR');
      addTearDown(second.dispose);
      second.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);
      second.setCachePassword('cache-pw');
      await second.loadCache();
      await second.loadPersistedSnapshot();

      // The point of the snapshot is that the user sees their balance on the
      // first frame rather than a spinner while a scan catches up.
      expect(second.totalBalanceBaseUnits, BigInt.parse('9007199254740993'));
      expect(second.unlockedBalanceBaseUnits, BigInt.from(1500000000000));
      expect(second.txHistory.map((t) => t.hash), ['a', 'b']);
    });

    test('a balance past 2^53 comes back exact, because it is stored as a string', () async {
      final wallet = await readyWallet();
      final big = BigInt.parse('9007199254740993'); // 2^53 + 1
      wallet.setBalancesForTesting(total: big, unlocked: big);
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      // Not a JSON number: those are IEEE doubles and this one does not survive
      // the round trip as one.
      final raw = await WalletCacheStore.load('XMR', 'cache-pw');
      expect(raw['cachedTotalBalanceUnits'], isA<String>());
      expect(raw['cachedTotalBalanceUnits'], '9007199254740993');
    });

    test('nothing reaches shared preferences', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      wallet.history = [_tx('a')];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      // Balances and the transaction list were once cached to plaintext
      // SharedPreferences. A balance and a list of txids in a readable file
      // ties the device to those transactions for anyone who gets the files.
      final leaked = prefs.values.entries.where(
        (e) => e.value.toString().contains('1500000000000') || e.value.toString().contains('"a"'),
      );
      expect(leaked, isEmpty);
    });

    test('the total falls back to the unlocked figure when it was never set', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: null, unlocked: BigInt.from(42));
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      final second = await readyWallet();
      await second.loadPersistedSnapshot();

      expect(second.totalBalanceBaseUnits, BigInt.from(42));
    });
  });

  group('what the snapshot refuses to write', () {
    test('a wallet with no balance yet writes nothing', () async {
      final wallet = await readyWallet();
      // Never loaded a balance; writing here records "0" as the last known
      // figure, and the next cold start shows an empty wallet.
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      expect(await WalletCacheStore.load('XMR', 'cache-pw'), isEmpty);
    });

    test('an inactive wallet writes nothing', () async {
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      wallet.setCachePassword('cache-pw');
      await wallet.loadCache();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));

      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      expect(await WalletCacheStore.load('XMR', 'cache-pw'), isEmpty);
    });

    test('a clean cache is not rewritten — every write is a KDF round trip', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      final before = await WalletCacheStore.load('XMR', 'cache-pw');
      // Nothing changed since. This runs on a timer, and the encryption is
      // 600k PBKDF2 rounds in production.
      await wallet.persistCache();
      expect(await WalletCacheStore.load('XMR', 'cache-pw'), before);
    });

    test('with no cache password nothing is written and nothing throws', () async {
      final wallet = await readyWallet(cachePassword: null);
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));

      await wallet.persistWalletSnapshot();
      await expectLater(wallet.persistCache(), completes);
    });

    test('an unchanged snapshot leaves the cache clean', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      wallet.history = [_tx('a')];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      // The gate `persistCache` already had was defeated by its own caller:
      // `cachePut` marked the cache dirty with no comparison, so writing the
      // same three values every 20-second cycle meant a full AES-GCM encrypt
      // and a file rewrite every cycle regardless. `cacheRemove` three lines
      // below always compared; the asymmetry was unintentional.
      await wallet.persistWalletSnapshot();
      expect(wallet.cacheDirtyForTesting, isFalse);
    });

    test('the history is not re-encoded when only confirmations moved', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      wallet.history = [_tx('a')];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      // Fixing the comparison stops the encrypt and the write but not the
      // *encode*; `jsonEncode` over every transaction the wallet has ever seen
      // runs before `cachePut` is reached. Confirmation counts tick up with
      // every block, so they are excluded from the revision deliberately: the
      // cost is a cold start showing a count up to one cycle stale.
      wallet.history = [_tx('a', confirmations: 99)];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.persistWalletSnapshot();

      expect(wallet.cacheDirtyForTesting, isFalse);
    });

    test('a new transaction does re-encode', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      wallet.history = [_tx('a')];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      wallet.history = [_tx('b', timestamp: 2000), _tx('a')];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.persistWalletSnapshot();

      expect(wallet.cacheDirtyForTesting, isTrue);
    });

    test('a mempool transaction confirming does re-encode', () async {
      // The case a length comparison misses: same count, same hash, and the
      // height going from -1 to a real value is exactly what the snapshot is
      // for.
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      wallet.history = [_tx('a', height: -1)];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      wallet.history = [_tx('a')];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.persistWalletSnapshot();

      expect(wallet.cacheDirtyForTesting, isTrue);
    });

    test('a wiped cache is rewritten rather than skipped as up to date', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      wallet.history = [_tx('a')];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      // The revisions are runtime-only, so clearing them with the cache is what
      // stops a skip on a revision describing a cache that no longer exists.
      await wallet.clearPersistedState();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      final raw = await WalletCacheStore.load('XMR', 'cache-pw');
      expect(raw['cachedTxHistory'], isNotNull);
    });
  });

  group('loading a snapshot that is not there or not readable', () {
    test('an unconfigured wallet loads nothing rather than showing a stale balance', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      // No server configured: this wallet is not set up, and last session's
      // numbers are not its numbers.
      final fresh = FakeWallet('XMR');
      addTearDown(fresh.dispose);
      fresh.setCachePassword('cache-pw');
      await fresh.loadCache();
      await fresh.loadPersistedSnapshot();

      expect(fresh.totalBalanceBaseUnits, isNull);
      expect(fresh.txHistory, isEmpty);
    });

    test('a corrupt cached history leaves the balance intact', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      // Rewrite the history entry as junk, keeping the balances.
      final raw = await WalletCacheStore.load('XMR', 'cache-pw');
      raw['cachedTxHistory'] = 'not json at all';
      await WalletCacheStore.save('XMR', raw, 'cache-pw');

      final second = await readyWallet();
      await second.loadPersistedSnapshot();

      // Losing the history is survivable; it is refetched. Losing the balance
      // with it, or throwing, is not.
      expect(second.unlockedBalanceBaseUnits, BigInt.from(5));
      expect(second.txHistory, isEmpty);
    });

    test('a cache written under a different password reads as empty', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      final other = FakeWallet('XMR');
      addTearDown(other.dispose);
      other.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);
      other.setCachePassword('the-wrong-password');
      await other.loadCache();
      await other.loadPersistedSnapshot();

      expect(other.totalBalanceBaseUnits, isNull);
    });
  });

  group('delete', () {
    test('files, prefs, cache and the notification marker all go', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      wallet.history = [_tx('a')];
      await wallet.loadTxHistory();
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();
      await wallet.markExistingTxsAsNotified();
      await SharedPreferencesService.set<int>('xmr_walletRestoreHeight', 3000000);

      await wallet.delete();

      expect(wallet.deleteFileCount, 1);
      expect(prefs.values.containsKey('xmr_walletRestoreHeight'), isFalse);
      expect(prefs.values.containsKey('xmr_txHistoryCount'), isFalse);
      expect(await WalletCacheStore.load('XMR', 'cache-pw'), isEmpty);
      // Two secrets, two lifetimes: a marker left behind gives the *next*
      // wallet on this device a cutoff from someone else's history, and it
      // stays silent about its own first receipts.
      expect(secrets.values.containsKey('xmr_txNotificationState'), isFalse);
      expect(wallet.isLoaded, isFalse);
    });

    test('deleting one coin leaves another coin alone', () async {
      final xmr = await readyWallet();
      final btc = FakeWallet('BTC');
      addTearDown(btc.dispose);
      await btc.openExisting(password: 'pw');
      btc.setConnection(address: 'electrum.example.com:50002', proxyPort: '', useTor: false);
      btc.setCachePassword('cache-pw');
      await btc.loadCache();
      btc.setBalancesForTesting(total: BigInt.from(9), unlocked: BigInt.from(9));
      await btc.persistWalletSnapshot();
      await btc.persistCache();
      await btc.markExistingTxsAsNotified();

      await xmr.delete();

      expect((await WalletCacheStore.load('BTC', 'cache-pw')).isNotEmpty, isTrue);
      expect(secrets.values.containsKey('btc_txNotificationState'), isTrue);
    });

    test('in-memory cache state is cleared, not just the file', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      await wallet.persistWalletSnapshot();

      await wallet.clearPersistedState();
      // Dirty state surviving the clear would write the deleted wallet's
      // balance straight back on the next persist.
      await wallet.persistCache();

      expect(await WalletCacheStore.load('XMR', 'cache-pw'), isEmpty);
    });
  });

  group('loadAllStats', () {
    test('it notifies before the slow read, not only after it', () async {
      final wallet = await readyWallet();
      var notifications = 0;
      wallet.addListener(() => notifications++);
      wallet.history = [_tx('a')];

      await wallet.loadAllStats();

      // Balance and sync state are staged ahead of the transaction read, which
      // is the slow one; the number the user is looking at must not wait for
      // a history fetch.
      expect(notifications, greaterThanOrEqualTo(2));
    });

    test('a disconnected wallet reads stats but persists nothing', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(5), unlocked: BigInt.from(5));
      wallet.connected = false;

      await wallet.loadAllStats();

      // Snapshotting mid-drop records whatever partial numbers the failed
      // reads left behind, and that is what the next cold start would show.
      expect(await WalletCacheStore.load('XMR', 'cache-pw'), isEmpty);
    });
  });

  group('the cached tx history survives a JSON round trip', () {
    test('amounts stay exact and the list order is kept', () async {
      final wallet = await readyWallet();
      wallet.setBalancesForTesting(total: BigInt.from(1), unlocked: BigInt.from(1));
      wallet.history = [_tx('newest', timestamp: 3000), _tx('older', timestamp: 1000)];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.persistWalletSnapshot();
      await wallet.persistCache();

      final raw = await WalletCacheStore.load('XMR', 'cache-pw');
      final decoded = parseCachedTxHistory(raw['cachedTxHistory'] as String);

      expect(decoded.map((t) => t.hash), ['newest', 'older']);
      expect(decoded.first.amountBaseUnits, BigInt.from(1500000000000));
      // Amounts are serialised as strings for the same reason balances are.
      final asJson = jsonDecode(raw['cachedTxHistory'] as String) as List<dynamic>;
      expect((asJson.first as Map<String, dynamic>)['amount'], isA<String>());
    });
  });
}
