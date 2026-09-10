import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart' show NotificationIcon;
import 'package:wallet_domain/wallet_domain.dart'
    show BackgroundSyncMode, CoinRegistry, CryptoWallet, WalletManager;
import 'package:wallet_infra/wallet_infra.dart';
import 'package:workmanager/workmanager.dart';

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
  static const txNotifier = 'txNotifier';

  /// iOS BGAppRefreshTask: opportunistic, ~30s, iOS decides when. Only light
  /// clearnet wallets can do anything useful in it.
  static const iosRefresh = 'refresh';

  /// iOS BGProcessingTask: minutes, while charging and idle, so there is room for Tor to
  /// bootstrap. Still never a Monero node scan.
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
Future<bool> runTxNotifier({
  Duration budget = _backgroundSyncBudget,
  bool allowTor = true,
  bool allowNode = true,
  Duration pollInterval = _backgroundSyncPollInterval,
}) async {
  // Decide what this window can sync WITHOUT opening any wallet file: load the
  // persisted connections onto a probe manager and read what each coin says an
  // unattended run of it would be. Opening a coin's file, a Monero wallet
  // especially, is the expensive part, and a short iOS refresh must not pay it
  // for coins it will skip.
  final probe = WalletManager(coins: BackgroundSync.coins);
  if (!await probe.hasAnyExistingWallet()) return true;
  await probe.loadCachedDisplayState();

  // Scheduling-window policy: the short iOS refresh takes neither Tor (a
  // bootstrap can outlast the window) nor a scan (it cannot finish); the
  // charging processing window allows Tor but still never a scan. BTC/ETH and
  // Monero-LWS all report `check`, a server already did the work, so they
  // always qualify.
  //
  // `allowNode` keeps its name and its meaning: it answers "can this *window*
  // afford the work", which is a different question from "which mechanism does
  // this coin use", and it stays true whatever key the scan holds. Native
  // view-key sync removes the security objection to an unattended scan, not the
  // battery and bandwidth one.
  final syncableSymbols = probe.allWallets
      .where(
        (w) =>
            w.backgroundSyncMode != BackgroundSyncMode.none &&
            (allowNode || w.backgroundSyncMode != BackgroundSyncMode.scan) &&
            (allowTor || !w.usingTor),
      )
      .map((w) => w.coinSymbol)
      .toSet();
  probe.dispose();
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
  await walletManager.openAll();

  final wallets = walletManager.activeWallets;
  if (wallets.isEmpty) return true;

  for (final w in wallets) {
    await w.loadPersistedConnection();
  }

  if (wallets.any((w) => w.usingTor)) {
    await BackgroundSync.ensureTorConnected?.call();
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

  await _waitForWallets(wallets, budget: budget, pollInterval: pollInterval);

  for (final w in wallets) {
    if (w.connectionAddress.isEmpty) continue;
    try {
      await w.loadTxHistory(persistCount: false);
    } catch (e) {
      log(LogLevel.warn, '[Background sync] loadTxHistory failed: $e', coin: w.coinSymbol);
    }
  }

  // Checkpoint the scan so a killed isolate doesn't lose progress since the last
  // store, then announce new incoming txs. The app's notifier respects the
  // notifications toggle on mobile and records txs as seen either way, so
  // enabling notifications later does not replay a backlog.
  await walletManager.pauseSyncAndStoreAll();
  await walletManager.notifyNewIncomingTxsAll();

  return true;
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

  while (waiting.isNotEmpty && DateTime.now().isBefore(deadline)) {
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
Future<bool> dispatchBackgroundTask(String task) async {
  switch (task) {
    // ~30s, whenever iOS feels like it: enough for a light server to report what
    // it already scanned, and nothing more.
    case PeriodicTasks.iosRefresh:
      return runTxNotifier(budget: _iosRefreshBudget, allowTor: false, allowNode: false);

    // Charging and idle, so there is room for Tor to bootstrap first.
    case PeriodicTasks.iosProcessing:
      return runTxNotifier(allowNode: false);

    case PeriodicTasks.txNotifier:
    default:
      // A node scan is heavy, so only run it when Background Sync is on; light
      // coins (LWS/Electrum/RPC) still notify on the Notifications toggle alone.
      final backgroundSync =
          await SharedPreferencesService.get<bool>(SettingsKeys.backgroundSyncEnabled) ?? false;
      return runTxNotifier(allowNode: backgroundSync);
  }
}

/// (Re)registers background work to match the current settings, or cancels it.
/// Call after anything that changes the answer: the notifications toggle, the
/// background-sync toggle, or a connection change.
Future<void> applyBackgroundTaskRegistration() async {
  if (Platform.isIOS) return _applyIosBackgroundTasks();
  if (!Platform.isAndroid) return;

  final backgroundSync =
      await SharedPreferencesService.get<bool>(SettingsKeys.backgroundSyncEnabled) ?? false;
  final notifications =
      await SharedPreferencesService.get<bool>(SettingsKeys.notificationsEnabled) ?? false;

  await Workmanager().cancelByUniqueName(PeriodicTasks.txNotifier);
  if (!backgroundSync && !notifications) return;

  final minutes =
      await SharedPreferencesService.get<int>(SettingsKeys.backgroundSyncIntervalMinutes) ??
      _minSyncIntervalMinutes;

  // A background scan is heavy (a Monero node in particular), so when background
  // sync is on gate it on charging + WiFi; a notifications-only run is light and
  // takes the looser constraint.
  final constraints = backgroundSync
      ? Constraints(networkType: NetworkType.unmetered, requiresCharging: true)
      : Constraints(networkType: NetworkType.connected, requiresBatteryNotLow: true);

  await Workmanager().registerPeriodicTask(
    PeriodicTasks.txNotifier,
    'Background sync',
    frequency: Duration(
      minutes: minutes < _minSyncIntervalMinutes ? _minSyncIntervalMinutes : minutes,
    ),
    constraints: constraints,
  );
}

/// iOS scheduling. Gated on the notifications toggle; the two windows exist to
/// deliver incoming-tx notifications, not to advance a heavy scan. Which coins
/// each window actually syncs is decided per-run in [runTxNotifier]: the short
/// refresh takes light clearnet wallets, while the charging processing window
/// additionally allows Tor. A Monero node is never background-scanned on iOS.
Future<void> _applyIosBackgroundTasks() async {
  final notifications =
      await SharedPreferencesService.get<bool>(SettingsKeys.notificationsEnabled) ?? false;

  await Workmanager().cancelByUniqueName(_iosRefreshTaskId);
  await Workmanager().cancelByUniqueName(_iosProcessingTaskId);

  if (!notifications) return;

  await Workmanager().registerPeriodicTask(
    _iosRefreshTaskId,
    PeriodicTasks.iosRefresh,
    frequency: Duration(minutes: _minSyncIntervalMinutes),
  );
  await Workmanager().registerProcessingTask(
    _iosProcessingTaskId,
    PeriodicTasks.iosProcessing,
    constraints: Constraints(networkType: NetworkType.connected, requiresCharging: true),
  );
}

Future<void> registerPeriodicTasks() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;

  Workmanager().initialize(BackgroundSync.workmanagerCallback);
  await applyBackgroundTaskRegistration();
}
