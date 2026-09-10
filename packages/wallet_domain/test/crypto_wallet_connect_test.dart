import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_wallet.dart';

/// The `CryptoWallet` connection state machine; the merge of Spice's in-flight
/// dedup and fail-closed Tor with Skylight's failure counter and backoff
/// (`connectToDaemon` and `_retryConnectIfDue`).
///
/// Both are rows the phase order says to test *before* merging, and neither had
/// a test. `torRequirementBroken` in particular had no assertion anywhere in the
/// repo, and it is the one piece of this class whose failure mode is a privacy
/// breach rather than a stall: a wallet configured for Tor that quietly connects
/// in the clear tells the operator of that node who is asking.

/// A coin whose connect needs only the persisted settings, so the manager may
/// run it before the wallet file is open.
class _EarlyConnectWallet extends FakeWallet {
  _EarlyConnectWallet(super.symbol);

  @override
  bool get canConnectBeforeOpen => true;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('connect');
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

  /// A wallet that is open and configured, which is what `isActive` requires
  /// before any connect is attempted.
  Future<FakeWallet> readyWallet({bool useTor = false, String proxyPort = ''}) async {
    final wallet = FakeWallet('XMR');
    addTearDown(wallet.dispose);
    await wallet.openExisting(password: 'pw');
    wallet.setConnection(address: 'node.example.com:18081', proxyPort: proxyPort, useTor: useTor);
    return wallet;
  }

  /// Turns Tor off at the settings layer, so `getProxy()` returns null without
  /// needing the Tor plugin. This is the "useTor set, no Tor available" state.
  Future<void> torUnavailable() =>
      TorSettingsService.sharedInstance.save(torMode: TorMode.disabled);

  /// An external SOCKS proxy on [port], resolvable with no plugin.
  Future<void> torOnPort(String port) =>
      TorSettingsService.sharedInstance.save(torMode: TorMode.external, socksPort: port);

  group('fail closed when Tor is required and missing', () {
    test('no clearnet attempt is made at all', () async {
      await torUnavailable();
      final wallet = await readyWallet(useTor: true);

      await wallet.connectToDaemon();

      // The assertion that matters is the empty list. `isConnected == false`
      // would also hold if the request had gone out and been refused, and by
      // then the node operator has already seen the user's IP.
      expect(wallet.connectCalls, isEmpty, reason: 'a Tor wallet must never reach the network');
      expect(wallet.torRequirementBroken, isTrue);
      expect(wallet.isConnected, isFalse);
    });

    test('a broken Tor requirement also blocks the refresh cycle', () async {
      await torUnavailable();
      final wallet = await readyWallet(useTor: true);
      await wallet.connectToDaemon();

      // Reconnecting is where the leak would come back: the connect path fails
      // closed, and then a timer helpfully retries it.
      expect(wallet.isReconnectDue(DateTime.now().add(const Duration(hours: 1))), isFalse);
      expect(wallet.connectCalls, isEmpty);
    });

    test('reconfiguring the connection is the way out of the broken state', () async {
      await torUnavailable();
      final wallet = await readyWallet(useTor: true);
      await wallet.connectToDaemon();
      expect(wallet.torRequirementBroken, isTrue);

      // The user turns Tor off for this connection. That is a deliberate act,
      // and it clears the flag; nothing else does.
      wallet.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);
      expect(wallet.torRequirementBroken, isFalse);

      wallet.connected = true;
      await wallet.connectToDaemon();
      expect(wallet.connectCalls, hasLength(1));
    });

    test('onGlobalTorDisabled breaks a Tor connection and is idempotent', () async {
      await torOnPort('9150');
      final wallet = await readyWallet(useTor: true);
      wallet.connected = true;
      await wallet.connectToDaemon();
      expect(wallet.isConnected, isTrue);

      wallet.onGlobalTorDisabled();
      expect(wallet.torRequirementBroken, isTrue);
      expect(wallet.isConnected, isFalse);

      // Called again (from a second listener, say) it must not toggle back.
      wallet.onGlobalTorDisabled();
      expect(wallet.torRequirementBroken, isTrue);
    });

    test('a clearnet connection is untouched by global Tor being switched off', () async {
      final wallet = await readyWallet();
      wallet.connected = true;
      await wallet.connectToDaemon();

      wallet.onGlobalTorDisabled();

      expect(wallet.torRequirementBroken, isFalse);
      expect(wallet.isConnected, isTrue);
    });
  });

  group('the proxy the connect actually uses', () {
    test('Tor supplies the port, overriding whatever was configured', () async {
      await torOnPort('9150');
      // A stale custom proxy port is still on the connection.
      final wallet = await readyWallet(useTor: true, proxyPort: '1080');

      await wallet.connectToDaemon();

      expect(wallet.connectCalls.single.proxyPort, '9150');
    });

    test('without Tor the configured proxy port is passed through', () async {
      final wallet = await readyWallet(proxyPort: '1080');

      await wallet.connectToDaemon();

      expect(wallet.connectCalls.single.proxyPort, '1080');
      expect(wallet.connectCalls.single.address, 'node.example.com:18081');
    });
  });

  group('connect preconditions and dedup', () {
    test('two concurrent connects make one call', () async {
      final wallet = await readyWallet();
      final gate = Completer<void>();
      wallet.connectGate = gate;

      final first = wallet.connectToDaemon();
      final second = wallet.connectToDaemon();
      gate.complete();
      await Future.wait([first, second]);

      // Over Tor a connect takes seconds; two in flight means two circuits and
      // two sync loops racing on the same wallet.
      expect(wallet.connectCalls, hasLength(1));
    });

    test('a connect after the first finishes is a new attempt, not a replay', () async {
      final wallet = await readyWallet();

      await wallet.connectToDaemon();
      await wallet.connectToDaemon();

      expect(wallet.connectCalls, hasLength(2));
    });

    test('an unopened wallet is a silent no-op, and does not reach the network', () async {
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      wallet.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);

      // Configured but never opened. Spice carries a `throw` for this case
      // behind an `isActive` check that already excludes it, so the throw
      // cannot fire; the observable behaviour is, and always was, a quiet
      // return. Stated here so the dead guard is not "restored" later as a fix.
      await wallet.connectToDaemon();

      expect(wallet.connectCalls, isEmpty);
      expect(wallet.isConnected, isFalse);
    });

    test('an unconfigured wallet is a no-op, not an error', () async {
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);
      await wallet.openExisting(password: 'pw');

      // No server set: nothing to connect to, and nothing to complain about.
      await wallet.connectToDaemon();
      expect(wallet.connectCalls, isEmpty);
    });

    test('connectBeforeOpen does nothing unless the coin allows it', () async {
      final monero = FakeWallet('XMR');
      addTearDown(monero.dispose);
      monero.setConnection(address: 'node.example.com:18081', proxyPort: '', useTor: false);
      await monero.connectBeforeOpen();
      expect(monero.connectCalls, isEmpty, reason: 'Monero connect touches the open wallet object');

      final early = _EarlyConnectWallet('BTC');
      addTearDown(early.dispose);
      early.setConnection(address: 'electrum.example.com:50002', proxyPort: '', useTor: false);
      await early.connectBeforeOpen();
      expect(early.connectCalls, hasLength(1), reason: 'runs in parallel with openExisting');
    });

    test('a throwing impl surfaces rather than reporting connected', () async {
      final wallet = await readyWallet();
      wallet.connectError = Exception('refused');

      await expectLater(wallet.connectToDaemon(), throwsA(isA<Exception>()));
      expect(wallet.isConnected, isFalse);
    });

    test('an impl that returns while the server stays silent is not connected', () async {
      final wallet = await readyWallet();
      // Nothing threw, but `getIsConnected` says no. Treating "the call
      // returned" as success is how a wallet sits on a dead node forever.
      wallet.connected = false;

      await wallet.connectToDaemon();

      expect(wallet.connectCalls, hasLength(1));
      expect(wallet.isConnected, isFalse);
    });
  });

  group('the reconnect backoff', () {
    test('a wallet that has never tried is due immediately', () async {
      final wallet = await readyWallet();
      expect(wallet.isReconnectDue(DateTime.now()), isTrue);
    });

    test('the delay grows with consecutive failures', () async {
      final wallet = await readyWallet();

      final t0 = DateTime.now();
      await wallet.connectToDaemon(); // failure 1 ⇒ 2s
      expect(wallet.isReconnectDue(t0.add(const Duration(milliseconds: 1900))), isFalse);
      expect(wallet.isReconnectDue(t0.add(const Duration(seconds: 3))), isTrue);

      final t1 = DateTime.now();
      await wallet.connectToDaemon(); // failure 2 ⇒ 5s
      expect(wallet.isReconnectDue(t1.add(const Duration(seconds: 3))), isFalse);
      expect(wallet.isReconnectDue(t1.add(const Duration(seconds: 6))), isTrue);
    });

    test('the schedule is bounded, so a long outage keeps retrying', () async {
      final wallet = await readyWallet();

      final t = DateTime.now();
      for (var i = 0; i < 8; i++) {
        await wallet.connectToDaemon();
      }

      // Past the end of the table it clamps at 20s rather than growing without
      // limit; a wallet that has been offline all night still comes back
      // promptly when the network does.
      expect(wallet.isReconnectDue(t.add(const Duration(seconds: 19))), isFalse);
      expect(wallet.isReconnectDue(t.add(const Duration(seconds: 21))), isTrue);
    });

    test('a success resets the delay', () async {
      final wallet = await readyWallet();
      await wallet.connectToDaemon();
      await wallet.connectToDaemon(); // 2 failures ⇒ next wait 5s

      wallet.connected = true;
      await wallet.connectToDaemon(); // success ⇒ counter back to zero
      wallet.connected = false;

      final t = DateTime.now();
      await wallet.connectToDaemon(); // failure 1 again ⇒ 2s, not 5s
      expect(wallet.isReconnectDue(t.add(const Duration(seconds: 3))), isTrue);
    });

    test('a connected wallet is never due', () async {
      final wallet = await readyWallet();
      wallet.connected = true;
      await wallet.connectToDaemon();

      expect(wallet.isConnected, isTrue);
      expect(wallet.isReconnectDue(DateTime.now().add(const Duration(hours: 1))), isFalse);
    });

    test('an in-flight connect is not overlapped by a retry', () async {
      final wallet = await readyWallet();
      final gate = Completer<void>();
      wallet.connectGate = gate;

      final pending = wallet.connectToDaemon();
      expect(wallet.isReconnectDue(DateTime.now().add(const Duration(hours: 1))), isFalse);

      gate.complete();
      await pending;
    });
  });

  group('setIsLoaded(false) clears every derived field', () {
    test('nothing from the previous wallet survives', () async {
      final wallet = await readyWallet();
      wallet.connected = true;
      await wallet.connectToDaemon();
      wallet.history = [
        TxDetails(
          index: 0,
          direction: txDirectionIncoming,
          hash: 'h',
          amountBaseUnits: BigInt.from(7),
          feeBaseUnits: BigInt.zero,
          recipients: const [],
          accountIndex: 0,
          subaddrIndexList: const [0],
          timestamp: 1000,
          height: 10,
          confirmations: 1,
          key: '',
        ),
      ];
      await wallet.loadTxHistory(persistCount: false);
      expect(wallet.txHistory, isNotEmpty);
      expect(wallet.isConnected, isTrue);

      wallet.setIsLoadedForTesting(false);

      // A stale balance or history on screen after the wallet closed is not a
      // cosmetic bug; it is the previous wallet's data under a new one.
      expect(wallet.isLoaded, isFalse);
      expect(wallet.isConnected, isFalse);
      expect(wallet.txHistory, isEmpty);
      expect(wallet.totalBalanceBaseUnits, isNull);
      expect(wallet.unlockedBalanceBaseUnits, isNull);
      expect(wallet.syncedHeight, isNull);
      expect(wallet.isSynced, isFalse);
    });
  });

  group('setConnection', () {
    test('clears stale sync state so a fresh connection does not lag a poll', () async {
      final wallet = await readyWallet();
      wallet.setSyncedForTesting(true);
      wallet.setSyncedHeightForTesting(1234);
      expect(wallet.isSynced, isTrue);

      // Pointing at a new server: it has not been synced to yet, so the status
      // must not keep claiming synced; that backs the connectivity poll off to
      // its slow cadence and makes "connected" show up a cycle late.
      wallet.setConnection(address: 'other.example.com:18081', proxyPort: '', useTor: false);

      expect(wallet.isSynced, isFalse);
      expect(wallet.syncedHeight, isNull);
    });
  });

  group('pauseSyncAndStore', () {
    test('an open wallet pauses its scan and checkpoints', () async {
      final wallet = await readyWallet();

      await wallet.pauseSyncAndStore();

      expect(wallet.pauseCount, 1);
      expect(wallet.storeCount, 1);
    });

    test('a wallet that was never opened does neither', () async {
      final wallet = FakeWallet('XMR');
      addTearDown(wallet.dispose);

      // A background task can run against a wallet the user never unlocked.
      // Storing one that has no native wallet behind it is at best a no-op and
      // at worst writes an empty file over a real one.
      await wallet.pauseSyncAndStore();

      expect(wallet.pauseCount, 0);
      expect(wallet.storeCount, 0);
    });
  });
}
