import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

/// The persisted half of the notification marker, and the `CryptoWallet` surface
/// on top of it: that it lives in secure storage rather than preferences, that
/// it seeds instead of announcing a backlog, that it records what was seen even
/// with notifications off, and that it is namespaced so Skylight keeps the key
/// it has already shipped.

TxDetails _tx({
  required String hash,
  required int timestamp,
  int direction = txDirectionIncoming,
  int height = 100,
}) => TxDetails(
  index: 0,
  direction: direction,
  hash: hash,
  amountBaseUnits: BigInt.from(1500000000000),
  feeBaseUnits: BigInt.zero,
  recipients: const [],
  accountIndex: 0,
  subaddrIndexList: const [0],
  timestamp: timestamp,
  height: height,
  confirmations: height > 0 ? 1 : 0,
  key: '',
);

/// A coin that wants many confirmations before a transaction counts as settled;
/// Ethereum mainnet's 12.
class _SlowToConfirmWallet extends FakeWallet {
  _SlowToConfirmWallet(super.symbol);

  @override
  int get requiredConfirmations => 12;
}

void main() {
  late Directory tmp;
  late MemoryPreferenceStore prefs;
  late MemorySecretStore secrets;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tx_notifications');
    prefs = MemoryPreferenceStore();
    SharedPreferencesService.store = prefs;
    secrets = MemorySecretStore();
    WalletSecrets.store = secrets;
  });

  tearDown(() {
    CryptoWallet.resetInjectablesForTesting();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void installSpice() =>
      WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
  void installSkylight() =>
      WalletAppConfig.install(WalletAppConfig.skylight, directories: FixedDirectories(tmp));

  Map<String, dynamic>? storedFor(String key) {
    final raw = secrets.values[key];
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  /// Records what the app would have shown the user.
  List<TxDetails> captureNotifications() {
    final seen = <TxDetails>[];
    CryptoWallet.incomingTxNotifier = (tx, coin) => seen.add(tx);
    return seen;
  }

  group('storage location', () {
    test('nothing about announced transactions reaches shared preferences', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);

      await wallet.markExistingTxsAsNotified();

      // These are on-chain identifiers. Shared preferences is a plaintext file
      // next to the theme and language settings; the keystore is not.
      expect(prefs.values, isEmpty);
      expect(secrets.values.keys, ['xmr_txNotificationState']);
    });

    test('an app that shipped a bare key keeps it', () async {
      installSkylight();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);

      await wallet.markExistingTxsAsNotified();

      // Renaming this would silently reset the marker for every existing user,
      // and the next sync would announce their whole history.
      expect(secrets.values.keys, ['txNotificationState']);
    });

    test('Spice namespaces per coin, so one coin cannot consume another marker', () async {
      installSpice();
      final xmr = FakeWallet('XMR');
      final btc = FakeWallet('BTC');
      addTearDown(xmr.dispose);
      addTearDown(btc.dispose);

      await xmr.markExistingTxsAsNotified();
      await btc.markExistingTxsAsNotified();

      expect(
        secrets.values.keys,
        containsAll(['xmr_txNotificationState', 'btc_txNotificationState']),
      );
    });

    test('state survives a round trip and can be cleared', () async {
      await TxNotificationStore.write(
        'k',
        const TxNotificationState(cutoff: 42, announcedHashes: ['a', 'b']),
      );

      final read = await TxNotificationStore.read('k');
      expect(read.cutoff, 42);
      expect(read.announcedHashes, ['a', 'b']);

      await TxNotificationStore.delete('k');
      expect((await TxNotificationStore.read('k')).cutoff, isNull);
    });

    test('an unreadable entry reads as "nothing recorded" rather than throwing', () async {
      secrets.values['k'] = 'not json';
      final read = await TxNotificationStore.read('k');
      expect(read.cutoff, isNull);
      expect(read.announcedHashes, isEmpty);
    });

    test('toString names no transaction id', () {
      const state = TxNotificationState(cutoff: 42, announcedHashes: ['deadbeef']);
      expect(state.toString(), isNot(contains('deadbeef')));
      expect(state.toString(), contains('1 hashes'));
    });
  });

  group('markExistingTxsAsNotified', () {
    test('seeds the cutoff to now and clears the hashes', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);

      secrets.values['xmr_txNotificationState'] = jsonEncode({
        'cutoff': 10,
        'announcedHashes': ['stale'],
      });

      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await wallet.markExistingTxsAsNotified();
      final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      final state = storedFor('xmr_txNotificationState')!;
      expect(state['cutoff'], greaterThanOrEqualTo(before));
      expect(state['cutoff'], lessThanOrEqualTo(after));
      expect(state['announcedHashes'], isEmpty);
    });
  });

  group('notifyNewIncomingTxs', () {
    test('the first run with no marker seeds instead of announcing a backlog', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      final seen = captureNotifications();

      // A wallet with history and nothing recorded; a fresh install, or an
      // upgrade from Spice's transaction counter.
      wallet.history = [_tx(hash: 'old-1', timestamp: 1000), _tx(hash: 'old-2', timestamp: 2000)];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.notifyNewIncomingTxs();

      expect(seen, isEmpty, reason: 'a backlog is never announced');
      expect(storedFor('xmr_txNotificationState')!['cutoff'], isNotNull);
    });

    test('a receipt after the marker is announced, once', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      final seen = captureNotifications();

      secrets.values['xmr_txNotificationState'] = jsonEncode({
        'cutoff': 1000,
        'announcedHashes': <String>[],
      });

      wallet.history = [_tx(hash: 'new', timestamp: 2000)];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.notifyNewIncomingTxs();
      expect(seen.map((t) => t.hash), ['new']);

      // A second pass (the next timer tick, or another isolate) says nothing.
      await wallet.notifyNewIncomingTxs();
      expect(seen.map((t) => t.hash), ['new']);
    });

    test('announce:false records the receipt as seen without firing the notifier', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      final seen = captureNotifications();

      secrets.values['xmr_txNotificationState'] = jsonEncode({
        'cutoff': 1000,
        'announcedHashes': <String>[],
      });

      wallet.history = [_tx(hash: 'watched-on-screen', timestamp: 2000)];
      await wallet.loadTxHistory(persistCount: false);

      // The foreground marks what the user watched arrive as seen; no OS
      // notification for it.
      await wallet.notifyNewIncomingTxs(announce: false);
      expect(seen, isEmpty);

      // And the mark stuck: a later background pass does not re-announce it.
      await wallet.notifyNewIncomingTxs();
      expect(seen, isEmpty);
    });

    test('a restore then a scan announces nothing', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      final seen = captureNotifications();

      // What WalletManager does after restoreFromSeed.
      await wallet.markExistingTxsAsNotified();

      // The scan then turns up the whole history behind the seed.
      wallet.history = [
        _tx(hash: 'historical-1', timestamp: 1000),
        _tx(hash: 'historical-2', timestamp: 2000),
      ];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.notifyNewIncomingTxs();

      expect(seen, isEmpty, reason: 'this is the bug the marker exists to fix');
    });

    test('a self-send is not announced, and is not left to announce later', () async {
      // End to end for the change/self-send rule: the wallet's own transaction
      // comes back as two entries under one hash, which is how Monero reports a
      // send between its own accounts, and neither is money received.
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      final seen = captureNotifications();

      secrets.values['xmr_txNotificationState'] = jsonEncode({
        'cutoff': 1000,
        'announcedHashes': <String>[],
      });

      wallet.history = [
        _tx(hash: 'churn', timestamp: 2000, direction: txDirectionOutgoing),
        _tx(hash: 'churn', timestamp: 2000),
      ];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.notifyNewIncomingTxs();

      expect(seen, isEmpty);
      // The cutoff still advanced, so the next tick does not reconsider it, and
      // the hash list is untouched; a suppressed entry is not a receipt to
      // remember, and the list is capped at 50 real ones.
      final state = storedFor('xmr_txNotificationState')!;
      expect(state['cutoff'], 2000);
      expect(state['announcedHashes'], isEmpty);
    });

    test('with no notifier installed the transaction still counts as seen', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      // No incomingTxNotifier, the core's equivalent of notifications off.

      secrets.values['xmr_txNotificationState'] = jsonEncode({
        'cutoff': 1000,
        'announcedHashes': <String>[],
      });
      wallet.history = [_tx(hash: 'while-off', timestamp: 2000)];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.notifyNewIncomingTxs();

      expect(storedFor('xmr_txNotificationState')!['announcedHashes'], ['while-off']);

      // Switching notifications on later must not replay it.
      final seen = captureNotifications();
      await wallet.notifyNewIncomingTxs();
      expect(seen, isEmpty);
    });

    test('an unchanged history writes nothing, so the keystore is not churned', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);

      secrets.values['xmr_txNotificationState'] = jsonEncode({
        'cutoff': 5000,
        'announcedHashes': ['a'],
      });
      wallet.history = [_tx(hash: 'a', timestamp: 1000)];
      await wallet.loadTxHistory(persistCount: false);

      final before = secrets.values['xmr_txNotificationState'];
      await wallet.notifyNewIncomingTxs();
      // This runs on a timer; every write is a keystore round trip.
      expect(secrets.values['xmr_txNotificationState'], before);
    });

    test('loadTxHistory does not touch the marker', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      final seen = captureNotifications();

      secrets.values['xmr_txNotificationState'] = jsonEncode({
        'cutoff': 1000,
        'announcedHashes': <String>[],
      });
      wallet.history = [_tx(hash: 'new', timestamp: 2000)];

      // Every isolate refreshes history on its own timer. If announcing lived
      // here, whichever one ran first would consume the marker for all of them.
      await wallet.loadTxHistory(persistCount: false);
      expect(seen, isEmpty);
      expect(storedFor('xmr_txNotificationState')!['cutoff'], 1000);
    });

    test('outgoing transactions are never announced', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      final seen = captureNotifications();

      secrets.values['xmr_txNotificationState'] = jsonEncode({
        'cutoff': 1000,
        'announcedHashes': <String>[],
      });
      wallet.history = [_tx(hash: 'sent', timestamp: 2000, direction: txDirectionOutgoing)];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.notifyNewIncomingTxs();

      expect(seen, isEmpty);
      // The cutoff still advances: it records what was seen, not what was said.
      expect(storedFor('xmr_txNotificationState')!['cutoff'], 2000);
    });

    test('the notifier is told which coin the transaction belongs to', () async {
      installSpice();
      final wallet = FakeWallet('BTC');
      addTearDown(wallet.dispose);

      final coins = <String>[];
      CryptoWallet.incomingTxNotifier = (tx, coin) => coins.add(coin);

      secrets.values['btc_txNotificationState'] = jsonEncode({
        'cutoff': 1000,
        'announcedHashes': <String>[],
      });
      wallet.history = [_tx(hash: 'new', timestamp: 2000)];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.notifyNewIncomingTxs();

      expect(coins, ['BTC']);
    });
  });

  group('lifecycle', () {
    test('delete clears the marker', () async {
      installSpice();
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);

      await wallet.markExistingTxsAsNotified();
      expect(secrets.values.containsKey('xmr_txNotificationState'), isTrue);

      await wallet.delete();

      // Left behind, the next wallet on this device inherits a cutoff from
      // someone else's history and stays silent about its own first receipts.
      expect(secrets.values.containsKey('xmr_txNotificationState'), isFalse);
    });

    test('one block is enough for the cutoff, even when the coin wants twelve', () async {
      installSpice();
      final wallet = _SlowToConfirmWallet('ETH');
      addTearDown(wallet.dispose);

      final oneBlock = _tx(hash: 'a', timestamp: 2000, height: 100);
      // Two different questions: `isTxInABlock` asks whether the timestamp has
      // stopped moving, `isTxConfirmed` whether the money is safe to spend.
      expect(isTxInABlock(oneBlock), isTrue);
      expect(wallet.isTxConfirmed(oneBlock), isFalse);

      secrets.values['eth_txNotificationState'] = jsonEncode({
        'cutoff': 1000,
        'announcedHashes': <String>[],
      });
      wallet.history = [oneBlock];
      await wallet.loadTxHistory(persistCount: false);
      await wallet.notifyNewIncomingTxs();

      // Waiting for 12 blocks to advance the cutoff would leave a wide window
      // in which a re-timestamped transaction is announced twice.
      expect(storedFor('eth_txNotificationState')!['cutoff'], 2000);
    });
  });
}
