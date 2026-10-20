import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

/// Where the isolates that can hold the wallets answer one another, by name
/// across the process (`IsolateNameServer`): the app ([appName]), the
/// Continuous Sync service while it holds them ([serviceName]), and a periodic
/// Background sync run while it holds them ([periodicRunName]). The app and the
/// service also talk over the plugin's channel ([SyncHandoff]).
///
/// Every holder runs in one Android process when the app is alive, where
/// wallet2's file locks never exclude one another; two holders would be two
/// writers on the same files. So the periodic run skips while the app holds
/// them, and the app asks a run that holds them to let go before it opens its
/// own.
abstract final class WalletHolders {
  /// The app isolate: answers `{op: holds?}` with `{op: holds, holds: bool}`.
  static const appName = 'wallet_core.app_holder';

  /// A periodic run while it holds the wallets: answers `{op: hello}` with
  /// `{op: released}` once it has stored and closed them.
  static const periodicRunName = 'wallet_core.periodic_run';

  /// The Continuous Sync service while it holds the wallets: answers
  /// `{op: holds?}` with `{op: holds, holds: true}`, so a periodic run skips.
  static const serviceName = 'wallet_core.service_holder';

  static const holdsQuery = {'op': 'holds?'};

  /// Sends [message] to the isolate registered under [name] with a port to
  /// answer on, and waits up to [timeout] for the answer. Null when nobody is
  /// registered or nobody answered; a name left behind by an isolate that has
  /// gone is then removed, so the next ask does not wait for it again.
  static Future<Object?> ask(
    String name,
    Map<String, Object> message, {
    required Duration timeout,
  }) async {
    final port = IsolateNameServer.lookupPortByName(name);
    if (port == null) return null;
    final reply = ReceivePort();
    try {
      port.send({...message, 'reply': reply.sendPort});
      return await reply.first.timeout(timeout);
    } on TimeoutException {
      unregister(name, port);
      return null;
    } finally {
      reply.close();
    }
  }

  /// Registers [port] under [name], replacing whatever was there.
  static void register(String name, SendPort port) {
    IsolateNameServer.removePortNameMapping(name);
    IsolateNameServer.registerPortWithName(port, name);
  }

  /// Removes [name] if it still points at [port], and leaves anyone else's.
  static void unregister(String name, SendPort port) {
    if (IsolateNameServer.lookupPortByName(name) == port) {
      IsolateNameServer.removePortNameMapping(name);
    }
  }

  /// Answers [request] (a message [ask] sent) with [answer].
  static void answer(Object? request, Map<String, Object> answer) {
    if (request is Map && request['reply'] is SendPort) {
      (request['reply'] as SendPort).send(answer);
    }
  }
}
