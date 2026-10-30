import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_foreground_task/flutter_foreground_task.dart' show NotificationIcon;
import 'package:wallet_domain/wallet_domain.dart'
    show BackgroundSyncMode, CoinRegistry, CryptoWallet, WalletManager;
import 'package:wallet_infra/wallet_infra.dart';
import 'package:workmanager/workmanager.dart';

import 'sync_handoff.dart' show SyncMessage;
import 'wallet_holders.dart';

/// Brings the app's Tor up and waits for it; `true` once connected. The apps run
/// their own `TorService` (the one the wallet connects through), so the core
/// can't own Tor, so it asks the app.
typedef TorConnector = Future<bool> Function();

/// App-provided seams for background sync, installed from the app's wallet-core
/// bootstrap. That bootstrap runs in **every** isolate (statics don't cross
/// isolate boundaries), so these are re-established each time a background task
/// or the foreground service spins up.
class BackgroundSync {
  const BackgroundSync._();

  /// The wallets to sync; the same factory the app hands [WalletManager].
  static CoinRegistry coins = () => const [];

  /// null when the app has no Tor; a Tor wallet is then skipped for the window.
  static TorConnector? ensureTorConnected;

  /// iOS bundle id; the two BGTaskScheduler ids derive from it and must match
  /// `Info.plist` + `AppDelegate`.
  static String iosBundleId = '';

  /// Android foreground-service notification title.
  static String foregroundTitle = 'Wallet';

  /// Android foreground-service small icon. null → the plugin falls back to the
  /// app launcher icon. Points at a manifest `<meta-data>` naming a drawable.
  static NotificationIcon? foregroundIcon;

  /// The app's WorkManager callback; a top-level `@pragma('vm:entry-point')`
  /// that bootstraps the isolate then calls [dispatchBackgroundTask].
  static void Function() workmanagerCallback = () {};

  /// The app's foreground-service callback (same entry rules).
  static void Function() foregroundCallback = () {};

  static void install({
    required CoinRegistry coins,
    required void Function() workmanagerCallback,
    required void Function() foregroundCallback,
    TorConnector? ensureTorConnected,
    String iosBundleId = '',
    String foregroundTitle = 'Wallet',
    NotificationIcon? foregroundIcon,
  }) {
    BackgroundSync.coins = coins;
    BackgroundSync.workmanagerCallback = workmanagerCallback;
    BackgroundSync.foregroundCallback = foregroundCallback;
    BackgroundSync.ensureTorConnected = ensureTorConnected;
    BackgroundSync.iosBundleId = iosBundleId;
    BackgroundSync.foregroundTitle = foregroundTitle;
    BackgroundSync.foregroundIcon = foregroundIcon;
  }
}

class PeriodicTasks {
  /// Android's light job: checks the coins a server already scanned (Bitcoin,
  /// Ethereum, Monero on a light-wallet server), on any network.
  static const txNotifier = 'txNotifier';

  /// Android's full-scan job: everything [txNotifier] checks plus a full scan
  /// (a Monero node), only while charging and on WiFi.
  static const scan = 'scan';

  /// iOS BGAppRefreshTask: opportunistic, ~30s, iOS decides when. Only light
  /// clearnet wallets can do anything useful in it.
  static const iosRefresh = 'refresh';

  /// iOS BGProcessingTask: minutes, while charging and idle, so there is room
  /// for a Tor bootstrap and a full scan (a Monero node).
  static const iosProcessing = 'processing';
}

/// Identifiers must match BGTaskSchedulerPermittedIdentifiers in Info.plist and
/// the registrations in AppDelegate.
String get _iosRefreshTaskId => '${BackgroundSync.iosBundleId}.${PeriodicTasks.iosRefresh}';
String get _iosProcessingTaskId => '${BackgroundSync.iosBundleId}.${PeriodicTasks.iosProcessing}';

/// Max wall-clock we let a background run scan before returning, leaving margin
/// under Android's ~10-minute WorkManager budget to persist + notify.
const _backgroundSyncBudget = Duration(minutes: 9);

/// What an iOS BGAppRefreshTask gets is short and not negotiable; overrunning it
/// makes iOS schedule the next one less willingly.
const _iosRefreshBudget = Duration(seconds: 25);

/// How often a background run checks on the work it is waiting for.
const _backgroundSyncPollInterval = Duration(seconds: 5);

/// Consecutive polls with **no height movement** before a scan is given up on.
///
/// A scan advertises progress directly: wallet2's scanned height jumps at every
/// `/getblocks.bin` batch boundary, so a completely static height means a dead
/// node, a stalled thread or a lost circuit.
///
/// Purposefully generous. Tor can be slow and we don't want to kill working
/// connections prematurely.
const _scanStuckPolls = 12;

/// Polls a **check** is given to report at all, before the run stops waiting.
///
/// Separate from the scan counter because it counts something different. A check
/// has no progress signal: the server already scanned, and the wallet's height
/// only moves when its own ~20-second refresh reloads stats, whether or not the
/// check is making headway. So this is a plain timeout, not a stall detector.
///
/// One shared counter can't do both jobs. It reset on any wallet's progress, so
/// a live Monero scan kept a dead Electrum server in the wait set for the full
/// budget.
const _checkPollBudget = 12;

/// WorkManager's minimum periodic interval.
const _minSyncIntervalMinutes = 15;

/// One background pass. [budget] is the wall-clock it may use; [allowTor] and
/// [allowNode] say what the scheduling window can accommodate; a ~30s iOS
/// refresh can carry neither a Tor bootstrap nor a Monero node scan. They are
/// re-checked here, not trusted from the scheduler, because iOS can deliver a
/// task scheduled under a connection the user has since changed.
///
/// The caller's isolate must already be bootstrapped (the app's `@pragma` entry
/// installs wallet-core before delegating here).
///
/// [pollInterval] is for tests. The wait loop is where a scan's and a check's
/// progress rules live, and a unit test can't wait five real seconds per poll.
///
/// One holder at a time ([WalletHolders]): a run skips while the app or the
/// Continuous Sync service holds the wallets (it syncs and announces them
/// itself), and one that holds them lets go when another is about to open
/// them: it stops waiting, stores, closes and says so. Every run closes its
/// wallets at the end, so none is left open in a process that outlives it.
/// [anotherHolderHasWallets] is for tests; on Android it asks the app and the
/// service.
Future<bool> runTxNotifier({
  Duration budget = _backgroundSyncBudget,
  bool allowTor = true,
  bool allowNode = true,
  Duration pollInterval = _backgroundSyncPollInterval,
  @visibleForTesting Future<bool> Function()? anotherHolderHasWallets,
}) async {
  // Android's two jobs share a process and one name to answer on, so they
  // take turns. The full-scan job also checks every light coin, so a light run
  // that finds it holding has nothing left to do; the full-scan job asks a
  // light run to let go, as the app does, and carries on in its place.
  if (holdersShareProcess && await _peerRunHolds()) {
    if (!allowNode) {
      log(LogLevel.info, '[Background sync] the full-scan run holds the wallets; it checks these.');
      return true;
    }
    await WalletHolders.ask(
      WalletHolders.periodicRunName,
      SyncMessage.hello,
      timeout: const Duration(minutes: 1),
    );
  }

  // Registered before the app is asked, so an app that claims the wallets
  // right after answering finds this run and waits for it.
  final release = _ReleaseRequest();
  WalletHolders.register(WalletHolders.periodicRunName, release.port.sendPort);
  try {
    if (await (anotherHolderHasWallets ?? _askOtherHolders)()) {
      log(LogLevel.info, '[Background sync] the wallets are held; their holder syncs them.');
      return true;
    }
    return await _runTxNotifier(
      budget: budget,
      allowTor: allowTor,
      allowNode: allowNode,
      pollInterval: pollInterval,
      release: release,
    );
  } finally {
    WalletHolders.unregister(WalletHolders.periodicRunName, release.port.sendPort);
    // Asked after the run let go of everything, before it opened anything, or
    // after its last store, with every scan paused.
    release.answerIfAsked();
    release.port.close();
  }
}

/// Whether the app, the Continuous Sync service and a periodic run share a
/// process, so that they must take turns: Android. Replaced in tests.
@visibleForTesting
bool holdersShareProcess = Platform.isAndroid;

/// Whether the app (its wallets open, with the keys or view-only) or the
/// Continuous Sync service holds the wallets. Android only, where they share
/// the process; one that does not answer within two seconds has gone. When
/// neither does, native wallets an app isolate left open when Android
/// destroyed it are closed first, sparing a live app's.
Future<bool> _askOtherHolders() async {
  if (!holdersShareProcess) return false;
  Future<Object?> ask(String name) =>
      WalletHolders.ask(name, WalletHolders.holdsQuery, timeout: const Duration(seconds: 2));
  final app = await ask(WalletHolders.appName);
  if (app is Map && app['holds'] == true) return true;
  final service = await ask(WalletHolders.serviceName);
  if (service is Map && service['holds'] == true) return true;
  await WalletManager.closeOrphanedWallets?.call(
    exceptToken: app is Map ? app['token'] as String? : null,
  );
  return false;
}

/// Whether another periodic run is registered and still answering.
Future<bool> _peerRunHolds() async {
  final answer = await WalletHolders.ask(
    WalletHolders.periodicRunName,
    WalletHolders.holdsQuery,
    timeout: const Duration(seconds: 2),
  );
  return answer is Map && answer['holds'] == true;
}

/// The app, or the full-scan run, asking a run to let go
/// ([WalletHolders.periodicRunName]); it answers "holds?" while it runs.
class _ReleaseRequest {
  _ReleaseRequest() {
    port.listen((message) {
      switch (SyncMessage.opOf(message)) {
        case 'hello':
          _asked ??= message;
        case 'holds?':
          WalletHolders.answer(message, {'op': 'holds', 'holds': true});
      }
    });
  }

  final port = ReceivePort();
  Object? _asked;
  bool _answered = false;

  bool get asked => _asked != null;

  void answerIfAsked() {
    if (_asked == null || _answered) return;
    _answered = true;
    WalletHolders.answer(_asked, SyncMessage.released);
  }
}

/// The coins an unattended run in this window would sync, decided WITHOUT
/// opening any wallet file: the persisted connections are loaded onto a probe
/// manager, and each coin says what an unattended run of it would be. Opening
/// a coin's file, a Monero wallet especially, is the expensive part, and a
/// short iOS refresh must not pay it for coins it will skip.
///
/// Asked twice: by a run, to pick what to open, and by the scheduler, so a
/// task that would find nothing is never registered at all. [scansOnly] asks
/// whether any coin needs a full scan, which is what Android's full-scan job
/// is registered for.
Future<Set<String>> syncableCoins({
  bool allowTor = true,
  bool allowNode = true,
  bool scansOnly = false,
}) async {
  final probe = WalletManager(coins: BackgroundSync.coins);
  try {
    if (!await probe.hasAnyExistingWallet()) return const {};
    await probe.loadCachedDisplayState();

    // Scheduling-window policy: the short iOS refresh takes neither Tor (a
    // bootstrap can outlast the window) nor a scan (it cannot finish); the
    // charging processing window allows Tor but still never a scan. BTC/ETH and
    // Monero-LWS all report `check`, a server already did the work, so they
    // always qualify.
    //
    // `allowNode` keeps its name and its meaning: it answers "can this *window*
    // afford the work", which is a different question from "which mechanism
    // does this coin use", and it stays true whatever key the scan holds. Native
    // view-key sync removes the security objection to an unattended scan, not
    // the battery and bandwidth one.
    return probe.allWallets
        .where(
          (w) =>
              w.backgroundSyncMode != BackgroundSyncMode.none &&
              (allowNode || w.backgroundSyncMode != BackgroundSyncMode.scan) &&
              (!scansOnly || w.backgroundSyncMode == BackgroundSyncMode.scan) &&
              (allowTor || !w.usingTor),
        )
        .map((w) => w.coinSymbol)
        .toSet();
  } finally {
    probe.dispose();
  }
}

Future<bool> _runTxNotifier({
  required Duration budget,
  required bool allowTor,
  required bool allowNode,
  required Duration pollInterval,
  required _ReleaseRequest release,
}) async {
  final syncableSymbols = await syncableCoins(allowTor: allowTor, allowNode: allowNode);
  if (syncableSymbols.isEmpty) return true;

  // Open ONLY the syncable coins; a filtered registry, so no other coin's file
  // (or native scan thread) is touched.
  final walletManager = WalletManager(
    coins: () => BackgroundSync.coins()
        .where((w) => syncableSymbols.contains(w.coinSymbol))
        // Marked before anything is opened, because it is what selects the file
        // and the password: a coin with a view-only unattended path (Monero on a
        // node) opens its background cache instead of its real wallet, and holds
        // no spend key for the length of the run. Nothing in the run may write
        // the display snapshot either; a view-only scan's balance is
        // approximate. See `CryptoWallet.markUnattended`.
        .map((w) => w..markUnattended())
        .toList(),
  );
  try {
    // The app is about to open its own: open nothing.
    if (release.asked) return true;
    await walletManager.openAll();
    // Asked again after each slow step (the open, Tor, connecting): the app
    // may have asked meanwhile, and waits until these wallets are closed.
    if (release.asked) return true;

    final wallets = walletManager.activeWallets;
    if (wallets.isEmpty) return true;

    for (final w in wallets) {
      await w.loadPersistedConnection();
    }

    if (wallets.any((w) => w.usingTor)) {
      await BackgroundSync.ensureTorConnected?.call();
      if (release.asked) return true;
    }

    // Kick each wallet's daemon connection (starts the scan thread).
    await Future.wait(
      wallets.map((w) async {
        if (w.connectionAddress.isEmpty) return;
        try {
          await w.connectToDaemon();
        } catch (e) {
          log(LogLevel.warn, '[Background sync] connect failed: $e', coin: w.coinSymbol);
        }
      }),
    );
    if (release.asked) return true;

    await _waitForWallets(
      wallets,
      budget: budget,
      pollInterval: pollInterval,
      stop: () => release.asked,
    );

    // The app wants the wallets, and announces from here.
    if (release.asked) return true;

    for (final w in wallets) {
      if (w.connectionAddress.isEmpty) continue;
      try {
        await w.loadTxHistory(persistCount: false);
      } catch (e) {
        log(LogLevel.warn, '[Background sync] loadTxHistory failed: $e', coin: w.coinSymbol);
      }
    }

    // Checkpoint the scan so a killed isolate doesn't lose progress since the
    // last store, then announce new incoming txs. The app's notifier respects
    // the notifications toggle on mobile and records txs as seen either way, so
    // enabling notifications later does not replay a backlog.
    await walletManager.pauseSyncAndStoreAll();
    await walletManager.notifyNewIncomingTxsAll();
    return true;
  } finally {
    // However the run ended, and before anyone that asked is told it may open
    // the wallets: checkpoint the scans and close everything. WorkManager
    // destroys this isolate next, and a wallet left open would stay behind in
    // a process the app or the service keeps alive.
    await _closeAll(walletManager);
  }
}

Future<void> _closeAll(WalletManager manager) async {
  try {
    await manager.fullyLock();
  } catch (e) {
    log(LogLevel.warn, '[Background sync] closing the wallets failed: $e');
  }
  manager.dispose();
}

/// Keeps the isolate alive while the wallets get on with it, up to [budget].
///
/// The wallets' own timers drive the work; this only decides when there is no
/// longer any point waiting. **Per wallet**, because the two shapes do not
/// advertise progress the same way and a single combined detector has to be
/// tuned for the slower one, which is how a scan-shaped detector came to carry
/// a check-shaped patience for everybody. A wallet that stops making progress is
/// dropped from the watch set rather than ending the whole run, and, just as
/// much to the point, a Monero scan that is working no longer keeps a dead
/// Electrum server in the set for the rest of the budget.
Future<void> _waitForWallets(
  List<CryptoWallet> wallets, {
  required Duration budget,
  required Duration pollInterval,
  required bool Function() stop,
}) async {
  final deadline = DateTime.now().add(budget);
  final waiting = wallets.where((w) => w.connectionAddress.isNotEmpty).toList();
  // Scans only. A check's height is not a progress signal, so reading it here
  // would be reading it for nothing.
  final lastHeights = {
    for (final w in waiting)
      if (w.backgroundSyncMode == BackgroundSyncMode.scan) w.coinSymbol: w.syncedHeight,
  };
  // Polls this wallet has waited. Reset by progress for a scan; monotonic for a
  // check, which has no progress to reset it; see the two constants above.
  final pollsWaited = {for (final w in waiting) w.coinSymbol: 0};

  while (waiting.isNotEmpty && DateTime.now().isBefore(deadline) && !stop()) {
    waiting.removeWhere((w) {
      if (w.isConnected && w.isSynced) return true;

      final polls = (pollsWaited[w.coinSymbol] ?? 0) + 1;
      pollsWaited[w.coinSymbol] = polls;

      if (w.backgroundSyncMode == BackgroundSyncMode.scan) {
        // Read once per poll, not twice: the second read of a moving value is a
        // different answer, and a test that scripts progress cannot script it.
        final height = w.syncedHeight;
        if (height != lastHeights[w.coinSymbol]) {
          lastHeights[w.coinSymbol] = height;
          pollsWaited[w.coinSymbol] = 0;
          return false;
        }
        if (polls < _scanStuckPolls) return false;
        log(
          LogLevel.warn,
          '[Background sync] the scan has not advanced; giving up on it for this window.',
          coin: w.coinSymbol,
        );
        return true;
      }

      if (polls < _checkPollBudget) return false;
      log(
        LogLevel.warn,
        '[Background sync] the server has not reported; giving up on it for this window.',
        coin: w.coinSymbol,
      );
      return true;
    });

    if (waiting.isEmpty) break;
    await Future.delayed(pollInterval);
  }
}

/// Routes a scheduled task to the right [runTxNotifier] window. The app's
/// WorkManager `@pragma` entry calls this after bootstrapping the isolate.
///
/// Runs only under [SyncFrequency.periodic]. Changing the setting cancels the
/// tasks, but one already handed to the isolate can still arrive.
Future<bool> dispatchBackgroundTask(String task) async {
  if (await loadSyncFrequency() != SyncFrequency.periodic) return true;
  switch (task) {
    // ~30s, whenever iOS feels like it: enough for a light server to report what
    // it already scanned, and nothing more.
    case PeriodicTasks.iosRefresh:
      return runTxNotifier(budget: _iosRefreshBudget, allowTor: false, allowNode: false);

    // Charging, idle and minutes long: room for a Tor bootstrap and a full scan.
    case PeriodicTasks.iosProcessing:
      return runTxNotifier();

    // Registered to run only while charging and on WiFi.
    case PeriodicTasks.scan:
      return runTxNotifier();

    // The light job, on any network; a task this build does not know is treated
    // as it, since that is the one whose constraints any device state meets.
    case PeriodicTasks.txNotifier:
    default:
      return runTxNotifier(allowNode: false);
  }
}

/// (Re)registers background work to match [SyncFrequency] and the configured
/// coins, or cancels it. Call once a change has been applied: after the
/// setting changes, after a saved connection has been applied (the wallet
/// rebuilt for it), when the wallet home opens, and at launch.
///
/// Each task is registered only while some coin gives it work, using the same
/// choice the run makes ([syncableCoins]), so a phone with nothing to check is
/// never woken to find that out. The README lays out every case.
///
/// Not from a connection form's save: [syncableCoins] asks whether each wallet
/// file exists, and a Monero wallet whose saved mode has no file yet (the node
/// file a just-saved node connection is about to create) adopts the mode that
/// has one, undoing the save.
///
/// A task that stays is updated in place, not replaced, so calling this often
/// does not keep pushing its next run back.
Future<void> applyBackgroundTaskRegistration() async {
  if (Platform.isIOS) return _applyIosBackgroundTasks();
  if (!Platform.isAndroid) return;

  final periodic = await loadSyncFrequency() == SyncFrequency.periodic;
  // Light coins: a server already scanned, so any network will do.
  final light = periodic && (await syncableCoins(allowNode: false)).isNotEmpty;
  // A full scan (a Monero node) downloads and scans every block, so it waits
  // for a charger and WiFi.
  final scan = periodic && (await syncableCoins(scansOnly: true)).isNotEmpty;

  final minutes =
      await SharedPreferencesService.get<int>(SettingsKeys.backgroundSyncIntervalMinutes) ??
      _minSyncIntervalMinutes;
  final frequency = Duration(
    minutes: minutes < _minSyncIntervalMinutes ? _minSyncIntervalMinutes : minutes,
  );

  Future<void> apply(String task, {required bool wanted, required Constraints constraints}) =>
      wanted
      ? Workmanager().registerPeriodicTask(
          task,
          task,
          frequency: frequency,
          constraints: constraints,
          existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        )
      : Workmanager().cancelByUniqueName(task);

  await apply(
    PeriodicTasks.txNotifier,
    wanted: light,
    constraints: Constraints(networkType: NetworkType.connected, requiresBatteryNotLow: true),
  );
  await apply(
    PeriodicTasks.scan,
    wanted: scan,
    constraints: Constraints(networkType: NetworkType.unmetered, requiresCharging: true),
  );
}

/// iOS scheduling, under [SyncFrequency.periodic]. The short refresh takes the
/// light coins that need no Tor; the charging processing window takes every
/// coin, Tor and full scans (a Monero node) included. iOS cannot require WiFi,
/// so that scan may run on cellular. iOS can also end a window early; a
/// scanning wallet checkpoints every few minutes as it goes
/// (`CryptoWallet.syncCheckpointInterval`), so little is lost.
Future<void> _applyIosBackgroundTasks() async {
  final periodic = await loadSyncFrequency() == SyncFrequency.periodic;

  if (periodic && (await syncableCoins(allowTor: false, allowNode: false)).isNotEmpty) {
    await Workmanager().registerPeriodicTask(
      _iosRefreshTaskId,
      PeriodicTasks.iosRefresh,
      frequency: Duration(minutes: _minSyncIntervalMinutes),
    );
  } else {
    await Workmanager().cancelByUniqueName(_iosRefreshTaskId);
  }
  if (periodic && (await syncableCoins()).isNotEmpty) {
    await Workmanager().registerProcessingTask(
      _iosProcessingTaskId,
      PeriodicTasks.iosProcessing,
      constraints: Constraints(networkType: NetworkType.connected, requiresCharging: true),
    );
  } else {
    await Workmanager().cancelByUniqueName(_iosProcessingTaskId);
  }
}

/// Moves the old Background Sync / Continuous Sync toggles onto
/// [SyncFrequency] ([migrateLegacySyncSettings]), once. Call at launch after
/// the app's wallet-core bootstrap, before anything reads the setting: the
/// task registration, the Continuous Sync service, or a wallet open.
///
/// Whether this is an existing install is read from the wallet files, without
/// opening any.
Future<void> migrateSyncSettings() async {
  if (await SharedPreferencesService.get<String>(SettingsKeys.syncFrequency) != null) {
    return migrateLegacySyncSettings(existingInstall: true);
  }
  final probe = WalletManager(coins: BackgroundSync.coins);
  try {
    await migrateLegacySyncSettings(existingInstall: await probe.hasAnyExistingWallet());
  } finally {
    probe.dispose();
  }
}

Future<void> registerPeriodicTasks() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;

  Workmanager().initialize(BackgroundSync.workmanagerCallback);
  await applyBackgroundTaskRegistration();
}
