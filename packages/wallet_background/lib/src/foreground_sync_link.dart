import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wallet_domain/wallet_domain.dart' show WalletIsolate, WalletManager;
import 'package:wallet_infra/wallet_infra.dart';

import 'foreground_sync_service.dart' show isWalletFullySynced, restartForegroundSyncIfRunning;
import 'sync_handoff.dart';
import 'wallet_holders.dart';

/// How the app reaches the Continuous Sync service; the plugin in the app,
/// a fake in tests.
abstract class SyncLinkTransport {
  const SyncLinkTransport();

  Future<bool> isServiceRunning();

  void sendToService(Map<String, Object> message);

  /// Stops the service and starts a fresh one, which holds nothing until it
  /// asks ([SyncHandoff]).
  Future<void> restartService();
}

class _PluginTransport extends SyncLinkTransport {
  const _PluginTransport();

  @override
  Future<bool> isServiceRunning() => FlutterForegroundTask.isRunningService;

  @override
  void sendToService(Map<String, Object> message) => FlutterForegroundTask.sendDataToTask(message);

  @override
  Future<void> restartService() => restartForegroundSyncIfRunning();
}

/// The app's side of the hand-off with the isolates that hold the wallets
/// without the user: the Continuous Sync service ([SyncHandoff]) and a periodic
/// Background sync run ([WalletHolders]). Before the app opens its wallets
/// they let go of theirs ([claim]); while its wallets are open the app answers
/// that it holds them, and announces payments itself.
class ForegroundSyncLink {
  ForegroundSyncLink({
    required this.manager,
    this._transport = const _PluginTransport(),
    this.claimTimeout = const Duration(seconds: 10),
    @visibleForTesting DateTime Function()? clock,
    @visibleForTesting
    Future<Object?> Function(String name, Map<String, Object> message, Duration timeout)? ask,
    @visibleForTesting Future<void> Function({String? exceptToken})? closeOrphans,
  }) : _clock = clock ?? DateTime.now,
       _closeOrphans =
           closeOrphans ??
           (({exceptToken}) async =>
               WalletManager.closeOrphanedWallets?.call(exceptToken: exceptToken)),
       _ask =
           ask ?? ((name, message, timeout) => WalletHolders.ask(name, message, timeout: timeout));

  /// The app's wallets.
  final WalletManager manager;
  final SyncLinkTransport _transport;

  /// How long [claim] waits for the service to let go before restarting it.
  final Duration claimTimeout;
  final DateTime Function() _clock;
  final Future<Object?> Function(String name, Map<String, Object> message, Duration timeout) _ask;
  final Future<void> Function({String? exceptToken}) _closeOrphans;

  Completer<void>? _released;

  // A claim counts as holding for a while, as the open it precedes runs: the
  // service must not take the wallets back before they have loaded.
  DateTime? _claimedAt;
  static const _claimHolds = Duration(minutes: 2);

  /// Installs the link for the app: answers the service over the plugin's
  /// port and a periodic run over [WalletHolders.appName], and makes every open
  /// with the password claim the files first ([WalletManager.claimWalletFiles]).
  /// Android only; call once, from the app isolate, before anything opens.
  static ForegroundSyncLink? install(WalletManager manager) {
    if (!Platform.isAndroid) return null;
    final link = ForegroundSyncLink(manager: manager);
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(link.onMessage);
    final holderPort = ReceivePort()..listen(link.onHolderMessage);
    WalletHolders.register(WalletHolders.appName, holderPort.sendPort);
    WalletManager.claimWalletFiles = link.claim;
    return link;
  }

  /// A periodic run asking whether the app holds the wallets
  /// ([WalletHolders.holdsQuery]). When it does, the run skips, and the app
  /// announces for it.
  void onHolderMessage(Object? message) {
    if (SyncMessage.opOf(message) != 'holds?') return;
    final holds = holdsWallets;
    // With this isolate's token: whoever closes wallets a destroyed isolate
    // left open must not close this one's.
    WalletHolders.answer(message, {'op': 'holds', 'holds': holds, 'token': WalletIsolate.token});
    if (holds) _announce();
  }

  void _announce() => unawaited(
    manager.notifyNewIncomingTxsAll().catchError((Object e) {
      log(LogLevel.warn, '[FG sync] notifying new transactions failed: $e');
    }),
  );

  /// Whether the app holds the wallets: any is open (with its keys, or
  /// view-only since the spend wallet locked), or an open is about to start.
  bool get holdsWallets {
    if (manager.loadedWallets.isNotEmpty) return true;
    final claimedAt = _claimedAt;
    return claimedAt != null && _clock().difference(claimedAt) < _claimHolds;
  }

  /// A message from the service.
  void onMessage(Object? data) {
    switch (SyncMessage.opOf(data)) {
      case 'ping':
        final holds = holdsWallets;
        final active = manager.activeWallets;
        _transport.sendToService(
          SyncMessage.pong(
            holds: holds,
            synced: active.isNotEmpty && active.every(isWalletFullySynced),
            token: WalletIsolate.token,
          ),
        );
        // The service announces only while it holds the wallets.
        if (holds) _announce();
      case 'released':
        final released = _released;
        if (released != null && !released.isCompleted) released.complete();
    }
  }

  /// Before the app opens its wallets: a periodic run that holds them, and
  /// the service, store and close theirs, and say so. A run that does not
  /// answer within [claimTimeout] has gone (its name is dropped); a service
  /// that does not is restarted, and a fresh one holds nothing. So no two
  /// write the same files.
  Future<void> claim() async {
    _claimedAt = _clock();
    await _ask(WalletHolders.periodicRunName, SyncMessage.hello, claimTimeout);
    // Native wallets an earlier app isolate left open when Android destroyed
    // it (the app was swiped away): closed before this one opens its own.
    await _closeOrphans(exceptToken: WalletIsolate.token);
    if (!await _transport.isServiceRunning()) return;
    final released = _released = Completer<void>();
    _transport.sendToService(SyncMessage.hello);
    try {
      await released.future.timeout(claimTimeout);
    } on TimeoutException {
      log(LogLevel.warn, '[FG sync] the service did not let go; restarting it');
      await _transport.restartService();
    } finally {
      if (identical(_released, released)) _released = null;
    }
  }
}
