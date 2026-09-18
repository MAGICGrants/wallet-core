import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

/// The rest of the orchestration: `ensureConnectionLoaded`, `load`,
/// `loadTxHistory`, the refresh timer task and `dispose`.
///
/// Four of these are `M` or `S→new` rows, which the phase order says to test
/// before merging, and the refresh task in particular had nothing at all; it
/// runs on a 20-second `Timer`, so it is only reachable now that the two timer
/// tasks are `@visibleForTesting`.

TxDetails _tx(String hash, {int confirmations = 6, int timestamp = 1000}) => TxDetails(
  index: 0,
  direction: txDirectionIncoming,
  hash: hash,
  amountBaseUnits: BigInt.from(1000),
  feeBaseUnits: BigInt.zero,
  recipients: const [],
  accountIndex: 0,
  subaddrIndexList: const [0],
  timestamp: timestamp,
  height: 100,
  confirmations: confirmations,
  key: '',
);

/// A coin that wants twelve confirmations, like Ethereum mainnet; so
/// "pending" is a coin-specific question, not a hardcoded 10.
class _SlowToConfirmWallet extends FakeWallet {
  _SlowToConfirmWallet(super.symbol);

  @override
  int get requiredConfirmations => 12;
}

/// A coin whose fast-cadence sync poll throws, the way a native stats read can
/// when it races a connect on the same wallet handle.
class _PollThrowsWallet extends FakeWallet {
  _PollThrowsWallet(super.symbol);

  bool pollShouldThrow = true;

  @override
  Future<void> pollSyncStatus() async {
    if (pollShouldThrow) throw Exception('native stats read failed');
    return super.pollSyncStatus();
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('lifecycle');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
  });

  tearDown(() {
    CryptoWallet.resetInjectablesForTesting();
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    TorSettingsService.sharedInstance.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<FakeWallet> readyWallet({FakeWallet? of}) async {
    final wallet = of ?? FakeWallet('XMR');
    addTearDown(wallet.dispose);
    await wallet.openExisting(password: 'pw');
    wallet.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);
    wallet.connected = true;
    wallet.lifecycle.clear();
    return wallet;
  }

  group('ensureConnectionLoaded', () {
    test('reads the persisted connection when nothing is in memory', () async {
      // Persist from one instance...
      final first = FakeWallet('XMR');
      addTearDown(first.dispose);
      first.setConnection(
        address: 'saved.example.com:18081',
        proxyPort: '1080',
        useTor: false,
        connectionType: 'node',
      );
      await first.persistCurrentConnection();

      // ...and a fresh one, which has never had setConnection called, finds it.
      final second = FakeWallet('XMR');
      addTearDown(second.dispose);
      expect(second.connectionAddress, isEmpty);

      await second.ensureConnectionLoadedForTesting();

      // This is what makes `hasExistingWallet` answerable: for Monero, *which*
      // file to look for depends on the connection type, so checking the
      // default path first reports "no wallet" for a node user and drops them
      // into onboarding on top of an existing wallet.
      expect(second.connectionAddress, 'saved.example.com:18081');
      expect(second.connectionType, 'node');
    });

    test('an in-memory connection is not overwritten by the persisted one', () async {
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      await SharedPreferencesService.set('xmr_connectionAddress', 'stale.example.com:18081');

      wallet.setConnection(address: 'chosen.example.com:18081', proxyPort: '', useTor: false);
      await wallet.ensureConnectionLoadedForTesting();

      // The user just picked a server; reloading disk over it would revert them.
      expect(wallet.connectionAddress, 'chosen.example.com:18081');
    });

    test('with nothing persisted it leaves the wallet unconfigured, not broken', () async {
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);

      await wallet.ensureConnectionLoadedForTesting();

      expect(wallet.connectionAddress, isEmpty);
      expect(wallet.isActive, isFalse);
    });
  });

  group('load', () {
    test('connects, then refreshes, then reads stats — in that order', () async {
      final wallet = await readyWallet();

      await wallet.load();

      // Reading stats before the refresh reports the previous cycle's numbers,
      // and refreshing before connecting reads nothing at all.
      expect(wallet.lifecycle.take(3).toList(), ['connect', 'refresh', 'loadAllStats']);
    });

    test('an inactive wallet does nothing', () async {
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      await wallet.openExisting(password: 'pw');
      // Opened, but no server configured.
      wallet.lifecycle.clear();

      await wallet.load();

      expect(wallet.lifecycle, isEmpty);
    });

    test('loadAllStats persists a snapshot only while connected', () async {
      final wallet = await readyWallet();
      wallet.setCachePassword('pw');
      wallet.history = [_tx('a')];

      await wallet.loadAllStats();
      // Nothing to snapshot: the fake never sets a balance, and
      // persistWalletSnapshot bails without one rather than writing nulls.
      expect(wallet.totalBalanceBaseUnits, isNull);

      // Disconnected, the whole persist step is skipped.
      wallet.connected = false;
      wallet.lifecycle.clear();
      await wallet.loadAllStats();
      expect(wallet.lifecycle, ['loadAllStats']);
    });

    test('applyConnectionChange on a coin with no server-kind switch just reloads', () async {
      // The base has no mode to rebuild for (only Monero's LWS↔node does),
      // so applying a connection change is a plain reconnect + refresh.
      final wallet = await readyWallet();

      await wallet.applyConnectionChange(password: 'pw');

      expect(wallet.lifecycle.take(3).toList(), ['connect', 'refresh', 'loadAllStats']);
    });
  });

  group('loadTxHistory', () {
    test('a sync that returns nothing keeps the cached list', () async {
      final wallet = await readyWallet();
      wallet.history = [_tx('a'), _tx('b')];
      await wallet.loadTxHistory();
      expect(wallet.txHistory, hasLength(2));

      // Not connected yet, mid-reopen, whatever: an empty read is "don't know",
      // not "the wallet is empty". Blanking the list here shows a user with a
      // balance and no transactions.
      wallet.history = const [];
      await wallet.loadTxHistory();

      expect(wallet.txHistory, hasLength(2));
    });

    test('an empty read on a wallet that never had transactions is accepted', () async {
      final wallet = await readyWallet();
      await wallet.loadTxHistory();
      expect(wallet.txHistory, isEmpty);
    });

    test('confirmations keep updating while the newest transaction is pending', () async {
      final wallet = await readyWallet(of: _SlowToConfirmWallet('ETH'));
      wallet.history = [_tx('a', confirmations: 1)];
      await wallet.loadTxHistory();
      expect(wallet.txHistory.first.confirmations, 1);

      // Same transaction, same count; only the confirmation number moved.
      // Skylight rechecked on exactly this condition (its "<10 confirmations"
      // guard); the count-only comparison it replaced left a receipt stuck at
      // "1 confirmation" on screen until another transaction arrived.
      wallet.history = [_tx('a', confirmations: 4)];
      await wallet.loadTxHistory();

      expect(wallet.txHistory.first.confirmations, 4);
    });

    test('"pending" is the coin own threshold, not a hardcoded ten', () async {
      final slow = await readyWallet(of: _SlowToConfirmWallet('ETH'));
      slow.history = [_tx('a', confirmations: 6)];
      await slow.loadTxHistory();
      // 6 < 12, so still pending, and the count is persisted for the recheck.
      expect(await slow.getPersistedTxHistoryCount(), 1);

      final fast = await readyWallet(of: FakeWallet('BTC')); // requires 1
      fast.history = [_tx('a', confirmations: 6)];
      await fast.loadTxHistory();
      // Settled for this coin, but it still grew from zero, so it persists.
      expect(await fast.getPersistedTxHistoryCount(), 1);

      // Now with no growth and nothing pending, there is nothing to write.
      await SharedPreferencesService.remove('btc_txHistoryCount');
      await fast.loadTxHistory();
      expect(await fast.getPersistedTxHistoryCount(), 0);
    });

    test('persistCount: false records nothing — every isolate calls this', () async {
      final wallet = await readyWallet();
      wallet.history = [_tx('a')];

      await wallet.loadTxHistory(persistCount: false);

      expect(wallet.txHistory, hasLength(1));
      expect(await wallet.getPersistedTxHistoryCount(), 0);
    });

    test('growth fires the hook, a steady list does not', () async {
      final wallet = await readyWallet();
      wallet.history = [_tx('a')];
      await wallet.loadTxHistory();
      expect(wallet.txHistoryGrewCount, 1);

      await wallet.loadTxHistory();
      expect(wallet.txHistoryGrewCount, 1, reason: 'no new transactions, no rescan');

      wallet.history = [_tx('b'), _tx('a')];
      await wallet.loadTxHistory();
      expect(wallet.txHistoryGrewCount, 2);
    });

    test('notification state is never touched here', () async {
      final wallet = await readyWallet();
      final seen = <String>[];
      CryptoWallet.incomingTxNotifier = (tx, coin) => seen.add(tx.hash);
      wallet.history = [_tx('a')];

      await wallet.loadTxHistory();

      // Every isolate refreshes on its own timer. If this announced anything,
      // whichever ran first would consume the signal for all of them.
      expect(seen, isEmpty);
      expect(await WalletSecrets.store.read('xmr_txNotificationState'), isNull);
    });
  });

  group('the refresh task', () {
    test('a full cycle refreshes, loads stats and checkpoints', () async {
      final wallet = await readyWallet();
      wallet.setConnectedForTesting(true);

      await wallet.refreshTask();

      expect(wallet.lifecycle, ['refresh', 'loadAllStats', 'store']);
    });

    test('it connects first when the connection dropped', () async {
      final wallet = await readyWallet();
      wallet.setConnectedForTesting(false);

      await wallet.refreshTask();

      expect(wallet.lifecycle.first, 'connect');
      expect(wallet.lifecycle, contains('loadAllStats'));
    });

    test('a connect that fails ends the cycle instead of reading a dead wallet', () async {
      final wallet = await readyWallet();
      wallet.setConnectedForTesting(false);
      wallet.connected = false;
      wallet.connectError = Exception('refused');

      await wallet.refreshTask();

      expect(wallet.lifecycle, ['connect']);
    });

    test('a connect that returns without throwing still refreshes when not connected', () async {
      final wallet = await readyWallet();
      wallet.setConnectedForTesting(false);
      // Connect succeeds (no error) but the daemon still reports not-connected;
      // a light wallet flips connected only after refresh() runs the login/scan.
      wallet.connected = false;
      wallet.connectError = null;

      await wallet.refreshTask();

      // Gating the cycle on _isConnected here would deadlock LWS: never refresh,
      // so never connected, so never refresh. Only a *throwing* connect
      // ends the cycle (the test above).
      expect(wallet.lifecycle, containsAllInOrder(['connect', 'refresh', 'loadAllStats']));
      expect(wallet.isConnected, isFalse);
    });

    test('while an on-device scan runs it only checkpoints', () async {
      final wallet = await readyWallet();
      wallet.deferStats = true;
      wallet.setConnectedForTesting(true);
      wallet.setSyncedForTesting(false);
      // The scan got somewhere. This path never reaches `loadAllStats`, so the
      // fast poll is the only thing that moves the height during a scan, and
      // a checkpoint with nothing to check point is the write the gate skips.
      wallet.setSyncedHeightForTesting(1001);

      await wallet.refreshTask();

      // refresh(), the history read and store() each take the wallet lock and
      // stall the native scan thread. Skylight's contribution to this row is
      // that the deferred path still checkpoints, so an interrupted sync
      // resumes instead of rescanning from the last full cycle.
      expect(wallet.lifecycle, ['store']);
      expect(wallet.refreshCount, 0);
      expect(wallet.statsCount, 0);
    });

    test('the checkpoint is throttled, not once per cycle', () async {
      final wallet = await readyWallet();
      wallet.deferStats = true;
      wallet.setConnectedForTesting(true);
      wallet.setSyncedForTesting(false);

      // Progress before every cycle, so the throttle is the only thing that can
      // hold a write back.
      wallet.setSyncedHeightForTesting(1001);
      await wallet.refreshTask();
      wallet.setSyncedHeightForTesting(1002);
      await wallet.refreshTask();
      wallet.setSyncedHeightForTesting(1003);
      await wallet.refreshTask();

      // A store per 20-second tick during a multi-hour scan is the stall this
      // is meant to avoid; the window is three minutes.
      expect(wallet.storeCount, 1);
    });

    test('a scan that stalls stops rewriting a byte-identical cache', () async {
      final wallet = await readyWallet();
      wallet.deferStats = true;
      wallet.setConnectedForTesting(true);
      wallet.setSyncedForTesting(false);
      // No progress at all: a dead node, a refresh() that threw, or a scan
      // thread a background checkpoint paused and nothing restarted.
      wallet.chainAdvances = false;

      await wallet.refreshTask();
      await wallet.refreshTask();

      // The old code rewrote the whole cache every three minutes for as long as
      // the app stayed open, each write a truncate-then-rewrite with its own
      // corruption window.
      expect(wallet.storeCount, 0);
    });

    test('a synced wallet with nothing new does not store on every cycle', () async {
      final wallet = await readyWallet();
      wallet.setConnectedForTesting(true);
      wallet.chainAdvances = false;

      // First cycle stores: the height goes from null to a real value, which is
      // a change and is worth persisting.
      await wallet.refreshTask();
      expect(wallet.storeCount, 1);

      await wallet.refreshTask();
      await wallet.refreshTask();

      // Three cycles, one store. Before the gate this was a full cache
      // serialise and file rewrite three times a minute, per wallet, forever.
      expect(wallet.storeCount, 1);
    });

    test('a checkpoint clears the flag, so the next cycle does not rewrite it', () async {
      final wallet = await readyWallet();
      wallet.deferStats = true;
      wallet.setConnectedForTesting(true);
      wallet.setSyncedForTesting(false);
      wallet.chainHeight = 1001;
      wallet.chainAdvances = false;
      wallet.setSyncedHeightForTesting(1001);

      await wallet.refreshTask();
      expect(wallet.storeCount, 1);

      // The scan caught up with nothing further to record. Both call sites go
      // through one helper that writes *and* clears the flag, so a full cycle
      // seconds after a checkpoint does not write the same state again.
      wallet.deferStats = false;
      await wallet.refreshTask();

      expect(wallet.storeCount, 1, reason: 'the checkpoint already wrote this state');
    });

    test('a nested suspension does not un-suspend the outer one', () async {
      final wallet = await readyWallet();
      wallet.setConnectedForTesting(true);

      await wallet.runWithSyncSuspendedForTesting(() async {
        await wallet.runWithSyncSuspendedForTesting(() async {});

        // Still inside the outer suspension. With a plain flag the inner
        // `finally` cleared it here, and the timers resumed against a
        // half-rebuilt wallet; a use-after-free in native code, not a Dart
        // exception. Nesting is reachable: the connection-change rebuild wraps
        // a re-open, and an open configures background sync inside its own.
        await wallet.refreshTask();
        expect(wallet.lifecycle, isEmpty);
      });

      // And it does lift once the outermost call returns.
      await wallet.refreshTask();
      expect(wallet.lifecycle, isNotEmpty);
    });

    test('the teardown checkpoint is never gated', () async {
      final wallet = await readyWallet();
      wallet.chainAdvances = false;

      // Nothing Dart can see has changed, but the native scan thread advances
      // state Dart cannot see, so this is the one write whose absence loses a
      // window rather than saving one.
      await wallet.pauseSyncAndStore();
      await wallet.pauseSyncAndStore();

      expect(wallet.storeCount, 2);
      expect(wallet.pauseCount, 2);
    });

    test('once synced the deferred wallet does the full cycle', () async {
      final wallet = await readyWallet();
      wallet.deferStats = true;
      wallet.setConnectedForTesting(true);
      wallet.setSyncedForTesting(true);

      await wallet.refreshTask();

      expect(wallet.lifecycle, ['refresh', 'loadAllStats', 'store']);
    });

    test('a refresh that throws does not skip the stats read', () async {
      final wallet = await readyWallet();
      wallet.setConnectedForTesting(true);
      wallet.refreshError = Exception('node hiccup');

      await wallet.refreshTask();

      // One bad refresh should not blank the screen for 20 seconds.
      expect(wallet.lifecycle, ['refresh', 'loadAllStats', 'store']);
    });

    test('a broken Tor requirement stops the cycle before anything happens', () async {
      await TorSettingsService.sharedInstance.save(torMode: TorMode.disabled);
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      await wallet.openExisting(password: 'pw');
      wallet.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: true);
      await wallet.connectToDaemon();
      expect(wallet.torRequirementBroken, isTrue);
      wallet.lifecycle.clear();

      await wallet.refreshTask();

      expect(wallet.lifecycle, isEmpty);
    });

    test('an inactive wallet is skipped', () async {
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      await wallet.refreshTask();
      expect(wallet.lifecycle, isEmpty);
    });
  });

  group('the connection task', () {
    test('it picks up a status change and reports it once', () async {
      final wallet = await readyWallet();
      wallet.setConnectedForTesting(false);
      wallet.connected = true;

      await wallet.checkConnectionTask();

      expect(wallet.isConnected, isTrue);
    });

    test('the networked probe is throttled while the sync poll is not', () async {
      final wallet = await readyWallet();
      wallet.setConnectedForTesting(true);

      // Three ticks inside one throttle window. The connectivity probe is a
      // network round trip; the sync poll is local and runs every tick so the
      // UI stays responsive.
      await wallet.checkConnectionTask();
      await wallet.checkConnectionTask();
      await wallet.checkConnectionTask();

      expect(wallet.pollSyncCount, 3);
      expect(wallet.getIsConnectedCount, 1);
    });
  });

  group('a throwing sync poll ends the only recovery path', () {
    // With `deferStatsUntilSynced` set, `refreshTask` loads no stats until
    // `_isSynced` flips, and the only thing that flips it is `pollSyncStatus`
    // on the connection tick. That makes the tick the single recovery path.

    test('the connection tick does not contain a throw from the sync poll', () async {
      final wallet = await readyWallet(of: _PollThrowsWallet('XMR'));

      // Nothing catches inside checkConnectionTask, so the throw reaches its
      // caller: the timer callback in `_scheduleConnectionCheck`, which
      // reschedules on the line after. A throw there ends the chain.
      await expectLater(wallet.checkConnectionTask(), throwsException);
    });

    test('the in-flight guard is released, so nothing looks stuck afterwards', () async {
      final wallet = await readyWallet(of: _PollThrowsWallet('XMR'));
      await expectLater(wallet.checkConnectionTask(), throwsException);

      // The `finally` clears the guard, so a manual tick still works; it is
      // only the timer chain that is gone.
      (wallet as _PollThrowsWallet).pollShouldThrow = false;
      await wallet.checkConnectionTask();
      expect(wallet.pollSyncCount, 1);
    });

    test('meanwhile the refresh timer loads no stats while unsynced', () async {
      final wallet = await readyWallet();
      wallet.deferStats = true;
      wallet.setSyncedForTesting(false);
      wallet.lifecycle.clear();

      // Three cycles of the only surviving timer: it checkpoints and returns.
      await wallet.refreshTask();
      await wallet.refreshTask();
      await wallet.refreshTask();

      expect(wallet.statsCount, 0, reason: 'deferred until the sync poll flips _isSynced');
    });
  });

  group('dispose', () {
    test('the timers stop, so a disposed wallet does no further work', () async {
      final wallet = FakeWallet('XMR');
      await wallet.openExisting(password: 'pw');
      wallet.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);
      wallet.connected = true;

      wallet.dispose();
      wallet.lifecycle.clear();

      // Skylight has no dispose at all, so its timers outlive the object and
      // keep touching a wallet the app has moved on from.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(wallet.lifecycle, isEmpty);
    });

    test('a connect still in flight when the wallet is disposed lands quietly', () async {
      final wallet = FakeWallet('XMR');
      await wallet.openExisting(password: 'pw');
      wallet.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);
      final gate = Completer<void>();
      wallet.connectGate = gate;

      // Cancelling the timers does not cancel what they already started. A
      // connect over Tor takes seconds, and the wallet can be disposed inside
      // that window; the app switches coins, or a background isolate ends.
      final pending = wallet.connectToDaemon();
      wallet.dispose();
      gate.complete();

      await expectLater(pending, completes);
    });

    test('a stats load still in flight when the wallet is disposed lands quietly', () async {
      final wallet = FakeWallet('XMR');
      await wallet.openExisting(password: 'pw');
      wallet.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);

      final pending = wallet.loadAllStats();
      wallet.dispose();

      await expectLater(pending, completes);
    });
  });
}
