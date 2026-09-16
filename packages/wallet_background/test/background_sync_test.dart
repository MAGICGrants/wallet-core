import 'dart:io';

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
    WalletLog.isVerbose = () async => true;
    // `runTxNotifier` opens with no password argument, so it depends on the
    // mobile password already being in the keystore, which is the real shape: a
    // background isolate has no user to ask.
    await storeMobileWalletPassword('background-test-password');
    // Tor resolvable and instant. The default mode is `builtIn`, whose
    // `getProxy()` waits on a Tor daemon that never starts under `flutter test`
    //; every Tor case then failed on a 30-second timeout rather than on
    // anything about background sync. `external` models "Tor is up" with no
    // daemon; the fail-closed case gets its own test below.
    await TorSettingsService.sharedInstance.save(torMode: TorMode.external, socksPort: '9050');
  });

  tearDown(() {
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

    test(
      'a wallet whose Tor never came up is skipped rather than tried anyway',
      () async {
        // KNOWN GAP. `runTxNotifier` awaits
        // `ensureTorConnected()` and discards the bool, so a wallet configured
        // for Tor is connected anyway when Tor failed to start. The transport
        // itself fails closed (pinned in wallet_monero), so this is a wasted
        // window rather than a leak, but the run reports success having synced
        // nothing, and the next window repeats it.
        //
        // Written now and skipped until the fix, so the finding is executable
        // rather than prose in a report.
        var asked = 0;
        BackgroundSync.ensureTorConnected = () async {
          asked++;
          return false; // Tor did not come up
        };

        final r = await runPass([const WalletSpec('BTC', tor: true)]);

        expect(asked, 1);
        expect(r.connects('BTC'), 0, reason: 'no Tor means no sync for a Tor wallet');
      },
      skip: 'M-14/L-15: the answer from ensureTorConnected is discarded',
    );
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

    test('the iOS processing window takes Tor but not a node', () async {
      final r = install([
        const WalletSpec('ETH', tor: true),
        const WalletSpec('XMR', type: 'node'),
      ]);

      await dispatchBackgroundTask(PeriodicTasks.iosProcessing);

      expect(r.connects('ETH'), 1);
      expect(r.connects('XMR'), 0);
    });

    test('with background sync off, a node is not scanned but light coins still are', () async {
      // The toggle gates the *heavy* work only: notifications from an LWS or
      // Electrum server cost almost nothing and stay on the notifications
      // setting alone.
      await SharedPreferencesService.set<bool>(SettingsKeys.backgroundSyncEnabled, false);
      final r = install([const WalletSpec('XMR', type: 'node'), const WalletSpec('BTC')]);

      await dispatchBackgroundTask(PeriodicTasks.txNotifier);

      expect(r.connects('XMR'), 0);
      expect(r.connects('BTC'), 1);
    });

    test('with background sync on, the node is scanned', () async {
      await SharedPreferencesService.set<bool>(SettingsKeys.backgroundSyncEnabled, true);
      final r = install([const WalletSpec('XMR', type: 'node')]);

      await dispatchBackgroundTask(PeriodicTasks.txNotifier);

      expect(r.connects('XMR'), 1);
    });

    test('an unknown task falls through to the full window rather than doing nothing', () async {
      await SharedPreferencesService.set<bool>(SettingsKeys.backgroundSyncEnabled, true);
      final r = install([const WalletSpec('BTC')]);

      expect(await dispatchBackgroundTask('something-else-entirely'), isTrue);
      expect(r.connects('BTC'), 1);
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
    });

    test('even with every toggle on', () async {
      await SharedPreferencesService.set<bool>(SettingsKeys.backgroundSyncEnabled, true);
      await SharedPreferencesService.set<bool>(SettingsKeys.notificationsEnabled, true);
      await SharedPreferencesService.set<bool>(SettingsKeys.foregroundSyncEnabled, true);

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

  group('stopSyncAndDeleteWallets', () {
    // The plugin calls (stopService, WorkManager cancel) are out of reach here,
    // as everywhere else in this file; what is reachable is the decision that
    // outlives the tap. Leaving these three set is what re-registers the
    // background task on the next launch, so a deleted wallet would keep waking
    // the device to find out it has nothing to sync.
    test('clears the sync preferences and deletes the wallets', () async {
      for (final key in [
        SettingsKeys.backgroundSyncEnabled,
        SettingsKeys.foregroundSyncEnabled,
        SettingsKeys.notificationsEnabled,
      ]) {
        await SharedPreferencesService.set<bool>(key, true);
      }

      final registry = _Registry([const WalletSpec('XMR'), const WalletSpec('BTC')]);
      final manager = WalletManager(coins: registry.build);
      addTearDown(manager.dispose);

      await stopSyncAndDeleteWallets(manager);

      for (final key in [
        SettingsKeys.backgroundSyncEnabled,
        SettingsKeys.foregroundSyncEnabled,
        SettingsKeys.notificationsEnabled,
      ]) {
        expect(await SharedPreferencesService.get<bool>(key), isFalse, reason: key);
      }
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
