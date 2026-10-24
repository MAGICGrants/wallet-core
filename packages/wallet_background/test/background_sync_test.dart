import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_background/wallet_background.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fake_background_wallet.dart';

/// Covers scheduling policy: which coins a wake-up window may touch, what it
/// refuses to open, and in what order.
///
/// Everything that reaches WorkManager or the foreground-service plugin is out
/// of reach under `flutter test` (no platform channels), so these stop at those
/// boundaries and assert the *decisions* rather than the plugin calls.

/// What a coin should look like this run. Not a wallet: [_Registry] builds a
/// fresh wallet from it per call, because that is what `CoinRegistry` requires.
class WalletSpec {
  const WalletSpec(
    this.symbol, {
    this.address = 'server.example.com:1234',
    this.type = '',
    this.tor = false,
    this.existing = true,
    this.connectThrows,
    this.historyThrows,
    this.synced = true,
    this.heightScript,
    this.viewOnly = true,
  });

  final String symbol;
  final String address;
  final String type;
  final bool tor;
  final bool existing;
  final Object? connectThrows;
  final Object? historyThrows;

  /// False puts the wallet in the wait loop instead of completing immediately.
  final bool synced;

  /// Heights the wait loop will see, one per poll. See
  /// [FakeBackgroundWallet.heightScript].
  final List<int>? heightScript;

  /// False: the coin's view-only material is not set up yet.
  final bool viewOnly;

  FakeBackgroundWallet build() =>
      FakeBackgroundWallet(
          symbol,
          address: address,
          type: type,
          tor: tor,
          existing: existing,
          connectThrows: connectThrows,
          historyThrows: historyThrows,
        )
        ..synced = synced
        ..hasViewOnly = viewOnly
        ..heightScript = heightScript == null ? null : [...heightScript!];
}

/// A `CoinRegistry` that hands out a **fresh generation of wallets per call**
/// and keeps every wallet it ever built, so a test can assert across all of
/// them.
///
/// The freshness is not a stylistic choice. `runTxNotifier` stands up a
/// throwaway probe manager to read persisted connections, disposes it, and then
/// builds the real manager over a second call to the registry. A fake that
/// returned one captured list hands the second manager already-disposed wallets
/// and everything throws on `addListener`, which is what happened when this
/// file was first written, and is why that requirement is now written on
/// `CoinRegistry` itself rather than only in the apps' own comments.
class _Registry {
  _Registry(this.specs);

  final List<WalletSpec> specs;
  final List<FakeBackgroundWallet> created = [];

  List<CryptoWallet> build() {
    final generation = [for (final spec in specs) spec.build()];
    created.addAll(generation);
    return generation;
  }

  Iterable<FakeBackgroundWallet> _of(String symbol) => created.where((w) => w.symbol == symbol);

  /// Summed across generations. The probe generation contributes zero to both,
  /// since it only ever reads persisted connections, so these count real work.
  int opens(String symbol) => _of(symbol).fold(0, (n, w) => n + w.openCount);
  int connects(String symbol) => _of(symbol).fold(0, (n, w) => n + w.connectCount);
  int histories(String symbol) => _of(symbol).fold(0, (n, w) => n + w.historyCount);

  /// The last wallet built for [symbol], the one the real manager used.
  FakeBackgroundWallet last(String symbol) => _of(symbol).last;
}

void main() {
  late Directory tmp;

  setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
  tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('wallet_background');
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
    WalletLog.sink = MemoryLogSink();
    WalletLog.isLoggingOn = () async => true;
    // A kept password is in the keystore, as on a phone with security keys
    // off, so the tests also show a background run never reads it: every run
    // opens view-only. Pinned to the mobile model, since the default follows
    // the test host, and Linux keeps no password there.
    WalletSecrets.holdsWalletPassword = true;
    await storeKeystoreWalletPassword('background-test-password');
    // Tor resolvable and instant. The default mode is `builtIn`, whose
    // `getProxy()` waits on a Tor daemon that never starts under `flutter test`
    //; every Tor case then failed on a 30-second timeout rather than on
    // anything about background sync. `external` models "Tor is up" with no
    // daemon; the fail-closed case gets its own test below.
    await TorSettingsService.sharedInstance.save(torMode: TorMode.external, socksPort: '9050');
    // A phone on the default Sync Frequency (Periodic); the host itself has no
    // background runs at all.
    syncFrequencyPlatform = 'android';
  });

  tearDown(() {
    syncFrequencyPlatform = Platform.operatingSystem;
    BackgroundSync.coins = () => const [];
    BackgroundSync.ensureTorConnected = null;
    WalletAppConfig.resetForTesting();
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
    TorSettingsService.sharedInstance.resetForTesting();
    WalletLog.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Installs [specs] and runs one pass with the wait loop skipped.
  ///
  /// `budget: Duration.zero` puts the deadline in the past, so the poll loop is
  /// never entered and the test spends no real seconds in `Future.delayed`.
  Future<_Registry> runPass(
    List<WalletSpec> specs, {
    bool allowTor = true,
    bool allowNode = true,
  }) async {
    final registry = _Registry(specs);
    BackgroundSync.coins = registry.build;
    await runTxNotifier(budget: Duration.zero, allowTor: allowTor, allowNode: allowNode);
    return registry;
  }

  /// Installs [specs] without running, for the `dispatchBackgroundTask` cases
  /// that choose the window themselves.
  _Registry install(List<WalletSpec> specs) {
    final registry = _Registry(specs);
    BackgroundSync.coins = registry.build;
    return registry;
  }

  // Every run without the user is view-only, keys or not: the kept password
  // stays in the keystore, unread.
  // One holder at a time: in one Android process a periodic run and the app
  // would be two writers on the same files.
  group('the periodic run and the app take turns', () {
    test('a run skips while the app holds the wallets', () async {
      final r = _Registry([const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')]);
      BackgroundSync.coins = r.build;
      expect(
        await runTxNotifier(budget: Duration.zero, anotherHolderHasWallets: () async => true),
        isTrue,
      );
      expect(r.opens('BTC'), 0);
      expect(r.opens('XMR'), 0);
      expect(IsolateNameServer.lookupPortByName(WalletHolders.periodicRunName), isNull);
    });

    test('a run that holds them lets go when the app claims them', () async {
      final r = _Registry([
        WalletSpec(
          'XMR',
          type: 'node',
          synced: false,
          heightScript: [for (var h = 1; h < 100000; h++) h],
        ),
      ]);
      BackgroundSync.coins = r.build;
      final run = runTxNotifier(
        budget: const Duration(seconds: 30),
        pollInterval: const Duration(milliseconds: 5),
        anotherHolderHasWallets: () async => false,
      );
      // The run registers itself and is scanning.
      while (r.opens('XMR') == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final answer = await WalletHolders.ask(
        WalletHolders.periodicRunName,
        SyncMessage.hello,
        timeout: const Duration(seconds: 10),
      );
      expect(answer, SyncMessage.released);
      expect(r.last('XMR').isLoaded, isFalse, reason: 'closed before the answer');
      expect(r.last('XMR').calls, contains('store'));
      expect(await run, isTrue);
      expect(IsolateNameServer.lookupPortByName(WalletHolders.periodicRunName), isNull);
    });

    test('asked while Tor starts: the run closes them without connecting', () async {
      final r = _Registry([const WalletSpec('BTC', tor: true)]);
      BackgroundSync.coins = r.build;
      Future<Object?>? answer;
      BackgroundSync.ensureTorConnected = () async {
        // The app asks while the run waits for Tor; the run answers once closed.
        answer = WalletHolders.ask(
          WalletHolders.periodicRunName,
          SyncMessage.hello,
          timeout: const Duration(seconds: 10),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return true;
      };
      expect(
        await runTxNotifier(
          budget: const Duration(seconds: 30),
          pollInterval: const Duration(milliseconds: 5),
          anotherHolderHasWallets: () async => false,
        ),
        isTrue,
      );
      expect(await answer, SyncMessage.released);
      expect(r.last('BTC').calls, isNot(contains('connectToDaemon')));
      expect(r.last('BTC').isLoaded, isFalse);
    });

    test('every run closes its wallets at the end: none outlives it in the process', () async {
      final r = await runPass([const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')]);
      expect(r.last('BTC').isLoaded, isFalse);
      expect(r.last('XMR').isLoaded, isFalse);
    });

    group('in a shared process (Android)', () {
      final ports = <ReceivePort>[];

      setUp(() => holdersShareProcess = true);

      tearDown(() {
        holdersShareProcess = Platform.isAndroid;
        WalletManager.closeOrphanedWallets = null;
        for (final name in [
          WalletHolders.appName,
          WalletHolders.serviceName,
          WalletHolders.periodicRunName,
        ]) {
          IsolateNameServer.removePortNameMapping(name);
        }
        for (final p in ports) {
          p.close();
        }
        ports.clear();
      });

      /// Registers a holder under [name] that answers whether it holds.
      void holder(String name, {required bool holds, String? token}) {
        final port = ReceivePort()
          ..listen(
            (m) => WalletHolders.answer(m, {'op': 'holds', 'holds': holds, 'token': ?token}),
          );
        ports.add(port);
        WalletHolders.register(name, port.sendPort);
      }

      test('a run skips while the Continuous Sync service holds the wallets', () async {
        holder(WalletHolders.serviceName, holds: true);
        final r = await runPass([const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')]);
        expect(r.opens('BTC'), 0);
        expect(r.opens('XMR'), 0);
      });

      /// Registers another periodic run under its shared name: it answers that
      /// it holds, and lets go when asked, recording the request.
      List<String> peerRun() {
        final asked = <String>[];
        final port = ReceivePort()
          ..listen((m) {
            final op = SyncMessage.opOf(m);
            if (op == null) return;
            asked.add(op);
            WalletHolders.answer(
              m,
              op == 'hello' ? SyncMessage.released : {'op': 'holds', 'holds': true},
            );
          });
        ports.add(port);
        WalletHolders.register(WalletHolders.periodicRunName, port.sendPort);
        return asked;
      }

      test('the light job skips while the full-scan job holds: that one checks them', () async {
        final asked = peerRun();
        final r = await runPass([const WalletSpec('BTC')], allowNode: false);
        expect(r.opens('BTC'), 0);
        expect(asked, ['holds?'], reason: 'it asked, and asked nothing to let go');
      });

      test('the full-scan job has a light run let go, then runs in its place', () async {
        final asked = peerRun();
        final r = await runPass([const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')]);
        expect(asked, ['holds?', 'hello']);
        expect(r.connects('BTC'), 1, reason: 'the light coins are checked here instead');
        expect(r.connects('XMR'), 1);
      });

      test('nobody holds them: what a destroyed app isolate left is closed first, '
          "sparing a live app's", () async {
        holder(WalletHolders.appName, holds: false, token: 'live-app');
        final spared = <String?>[];
        WalletManager.closeOrphanedWallets = ({exceptToken}) async => spared.add(exceptToken);

        final r = await runPass([const WalletSpec('BTC')]);
        expect(spared, ['live-app']);
        expect(r.opens('BTC'), 1);
      });
    });

    test('the service holds as a registered holder, and lets go on hello', () async {
      final r = install([const WalletSpec('BTC')]);
      final handler = BackgroundSyncTaskHandler();
      // The app answers that it holds nothing (its lock screen after a cold start).
      handler.onReceiveData(SyncMessage.pong(holds: false, synced: false, token: 'app'));
      while (r.opens('BTC') == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final answer = await WalletHolders.ask(
        WalletHolders.serviceName,
        WalletHolders.holdsQuery,
        timeout: const Duration(seconds: 5),
      );
      expect(answer, {'op': 'holds', 'holds': true});

      handler.onReceiveData(SyncMessage.hello);
      while (IsolateNameServer.lookupPortByName(WalletHolders.serviceName) != null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(r.last('BTC').isLoaded, isFalse);
    });

    test('nobody registered: a claim has nothing to wait for', () async {
      expect(
        await WalletHolders.ask(
          WalletHolders.periodicRunName,
          SyncMessage.hello,
          timeout: const Duration(milliseconds: 50),
        ),
        isNull,
      );
    });
  });

  group('view-only, whatever the configuration', () {
    test('a run never reads the kept wallet password', () async {
      final store = _CountingSecretStore();
      store.values.addAll((WalletSecrets.store as MemorySecretStore).values);
      WalletSecrets.store = store;

      final r = await runPass([const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')]);
      expect(r.opens('BTC'), 1);
      expect(r.opens('XMR'), 1);
      expect(r.last('XMR').calls, contains('openViewOnly'));
      expect(r.last('XMR').calls, isNot(contains('openExisting')));
      expect(store.reads, isNot(contains(walletPasswordStorageKey)));
    });

    test('a coin whose view-only material is not set up yet is skipped', () async {
      final r = await runPass([
        const WalletSpec('BTC'),
        const WalletSpec('XMR', type: 'node', viewOnly: false),
      ]);
      expect(r.opens('BTC'), 1);
      expect(r.opens('XMR'), 0);
    });

    test('the Continuous Sync service marks every coin before opening it', () {
      final r = install([const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')]);
      final coins = serviceCoins();
      expect(coins.every((w) => w.unattended), isTrue);
      expect(r.created.every((w) => w.markedUnattendedBeforeOpen), isTrue);
    });
  });

  group('which coins a window may sync', () {
    test('the default window syncs everything configured', () async {
      final r = await runPass([const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')]);
      expect(r.connects('BTC'), 1);
      expect(r.connects('XMR'), 1);
    });

    test('the short iOS refresh takes neither Tor nor a node', () async {
      // ~30s, whenever iOS feels like it. A Tor bootstrap can outlast the whole
      // window and a Monero node scan certainly can, so both are skipped;
      // otherwise the window is spent and iOS grows less willing to grant the
      // next one.
      final r = await runPass(
        [
          const WalletSpec('BTC'),
          const WalletSpec('ETH', tor: true),
          const WalletSpec('XMR', type: 'node'),
        ],
        allowTor: false,
        allowNode: false,
      );

      expect(r.connects('BTC'), 1);
      expect(r.connects('ETH'), 0, reason: 'a Tor bootstrap can outlast the window');
      expect(r.connects('XMR'), 0, reason: 'a node scan cannot finish in the window');
    });

    test('the charging processing window allows Tor but still not a node', () async {
      final r = await runPass([
        const WalletSpec('ETH', tor: true),
        const WalletSpec('XMR', type: 'node'),
      ], allowNode: false);

      expect(r.connects('ETH'), 1);
      expect(r.connects('XMR'), 0);
    });

    test('an unconfigured coin is never synced', () async {
      final r = await runPass([const WalletSpec('BTC', address: '')]);
      expect(r.connects('BTC'), 0);
    });

    test('a Monero wallet in LWS mode is not a node, so a short window takes it', () async {
      // The distinction is `connectionType`, not the coin. Skipping XMR wholesale
      // would drop the light-server case the window exists to serve.
      final r = await runPass(
        [const WalletSpec('XMR', type: 'lws')],
        allowTor: false,
        allowNode: false,
      );
      expect(r.connects('XMR'), 1);
    });
  });

  group('what a window refuses to pay for', () {
    test('a skipped coin never has its wallet file opened', () async {
      // The load-bearing claim in `runTxNotifier`'s own comment: the probe reads
      // persisted connections to decide, and only then opens the survivors.
      // Opening a Monero wallet is the expensive part, and a 25-second window
      // must not spend it on a coin it is about to skip.
      final r = await runPass(
        [const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')],
        allowTor: false,
        allowNode: false,
      );

      expect(r.opens('BTC'), 1);
      expect(r.opens('XMR'), 0, reason: 'the skipped coin must cost nothing to skip');
    });

    test('a run with nothing syncable opens no wallet at all', () async {
      final r = await runPass([const WalletSpec('XMR', type: 'node')], allowNode: false);
      expect(r.opens('XMR'), 0);
      expect(r.histories('XMR'), 0);
    });

    test('a run with no wallet files returns without opening anything', () async {
      final r = await runPass([const WalletSpec('BTC', existing: false)]);
      expect(r.opens('BTC'), 0);
    });
  });

  group('whether there is anything to schedule', () {
    // The scheduler asks `syncableCoins` before registering, so a task that
    // would only wake up, read the settings and exit is never registered.
    test('a node alone leaves the light job nothing', () async {
      install([const WalletSpec('XMR', type: 'node')]);
      expect(await syncableCoins(allowNode: false), isEmpty);
    });

    test('a node beside light coins leaves the light job those coins', () async {
      install([const WalletSpec('XMR', type: 'node'), const WalletSpec('BTC')]);
      expect(await syncableCoins(allowNode: false), {'BTC'});
    });

    test('a node is work for a window that allows a full scan', () async {
      install([const WalletSpec('XMR', type: 'node')]);
      expect(await syncableCoins(), {'XMR'});
    });

    test('the full-scan job is registered only for a coin that needs a full scan', () async {
      install([const WalletSpec('XMR', type: 'node'), const WalletSpec('BTC')]);
      expect(await syncableCoins(scansOnly: true), {'XMR'});
    });

    test('light coins alone give the full-scan job nothing', () async {
      install([const WalletSpec('XMR', type: 'lws'), const WalletSpec('BTC')]);
      expect(await syncableCoins(scansOnly: true), isEmpty);
    });

    test('no configured server leaves nothing', () async {
      install([const WalletSpec('BTC', address: ''), const WalletSpec('XMR', address: '')]);
      expect(await syncableCoins(), isEmpty);
    });

    test('no wallet files leaves nothing', () async {
      install([const WalletSpec('BTC', existing: false)]);
      expect(await syncableCoins(), isEmpty);
    });

    test('asking opens no wallet file', () async {
      // The scheduler asks from the app's own isolate, alongside its open
      // wallets; it must only ever read the persisted settings.
      final r = install([const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')]);
      await syncableCoins();
      expect(r.opens('BTC'), 0);
      expect(r.opens('XMR'), 0);
    });
  });

  group('ordering, because the isolate can be killed at any point', () {
    test('history is read, then the scan is checkpointed', () async {
      // If the checkpoint went first, everything scanned while reading history
      // would be lost on a kill; if the announcement went before the checkpoint,
      // a notification could be delivered for progress that was then thrown
      // away, and the next run would rescan and could announce it again.
      final r = await runPass([const WalletSpec('BTC')]);
      final calls = r.last('BTC').calls;

      final pause = calls.indexOf('pauseSync');
      expect(pause, isNot(-1), reason: 'the run must checkpoint at all');
      expect(calls.indexOf('loadTxHistory'), lessThan(pause));
    });

    test('the connection is restored before the daemon is contacted', () async {
      final calls = (await runPass([const WalletSpec('BTC')])).last('BTC').calls;
      expect(calls.indexOf('loadPersistedConnection'), lessThan(calls.indexOf('connectToDaemon')));
      expect(calls.indexOf('connectToDaemon'), lessThan(calls.indexOf('loadTxHistory')));
    });
  });

  group('one bad wallet does not take down the run', () {
    test('a server that will not connect leaves the others syncing', () async {
      final r = await runPass([
        const WalletSpec('BTC', connectThrows: SocketException('refused')),
        const WalletSpec('ETH'),
      ]);

      expect(r.connects('ETH'), 1);
      expect(r.histories('ETH'), 1, reason: 'the healthy wallet still finishes its pass');
    });

    test('a history read that throws does not skip the checkpoint', () async {
      // Losing the checkpoint would throw away every block scanned this window.
      final r = await runPass([WalletSpec('BTC', historyThrows: StateError('server hung up'))]);
      expect(r.last('BTC').calls, contains('pauseSync'));
    });
  });

  group('Tor is only brought up when something needs it', () {
    test('a clearnet-only run never asks the app for Tor', () async {
      var asked = 0;
      BackgroundSync.ensureTorConnected = () async {
        asked++;
        return true;
      };
      await runPass([const WalletSpec('BTC')]);
      expect(asked, 0, reason: 'starting Tor for nothing costs battery and time');
    });

    test('a Tor wallet in the window does ask', () async {
      var asked = 0;
      BackgroundSync.ensureTorConnected = () async {
        asked++;
        return true;
      };
      await runPass([const WalletSpec('BTC', tor: true)]);
      expect(asked, 1);
    });

    test('an app with no Tor at all is not a crash', () async {
      BackgroundSync.ensureTorConnected = null;
      await expectLater(runPass([const WalletSpec('BTC', tor: true)]), completes);
    });

    test('a Tor wallet does not fall back to clearnet when Tor is off', () async {
      // The fail-closed property, exercised end to end through a background
      // window rather than at the wallet in isolation. A background run has no
      // user watching, so a silent clearnet fallback here would deanonymise
      // someone who had done everything right.
      await TorSettingsService.sharedInstance.save(torMode: TorMode.disabled);

      final r = await runPass([const WalletSpec('BTC', tor: true)]);

      expect(r.connects('BTC'), 0, reason: 'no proxy must mean no connection at all');
    });

    test('a clearnet wallet is unaffected by Tor being off', () async {
      await TorSettingsService.sharedInstance.save(torMode: TorMode.disabled);
      final r = await runPass([const WalletSpec('BTC')]);
      expect(r.connects('BTC'), 1);
    });

    test('a wallet whose Tor never came up is skipped rather than tried anyway', () async {
      // KNOWN GAP. `runTxNotifier` awaits
      // `ensureTorConnected()` and discards the bool, so a wallet configured
      // for Tor is connected anyway when Tor failed to start. The transport
      // itself fails closed (pinned in wallet_monero), so this is a wasted
      // window rather than a leak, but the run reports success having synced
      // nothing, and the next window repeats it.
      //
      // Written now and skipped until the fix, so the gap is pinned by a test
      // rather than only described.
      var asked = 0;
      BackgroundSync.ensureTorConnected = () async {
        asked++;
        return false; // Tor did not come up
      };

      final r = await runPass([const WalletSpec('BTC', tor: true)]);

      expect(asked, 1);
      expect(r.connects('BTC'), 0, reason: 'no Tor means no sync for a Tor wallet');
    }, skip: 'known gap: the answer from ensureTorConnected is discarded');
  });

  group('dispatchBackgroundTask routes each window', () {
    test('the iOS refresh window skips Tor and node coins', () async {
      final r = install([
        const WalletSpec('ETH', tor: true),
        const WalletSpec('XMR', type: 'node'),
        const WalletSpec('BTC'),
      ]);

      await dispatchBackgroundTask(PeriodicTasks.iosRefresh);

      expect(r.connects('BTC'), 1);
      expect(r.connects('ETH'), 0);
      expect(r.connects('XMR'), 0);
    });

    test('the iOS processing window takes Tor and scans a node', () async {
      final r = install([
        const WalletSpec('ETH', tor: true),
        const WalletSpec('XMR', type: 'node'),
      ]);

      await dispatchBackgroundTask(PeriodicTasks.iosProcessing);

      expect(r.connects('ETH'), 1);
      expect(r.connects('XMR'), 1);
    });

    test('the Android light job checks light coins and leaves a node alone', () async {
      // It runs on any network; a node scan waits for the full-scan job, which
      // only runs while charging and on WiFi.
      final r = install([const WalletSpec('XMR', type: 'node'), const WalletSpec('BTC')]);

      await dispatchBackgroundTask(PeriodicTasks.txNotifier);

      expect(r.connects('XMR'), 0);
      expect(r.connects('BTC'), 1);
    });

    test('the Android full-scan job scans the node and checks the light coins too', () async {
      final r = install([const WalletSpec('XMR', type: 'node'), const WalletSpec('BTC')]);

      await dispatchBackgroundTask(PeriodicTasks.scan);

      expect(r.connects('XMR'), 1);
      expect(r.connects('BTC'), 1);
    });

    test('an unknown task is the light job, whose constraints any device meets', () async {
      // Builds before this one registered the light job as "Background sync".
      final r = install([const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')]);

      expect(await dispatchBackgroundTask('Background sync'), isTrue);
      expect(r.connects('BTC'), 1);
      expect(r.connects('XMR'), 0);
    });

    test('nothing runs unless Sync Frequency is Periodic', () async {
      // Changing the setting cancels the tasks, but one already handed to the
      // isolate can still arrive.
      for (final frequency in [SyncFrequency.off, SyncFrequency.continuous]) {
        await saveSyncFrequency(frequency);
        for (final task in [
          PeriodicTasks.txNotifier,
          PeriodicTasks.scan,
          PeriodicTasks.iosRefresh,
          PeriodicTasks.iosProcessing,
        ]) {
          final r = install([const WalletSpec('BTC'), const WalletSpec('XMR', type: 'node')]);
          expect(await dispatchBackgroundTask(task), isTrue);
          expect(r.opens('BTC') + r.opens('XMR'), 0, reason: '${frequency.name} / $task');
        }
      }
    });
  });

  group('BackgroundSync.install wires every seam', () {
    test('installs each field, and leaves Tor null when the app has none', () {
      var workmanager = 0;
      var foreground = 0;
      BackgroundSync.install(
        coins: () => const [],
        workmanagerCallback: () => workmanager++,
        foregroundCallback: () => foreground++,
        iosBundleId: 'org.example.wallet',
        foregroundTitle: 'Example',
      );

      expect(BackgroundSync.iosBundleId, 'org.example.wallet');
      expect(BackgroundSync.foregroundTitle, 'Example');
      expect(BackgroundSync.ensureTorConnected, isNull);

      // The callbacks are the isolate entry points; installing the wrong one is
      // a background isolate that bootstraps nothing.
      BackgroundSync.workmanagerCallback();
      BackgroundSync.foregroundCallback();
      expect(workmanager, 1);
      expect(foreground, 1);
    });
  });

  group('scheduling is a no-op away from mobile', () {
    // Desktop builds share this code, and every one of these reaches a plugin
    // with no desktop implementation; so a lost platform guard is a crash on
    // launch, not a subtle bug. `flutter test` runs on the host, which is
    // exactly where the guard has to hold.
    test('registration and foreground control do nothing on the host', () async {
      expect(Platform.isAndroid || Platform.isIOS, isFalse, reason: 'these run on the host');

      await expectLater(applyBackgroundTaskRegistration(), completes);
      await expectLater(registerPeriodicTasks(), completes);
      await expectLater(startForegroundSync(), completes);
      await expectLater(stopForegroundSync(), completes);
      await expectLater(startForegroundSyncIfEnabled(), completes);
      await expectLater(restartForegroundSyncIfRunning(), completes);
    });

    test('whatever Sync Frequency says', () async {
      await saveSyncFrequency(SyncFrequency.continuous);
      await SharedPreferencesService.set<bool>(SettingsKeys.notificationsEnabled, true);

      await expectLater(applyBackgroundTaskRegistration(), completes);
      await expectLater(startForegroundSyncIfEnabled(), completes);
    });
  });

  group('waiting, which is not the same shape for a scan and a check', () {
    /// One pass with a real (but instant) poll interval, so the wait loop is
    /// actually entered. Every other test in this file uses `Duration.zero` for
    /// the budget, which skips the loop entirely, which is why nothing pinned
    /// any of this until the two shapes were separated.
    Future<_Registry> runWaiting(List<WalletSpec> specs) async {
      final registry = _Registry(specs);
      BackgroundSync.coins = registry.build;
      await runTxNotifier(budget: const Duration(seconds: 30), pollInterval: Duration.zero);
      return registry;
    }

    test('a check is on a plain timeout — its height is never consulted', () async {
      // The distinction that one combined counter could not express. A check has
      // no progress signal at this granularity: the server already scanned, and
      // the wallet's height moves only when its own ~20-second cycle reloads
      // stats, whether or not the check is getting anywhere. So watching the
      // height for a check is watching the wrong thing.
      final registry = await runWaiting([const WalletSpec('BTC', synced: false)]);

      expect(registry.last('BTC').heightReads, 0);
    });

    test('a scan that keeps advancing is never given up on', () async {
      // Forty polls of movement, well past the check budget. A scan does
      // advertise progress, so its counter resets on it, and the run has to keep
      // waiting for as long as blocks keep arriving.
      final registry = await runWaiting([
        WalletSpec(
          'XMR',
          type: 'node',
          synced: false,
          heightScript: List.generate(40, (i) => 100 + i),
        ),
      ]);

      expect(registry.last('XMR').heightReads, greaterThan(40));
    });

    test('a working scan no longer keeps a dead server in the wait set', () async {
      // The old counter reset on *any* wallet's progress, so a live Monero scan
      // held an unreachable Electrum server in the set for the entire budget.
      final registry = await runWaiting([
        const WalletSpec('BTC', synced: false),
        WalletSpec(
          'XMR',
          type: 'node',
          synced: false,
          heightScript: List.generate(40, (i) => 100 + i),
        ),
      ]);

      // The scan is still being polled long after the check was dropped, and the
      // check's height was never the thing being watched.
      expect(registry.last('XMR').heightReads, greaterThan(40));
      expect(registry.last('BTC').heightReads, 0);
    });

    test('a synced wallet is never waited on', () async {
      final registry = await runWaiting([const WalletSpec('BTC')]);

      // One read to notice, and out. The loop's first act is the completion
      // check, so a caught-up wallet costs a single pass.
      expect(registry.last('BTC').heightReads, lessThanOrEqualTo(1));
    });
  });

  group('isWalletFullySynced', () {
    test('needs a real height, not just the synced flag', () {
      // LWS reports height 0 in the window just after open while `isSynced` is
      // already true. Trusting the flag alone shows "up to date" over a wallet
      // that has scanned nothing.
      final w = FakeBackgroundWallet('BTC')
        ..connected = true
        ..synced = true
        ..height = 0;
      addTearDown(w.dispose);
      expect(isWalletFullySynced(w), isFalse);

      w.height = 1;
      expect(isWalletFullySynced(w), isTrue);
    });

    test('a null height is not synced', () {
      final w = FakeBackgroundWallet('BTC')..height = null;
      addTearDown(w.dispose);
      expect(isWalletFullySynced(w), isFalse);
    });

    test('disconnected or unsynced is not fully synced whatever the height', () {
      final disconnected = FakeBackgroundWallet('BTC')..connected = false;
      addTearDown(disconnected.dispose);
      expect(isWalletFullySynced(disconnected), isFalse);

      final unsynced = FakeBackgroundWallet('BTC')..synced = false;
      addTearDown(unsynced.dispose);
      expect(isWalletFullySynced(unsynced), isFalse);
    });
  });

  group('migrateSyncSettings', () {
    test('an install with a wallet and every old toggle off stays off', () async {
      install([const WalletSpec('XMR', type: 'node')]);
      await SharedPreferencesService.set<bool>('backgroundSyncEnabled', false);
      await migrateSyncSettings();
      expect(await loadSyncFrequency(), SyncFrequency.off);
    });

    test('an install with no wallet yet gets the default, Periodic', () async {
      final r = install([const WalletSpec('XMR', existing: false)]);
      await migrateSyncSettings();
      expect(await loadSyncFrequency(), SyncFrequency.periodic);
      expect(r.opens('XMR'), 0, reason: 'it reads the files, it opens none');
    });
  });

  group('stopSyncAndDeleteWallets', () {
    // The plugin calls (stopService, WorkManager cancel) are out of reach here,
    // as everywhere else in this file; what is reachable is the decision that
    // outlives the tap. Settings go back to a fresh install's: Sync Frequency
    // written down as Periodic, so the next launch's migration cannot read the
    // empty install as "existing, everything off", and notifications off.
    test('resets the sync settings and deletes the wallets', () async {
      await saveSyncFrequency(SyncFrequency.continuous);
      await SharedPreferencesService.set<bool>(SettingsKeys.notificationsEnabled, true);

      final registry = _Registry([const WalletSpec('XMR'), const WalletSpec('BTC')]);
      final manager = WalletManager(coins: registry.build);
      addTearDown(manager.dispose);

      await stopSyncAndDeleteWallets(manager);

      expect(
        await SharedPreferencesService.get<String>(SettingsKeys.syncFrequency),
        SyncFrequency.periodic.name,
      );
      expect(await SharedPreferencesService.get<bool>(SettingsKeys.notificationsEnabled), isFalse);
      expect(registry.last('XMR').deleteFilesCount, 1);
      expect(registry.last('BTC').deleteFilesCount, 1);
    });

    test('passes the app\'s own pref keys through to deleteAll', () async {
      await SharedPreferencesService.set<String>('skylight_contacts', 'x');

      final registry = _Registry([const WalletSpec('XMR')]);
      final manager = WalletManager(coins: registry.build);
      addTearDown(manager.dispose);

      await stopSyncAndDeleteWallets(manager, extraPrefKeys: ['skylight_contacts']);

      expect(await SharedPreferencesService.get<String>('skylight_contacts'), isNull);
    });
  });
}

/// Records which keys were read, to show a run never asks for the password.
class _CountingSecretStore extends MemorySecretStore {
  final List<String> reads = [];

  @override
  Future<String?> read(String key) {
    reads.add(key);
    return super.read(key);
  }
}
