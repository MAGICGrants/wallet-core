import '../crypto_wallet.dart' show txDirectionIncoming;
import 'tx_details.dart';

/// Whether a transaction left the wallet holding more than it did before.
///
/// Change and self-sends both arrive as incoming entries, so "did anything
/// arrive" is the wrong question; this asks whether the balance went up.
///
/// Sums what arrived under this hash against what left, and requires the first
/// to strictly exceed the second. Strictly, because a self-send makes them equal
/// and `>=` would announce every one. `wallet2.cpp` uses the same rule.
///
/// A payjoin still announces correctly: the wallet contributes an input and is
/// genuinely paid.
bool _isNetReceive(TxDetails tx, Map<String, BigInt> received, Map<String, BigInt> sent) {
  final key = tx.hash.toLowerCase();
  return (received[key] ?? BigInt.zero) > (sent[key] ?? BigInt.zero);
}

/// How many announced transaction hashes are remembered. The cutoff covers
/// everything older, so this only has to span transactions near the tip.
const int maxRememberedTxHashes = 50;

/// What to announce, and the state to persist afterwards.
class TxNotificationDecision {
  const TxNotificationDecision({
    required this.toAnnounce,
    required this.cutoff,
    required this.announcedHashes,
  });

  /// Incoming transactions to announce, oldest first.
  final List<TxDetails> toAnnounce;

  /// New value for the cutoff (unix seconds).
  final int cutoff;

  /// New list of remembered hashes, oldest first.
  final List<String> announcedHashes;
}

/// Works out which incoming transactions the user hasn't been told about.
///
/// Needs both pieces of state:
///
/// [cutoff] is a coarse "everything before this is old news" line, so a restored
/// wallet does not announce a backlog.
///
/// [announcedHashes] catches what a timestamp cannot. A transaction's timestamp
/// moves when it is mined, so a payment announced from the mempool would be
/// announced again on confirmation, and likewise one dropped and later reappearing.
///
/// Only confirmed transactions advance the cutoff. An unconfirmed one carries
/// roughly the current time, which can sit ahead of blocks still being scanned.
///
/// Third condition: only a transaction that increased the balance counts. See
/// [_isNetReceive].
TxNotificationDecision decideTxNotifications({
  required List<TxDetails> txHistory,
  required int cutoff,
  required List<String> announcedHashes,
  int maxHashes = maxRememberedTxHashes,
}) {
  final seen = announcedHashes.toSet();

  // Totals per transaction, not per entry: one transaction can arrive as several
  // history entries; Monero reports a self-send between accounts as an outgoing
  // one and an incoming one under a single hash, and a send to several of the
  // wallet's own addresses as one per output. What matters is the transaction.
  final received = <String, BigInt>{};
  final sent = <String, BigInt>{};
  for (final tx in txHistory) {
    final key = tx.hash.toLowerCase();
    final into = tx.direction == txDirectionIncoming ? received : sent;
    into[key] = (into[key] ?? BigInt.zero) + tx.amountBaseUnits;
  }

  final toAnnounce =
      txHistory
          .where(
            (tx) =>
                tx.direction == txDirectionIncoming &&
                tx.timestamp > cutoff &&
                !seen.contains(tx.hash) &&
                _isNetReceive(tx, received, sent),
          )
          .toList()
        // Oldest first, so a burst is announced in the order it happened.
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

  var newCutoff = cutoff;

  for (final tx in txHistory) {
    if (isTxInABlock(tx) && tx.timestamp > newCutoff) {
      newCutoff = tx.timestamp;
    }
  }

  final hashes = [
    ...announcedHashes.where((hash) => !toAnnounce.any((tx) => tx.hash == hash)),
    ...toAnnounce.map((tx) => tx.hash),
  ];

  return TxNotificationDecision(
    toAnnounce: toAnnounce,
    cutoff: newCutoff,
    announcedHashes: hashes.length > maxHashes ? hashes.sublist(hashes.length - maxHashes) : hashes,
  );
}

/// True when a transaction is in a block at all.
///
/// Deliberately strict, and deliberately **not** `CryptoWallet.isTxConfirmed`:
/// that one asks "confirmed enough to spend" and consults the coin's
/// `requiredConfirmations`, which for Ethereum mainnet is 12 blocks. Waiting
/// that long to advance the cutoff would leave a wide window in which a
/// re-timestamped transaction is announced twice. What matters here is only
/// whether the timestamp has stopped moving, and that happens at one block.
///
/// Erring the other way, treating an unconfirmed transaction as in a block,
/// would drag the cutoff forward and silence real notifications, while this
/// direction only costs a re-check that [decideTxNotifications] deduplicates by
/// hash anyway.
bool isTxInABlock(TxDetails tx) => tx.height > 0;
