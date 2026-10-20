/// Who holds the wallets while Continuous Sync runs: the app or the service,
/// never both.
///
/// Both run in the same Android process, where wallet2's file locks (`fcntl`
/// record locks) never exclude one another. Two holders would be two writers on
/// the same files: the app's main wallet rewrites Monero's view-only copy on
/// every store, under a service scanning that copy. So the two take turns:
///
/// - The app holds whenever its wallets are open (with the keys, or view-only
///   after the spend wallet locked), and announces payments itself.
/// - The service holds otherwise: while the app sits at its lock screen with
///   nothing open, or after Android has closed the app's screen and its isolate
///   with it. It then opens the view-only copies and announces.
/// - Before the app opens its wallets it says [SyncMessage.hello]; the service
///   stores and closes whatever it holds and answers [SyncMessage.released].
/// - Every tick the service says [SyncMessage.ping]; the app answers
///   [SyncMessage.pong] with whether it holds. No answer for a few ticks means
///   the app's isolate is gone, and the service takes over.
class SyncHandoff {
  SyncHandoff({this.missedPongLimit = 2});

  /// Ticks without a [SyncMessage.pong] before the app counts as gone.
  final int missedPongLimit;

  // The app started the service (a toggle, or its own launch), so it is there
  // until it says otherwise or stops answering.
  bool _appHolds = true;
  int _missed = 0;

  /// Whether the service should hold the wallets now.
  bool get serviceShouldHold => !_appHolds || _missed > missedPongLimit;

  /// A repeat tick, as the service sends its [SyncMessage.ping].
  void onTick() => _missed++;

  /// The app answered: it is there, and holds its wallets or not.
  void onPong({required bool appHolds}) {
    _missed = 0;
    _appHolds = appHolds;
  }

  /// The app is about to open its wallets: from here it holds them.
  void onHello() {
    _missed = 0;
    _appHolds = true;
  }
}

/// The messages between the app and the Continuous Sync service, as plain maps
/// (the plugin's channel and isolate port both carry them).
abstract final class SyncMessage {
  static const ping = {'op': 'ping'};
  static const hello = {'op': 'hello'};
  static const released = {'op': 'released'};

  static Map<String, Object> pong({
    required bool holds,
    required bool synced,
    required String token,
  }) => {'op': 'pong', 'holds': holds, 'synced': synced, 'token': token};

  /// The message's kind, or null for anything that is not one of these.
  static String? opOf(Object? data) =>
      data is Map && data['op'] is String ? data['op'] as String : null;
}
