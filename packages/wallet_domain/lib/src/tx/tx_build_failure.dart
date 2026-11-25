/// Why a wallet could not build a transaction, as far as it can tell.
///
/// Only causes a Send form can say something useful about get their own value.
/// Everything else is [other], and the backend's reason goes to the log.
enum TxBuildProblem {
  /// The wallet had no working connection to its server while building. Fees,
  /// decoys and (for LWS) the login all come from the server, so nothing can be
  /// built until it connects. The usual case is a payment link that opens the
  /// app straight onto a filled-in Send form before the connection is up.
  notConnected,

  /// The wallet could not check what its server said about the coins this
  /// transaction would spend, so it signed nothing. Bitcoin checks each coin's
  /// value and script against the transaction that created it, because a
  /// signature commits to the value the wallet was told; it stops when the
  /// server will not show that transaction or the transaction disagrees. Retrying
  /// can help with a flaky server; a server that keeps doing it should be
  /// replaced.
  coinsNotVerified,

  /// Anything else.
  other,
}

/// Thrown by `createTx` when the wallet could not build the transaction.
///
/// Like [BroadcastFailure], it carries a classification for the app to word,
/// not text to show: [detail] is the backend's own reason, which can quote a
/// server or a node. It stays in [toString] for the log and for callers that
/// still match on it (the apps find "Unlocked funds too low" that way).
class TxBuildFailure implements Exception {
  const TxBuildFailure(this.problem, {this.detail = ''});

  final TxBuildProblem problem;

  /// The backend's own reason; for the log, not for the screen.
  final String detail;

  @override
  String toString() => 'TxBuildFailure(${problem.name})${detail.isEmpty ? '' : ': $detail'}';
}
