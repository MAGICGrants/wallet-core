import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wallet_domain/wallet_domain.dart' show WalletManager, CryptoWallet;
import 'package:wallet_infra/wallet_infra.dart';

import 'background_sync.dart';
import 'foreground_sync_link.dart' show ForegroundSyncLink;
import 'sync_handoff.dart';
import 'wallet_holders.dart';

/// Android foreground service that keeps the wallets syncing while the app is
/// backgrounded; a persistent-notification alternative to the budget-limited
/// WorkManager task. Dies on force-quit (OS limitation).
const _channelId = 'wallet_background_sync';
const _channelName = 'Background sync';

/// The task handler the app's foreground `@pragma` entry hands to
/// `FlutterForegroundTask.setTaskHandler`. The entry bootstraps wallet-core in
/// the isolate first, so [onStart] can assume it is installed.
///
/// View-only, whether or not security keys are on: every wallet is marked
/// unattended ([serviceCoins]), so this isolate never holds the wallet password,
/// the seed or a spend key. A Monero node wallet scans its view-only background
/// copy; Monero LWS asks its server with the view key, Bitcoin checks with the
/// account xpub, Ethereum with the address. Incoming payments are announced
/// once confirmed (the background copy does not watch the mempool). What the
/// copy scanned merges into the main wallet the next time that opens.
///
/// It holds the wallets only when the app does not ([SyncHandoff]): while the
/// app's are open it keeps the process alive and lets the app announce, and it
/// lets go of its own before the app opens them ([ForegroundSyncLink]).
class BackgroundSyncTaskHandler extends TaskHandler {
  WalletManager? _manager;
  final _handoff = SyncHandoff();
  // What the app last said about its wallets, for the notification text.
  bool _appSynced = false;
  // Holding and releasing one at a time: each opens or closes every wallet.
  Future<void> _changes = Future.value();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Nothing opens here: the app holds the wallets until it says otherwise or
    // stops answering ([SyncHandoff]). The first tick asks.
    FlutterForegroundTask.sendDataToMain(SyncMessage.ping);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.sendDataToMain(SyncMessage.ping);
    _handoff.onTick();
    _applyHandoff();

    final manager = _manager;
    final wallets = manager?.activeWallets ?? const <CryptoWallet>[];
    final syncing = manager == null
        ? !_appSynced
        : wallets.any((w) => w.connectionAddress.isNotEmpty && !isWalletFullySynced(w));
    FlutterForegroundTask.updateService(
      notificationTitle: BackgroundSync.foregroundTitle,
      notificationText: syncing ? 'Syncing…' : 'Wallet up to date',
      notificationIcon: BackgroundSync.foregroundIcon,
    );

    // While this service holds the wallets it announces what it finds; the
    // app announces for its own.
    if (manager != null) {
      unawaited(
        manager.notifyNewIncomingTxsAll().catchError((Object e) {
          log(LogLevel.warn, '[FG sync] notifying new transactions failed: $e');
        }),
      );
    }
  }

  @override
  void onReceiveData(Object data) {
    switch (SyncMessage.opOf(data)) {
      case 'pong':
        final map = data as Map;
        _appSynced = map['synced'] == true;
        _handoff.onPong(appHolds: map['holds'] == true);
        _applyHandoff();
      case 'hello':
        _handoff.onHello();
        // Closed first, then said: the app opens only once nothing here
        // holds the files.
        unawaited(
          _change(_release)
              .whenComplete(() => FlutterForegroundTask.sendDataToMain(SyncMessage.released)),
        );
    }
  }

  void _applyHandoff() {
    if (_handoff.serviceShouldHold) {
      unawaited(_change(_hold));
    } else {
      unawaited(_change(_release));
    }
  }

  Future<void> _change(Future<void> Function() step) =>
      _changes = _changes.then((_) => step()).catchError((Object e) {
        log(LogLevel.warn, '[FG sync] hand-off step failed: $e');
      });

  /// Opens the view-only wallets and connects them; their own timers then
  /// drive the scan and its checkpoints for as long as this holds them.
  ///
  /// Registered as a holder first ([WalletHolders.serviceName]), so a periodic
  /// run starting meanwhile skips; then a periodic run that holds them lets go.
  Future<void> _hold() async {
    if (_manager != null || !_handoff.serviceShouldHold) return;
    final manager = WalletManager(coins: serviceCoins);
    _manager = manager;
    final holderPort = ReceivePort()..listen(_answerHolds);
    _holderPort = holderPort;
    WalletHolders.register(WalletHolders.serviceName, holderPort.sendPort);
    try {
      await WalletHolders.ask(
        WalletHolders.periodicRunName,
        SyncMessage.hello,
        timeout: const Duration(seconds: 10),
      );
      // Native wallets the app's isolate left open when Android destroyed it
      // (swiped away while this keeps the process alive): closed first. Asked
      // once more, so the wallets of an app that still answers are spared.
      final app = await WalletHolders.ask(
        WalletHolders.appName,
        WalletHolders.holdsQuery,
        timeout: const Duration(seconds: 2),
      );
      await WalletManager.closeOrphanedWallets?.call(
        exceptToken: app is Map ? app['token'] as String? : null,
      );
      if (!await manager.hasAnyExistingWallet()) return;
      await manager.openAll();
      final wallets = manager.activeWallets;
      for (final w in wallets) {
        await w.loadPersistedConnection();
      }
      if (wallets.any((w) => w.usingTor)) {
        await BackgroundSync.ensureTorConnected?.call();
      }
      for (final w in wallets) {
        if (w.connectionAddress.isEmpty) continue;
        try {
          await w.connectToDaemon();
        } catch (e) {
          log(LogLevel.warn, '[FG sync] connect failed: $e', coin: w.coinSymbol);
        }
      }
      log(LogLevel.info, '[FG sync] holding the view-only wallets');
    } catch (e) {
      log(LogLevel.warn, '[FG sync] start failed: $e');
    }
  }

  ReceivePort? _holderPort;

  void _answerHolds(Object? message) {
    if (SyncMessage.opOf(message) == 'holds?') {
      WalletHolders.answer(message, {'op': 'holds', 'holds': _manager != null});
    }
  }

  /// Checkpoints the scan, then closes every wallet, so the app can open its
  /// own on the same files.
  Future<void> _release() async {
    final manager = _manager;
    if (manager == null) return;
    _manager = null;
    try {
      await manager.fullyLock();
      manager.dispose();
    } finally {
      final holderPort = _holderPort;
      _holderPort = null;
      if (holderPort != null) {
        WalletHolders.unregister(WalletHolders.serviceName, holderPort.sendPort);
        holderPort.close();
      }
    }
    log(LogLevel.info, '[FG sync] released the wallets to the app');
  }

  @override
  Future<void> onDestroy(DateTime timestamp) => _change(_release);
}

/// The coins the Continuous Sync service opens: every one, each marked
/// unattended before it is opened, so it opens view-only.
List<CryptoWallet> serviceCoins() => [for (final w in BackgroundSync.coins()) w..markUnattended()];

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

/// Restarts the service so its isolate re-reads a changed connection. No-op when
/// it isn't running. The new connection must already be persisted before this.
Future<void> restartForegroundSyncIfRunning() async {
  if (!Platform.isAndroid) return;
  if (!await FlutterForegroundTask.isRunningService) return;
  await stopForegroundSync();
  await startForegroundSync();
}

/// Starts the service on launch if the user enabled it, so backgrounding keeps
/// syncing.
Future<void> startForegroundSyncIfEnabled() async {
  if (!Platform.isAndroid) return;
  final enabled =
      await SharedPreferencesService.get<bool>(SettingsKeys.foregroundSyncEnabled) ?? false;
  if (enabled) await startForegroundSync();
}

Future<void> stopSyncAndDeleteWallets(
  WalletManager manager, {
  List<String> extraPrefKeys = const [],
}) async {
  // First: the running service's isolate must be gone before the files are.
  await stopForegroundSync();

  await SharedPreferencesService.set<bool>(SettingsKeys.backgroundSyncEnabled, false);
  await SharedPreferencesService.set<bool>(SettingsKeys.foregroundSyncEnabled, false);
  await SharedPreferencesService.set<bool>(SettingsKeys.notificationsEnabled, false);
  await applyBackgroundTaskRegistration();

  await manager.deleteAll(extraPrefKeys: extraPrefKeys);
}
