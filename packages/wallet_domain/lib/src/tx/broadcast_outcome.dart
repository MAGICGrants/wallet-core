/// What actually happened when a signed transaction was handed to a server.
///
/// This exists because the codebase collapsed four outcomes into two. Electrum's
/// `commitTx` accepted *any* string reply as the txid and reported success, so a
/// rejection was recorded as "sent"; and the one case with no record at all,
/// the connection dying after the bytes went out, looked identical to never
/// having tried.
///
/// The distinction is not cosmetic. A user who believes funds moved when they
/// did not takes irreversible action off that belief: releasing goods, treating
/// a debt as settled, or re-sending and paying twice. [rejected] and
/// [unknown] must not read the same, and neither may read as [accepted].
enum BroadcastOutcome {
  /// The server took the transaction and it is now in its mempool.
  accepted,

  /// The server already had it; a re-broadcast, or a first attempt whose reply
  /// was lost. The transaction *is* in the network, so this is a success for
  /// every purpose except "we are the reason it got there".
  alreadyKnown,

  /// The server refused it. The transaction is not in the network and the funds
  /// have not moved; the inputs are still spendable.
  rejected,

  /// The bytes went out and no answer came back: a dropped socket, a timeout, a
  /// reply that did not parse. The transaction may or may not be in the network.
  ///
  /// The only outcome that must not be resolved by guessing. Record it, show it
  /// as unresolved, and let the next sync settle it: treating it as [rejected]
  /// invites a double-send, and treating it as [accepted] invites the false
  /// receipt.
  unknown;

  /// Whether the transaction is believed to be in the network.
  bool get isInNetwork =>
      this == BroadcastOutcome.accepted || this == BroadcastOutcome.alreadyKnown;
}

/// Thrown when a broadcast did not demonstrably succeed.
///
/// Carries the classification rather than the server's own text: an Electrum
/// error message is attacker-influenced (a rejection quotes the daemon, which
/// quotes the transaction), so it is summarised into [outcome] here and only the
/// classification travels.
class BroadcastFailure implements Exception {
  const BroadcastFailure(this.outcome, {this.detail = ''});

  final BroadcastOutcome outcome;

  /// Short, non-quoting description of *why*; safe to log and to show.
  final String detail;

  @override
  String toString() => 'BroadcastFailure(${outcome.name})${detail.isEmpty ? '' : ': $detail'}';
}
