import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:wallet_domain/wallet_domain.dart' show WalletIsolate;
import 'package:wallet_infra/wallet_infra.dart';

import 'ffi_monero_backend.dart';
import 'monero_backend.dart';

/// The native Monero wallets the app has open, listed in a file beside them
/// with the process id and the opening isolate's token
/// ([WalletIsolate.token]). Android only.
///
/// Android destroys the app's isolate when the user swipes the app away, and
/// nothing in it closes its native wallets, while Continuous Sync keeps the
/// process alive. Each such wallet would keep its refresh thread running and
/// its keys in memory, with nothing left to close it. Whoever takes the
/// wallets next in this process closes them ([closeOrphanedMoneroWallets]).
///
/// The process id keeps a list a previous process left behind from being acted
/// on: its handles are addresses in memory that no longer exists. An entry
/// comes off before its wallet closes, so an isolate destroyed in between
/// leaks a wallet rather than leaving it to be closed twice. Reads and writes
/// are synchronous, on a file of a few lines, so one isolate's never
/// interleave. Only the app's own (attended) wallets are listed; a background
/// run and the service close theirs themselves.
abstract final class NativeWalletRegistry {
  static const fileName = 'native_wallets.json';

  /// Off except on Android, where a process outlives the app's isolate.
  @visibleForTesting
  static bool enabled = Platform.isAndroid;

  /// The process id; replaced in tests.
  @visibleForTesting
  static int Function() processId = () => pid;

  // Resolved by the first [add]: an isolate that listed nothing has nothing to
  // take off.
  static String? _path;

  static Future<String> _resolvePath() async => _path ??= '${(await getAppDir()).path}/$fileName';

  /// Lists [wallet], opened through [manager], as this isolate's. Await it
  /// before the wallet can be closed.
  static Future<void> add(NativeHandle manager, NativeHandle wallet) async {
    if (!enabled) return;
    final path = await _resolvePath();
    _write(path, [
      for (final e in _read(path))
        if (e.wallet != wallet.id) e,
      (token: WalletIsolate.token, manager: manager.id, wallet: wallet.id),
    ]);
  }

  /// Takes [wallet] off the list. Synchronous, so it is done before the close
  /// that follows it.
  static void remove(NativeHandle wallet) {
    final path = _path;
    if (!enabled || path == null) return;
    _write(path, [
      for (final e in _read(path))
        if (e.wallet != wallet.id) e,
    ]);
  }

  /// Takes off the list, and returns, the wallets of this process's other
  /// isolates than this one and [exceptToken]'s (a live isolate's): the caller
  /// closes them.
  static Future<List<({int manager, int wallet})>> takeOrphans({String? exceptToken}) async {
    if (!enabled) return const [];
    final path = await _resolvePath();
    bool live(_Entry e) => e.token == WalletIsolate.token || e.token == exceptToken;
    final entries = _read(path);
    final orphans = [
      for (final e in entries)
        if (!live(e)) (manager: e.manager, wallet: e.wallet),
    ];
    if (orphans.isNotEmpty) {
      _write(path, [
        for (final e in entries)
          if (live(e)) e,
      ]);
    }
    return orphans;
  }

  /// This process's entries; none from a list another process left, or one
  /// that cannot be read.
  static List<_Entry> _read(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return const [];
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map || json['pid'] != processId()) return const [];
      return [
        for (final w in json['wallets'] as List)
          if (w is Map && w['token'] is String && w['manager'] is int && w['wallet'] is int)
            (token: w['token'] as String, manager: w['manager'] as int, wallet: w['wallet'] as int),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Written beside it and renamed over it, so a reader never sees half a list.
  static void _write(String path, List<_Entry> entries) {
    try {
      final tmp = File('$path.${processId()}.tmp');
      tmp.writeAsStringSync(
        jsonEncode({
          'pid': processId(),
          'wallets': [
            for (final e in entries) {'token': e.token, 'manager': e.manager, 'wallet': e.wallet},
          ],
        }),
        flush: true,
      );
      tmp.renameSync(path);
    } catch (e) {
      log(LogLevel.warn, '[Monero] Could not update the open-wallet list: $e');
    }
  }

  /// Forgets the path an earlier [add] resolved. For tests, whose app folder
  /// changes from one to the next.
  @visibleForTesting
  static void resetForTesting() => _path = null;
}

typedef _Entry = ({String token, int manager, int wallet});

/// Closes the native Monero wallets that app isolates of this process left
/// open when Android destroyed them, other than [exceptToken]'s (a live
/// isolate's) and this isolate's own ([NativeWalletRegistry]). Not stored:
/// a wallet whose isolate died may have been in the middle of anything, and
/// its scan since the last store is simply done again. Install it as
/// `WalletManager.closeOrphanedWallets`.
Future<void> closeOrphanedMoneroWallets({
  String? exceptToken,
  MoneroBackend backend = const FfiMoneroBackend(),
}) async {
  final orphans = await NativeWalletRegistry.takeOrphans(exceptToken: exceptToken);
  for (final o in orphans) {
    try {
      await backend.closeWallet(NativeHandle(o.manager), NativeHandle(o.wallet), store: false);
    } catch (e) {
      log(LogLevel.warn, '[Monero] Could not close a wallet a destroyed isolate left open: $e');
    }
  }
  if (orphans.isNotEmpty) {
    log(LogLevel.info, '[Monero] Closed ${orphans.length} wallets a destroyed isolate left open.');
  }
}
