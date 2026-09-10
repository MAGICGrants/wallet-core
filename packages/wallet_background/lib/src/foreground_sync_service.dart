import 'dart:async';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wallet_domain/wallet_domain.dart' show WalletManager, CryptoWallet;
import 'package:wallet_infra/wallet_infra.dart';

import 'background_sync.dart';

/// Android foreground service that keeps the wallets syncing while the app is
/// backgrounded; a persistent-notification alternative to the budget-limited
/// WorkManager task. Dies on force-quit (OS limitation).
const _channelId = 'wallet_background_sync';
const _channelName = 'Background sync';

/// The task handler the app's foreground `@pragma` entry hands to
/// `FlutterForegroundTask.setTaskHandler`. The entry bootstraps wallet-core in
/// the isolate first, so [onStart] can assume it is installed.
///
/// This handler deliberately skips the view-only path `runTxNotifier` uses for a
/// Monero node wallet. A view-only run's progress only merges when the main
/// wallet is next opened, so it would reach the balance on the next cold start
/// rather than when the user switches back to the app.
///
/// Known limitation: opening the main wallet here means two wallet2 instances on
/// `<path>_node` while the service runs, each with its own poll loop and cache
/// writer. Fixing it needs a handshake between this isolate and the UI's, since
/// `onDestroy` only fires on `stopService`. Tolerable because the user switched
/// this on and a persistent notification announces it, unlike a WorkManager
/// wake-up.
class BackgroundSyncTaskHandler extends TaskHandler {
  WalletManager? _manager;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final manager = WalletManager(coins: BackgroundSync.coins);
    _manager = manager;
    try {
      if (!await manager.hasAnyExistingWallet()) return;
      await manager.openAll();
      final wallets = manager.activeWallets;
      for (final w in wallets) {
        await w.loadPersistedConnection();
      }
      if (wallets.any((w) => w.usingTor)) {
        await BackgroundSync.ensureTorConnected?.call();
      }
      // Connect each wallet; their own timers then drive the scan + checkpoints
      // for as long as this service keeps the isolate alive.
      for (final w in wallets) {
        if (w.connectionAddress.isEmpty) continue;
        try {
          await w.connectToDaemon();
        } catch (e) {
          log(LogLevel.warn, '[FG sync] connect failed: $e', coin: w.coinSymbol);
        }
      }
    } catch (e) {
      log(LogLevel.warn, '[FG sync] start failed: $e');
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    final wallets = _manager?.activeWallets ?? const <CryptoWallet>[];
    final syncing = wallets.any((w) => w.connectionAddress.isNotEmpty && !isWalletFullySynced(w));
    FlutterForegroundTask.updateService(
      notificationTitle: BackgroundSync.foregroundTitle,
      notificationText: syncing ? 'Syncing…' : 'Wallet up to date',
      notificationIcon: BackgroundSync.foregroundIcon,
    );

    // While this service runs it watches the chain, so it announces what it
    // finds; the WorkManager task runs on its own schedule and would otherwise
    // never see these.
    final manager = _manager;
    if (manager != null) {
      unawaited(
        manager.notifyNewIncomingTxsAll().catchError((Object e) {
          log(LogLevel.warn, '[FG sync] notifying new transactions failed: $e');
        }),
      );
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // Checkpoint scan progress before tearing down, or everything scanned since
    // the last periodic store is lost.
    await _manager?.pauseSyncAndStoreAll();
    _manager?.dispose();
    _manager = null;
  }
}

/// A wallet is fully caught up only once a real height has loaded: [isSynced]
/// can flip true in the post-open window before [syncedHeight] arrives (LWS
/// reports 0 first), which would otherwise show "up to date" prematurely.
bool isWalletFullySynced(CryptoWallet w) =>
    w.isConnected && w.isSynced && (w.syncedHeight ?? 0) > 0;

/// Configures the service. Safe to call more than once.
void initForegroundSync() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: _channelId,
      channelName: _channelName,
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(30000),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

/// [synced] seeds the initial notification text so toggling the service on while
/// already caught up shows "up to date" immediately, not a stale "Syncing…"
/// until the first repeat tick.
Future<void> startForegroundSync({bool synced = false}) async {
  if (!Platform.isAndroid) return;
  initForegroundSync();
  await FlutterForegroundTask.requestNotificationPermission();
  if (await FlutterForegroundTask.isRunningService) return;
  await FlutterForegroundTask.startService(
    notificationTitle: BackgroundSync.foregroundTitle,
    notificationText: synced ? 'Wallet up to date' : 'Syncing…',
    notificationIcon: BackgroundSync.foregroundIcon,
    callback: BackgroundSync.foregroundCallback,
  );
}

Future<void> stopForegroundSync() async {
  if (!Platform.isAndroid) return;
  if (await FlutterForegroundTask.isRunningService) {
    await FlutterForegroundTask.stopService();
  }
}

/// Starts the service on launch if the user enabled it, so backgrounding keeps
/// syncing.
Future<void> startForegroundSyncIfEnabled() async {
  if (!Platform.isAndroid) return;
  final enabled =
      await SharedPreferencesService.get<bool>(SettingsKeys.foregroundSyncEnabled) ?? false;
  if (enabled) await startForegroundSync();
}
