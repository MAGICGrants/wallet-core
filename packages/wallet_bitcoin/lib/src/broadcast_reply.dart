import 'dart:async';

import 'package:wallet_domain/wallet_domain.dart';

import 'bitcoin_txid.dart';

/// Classifies what an Electrum server said in reply to
/// `blockchain.transaction.broadcast`.
///
/// A pure function on purpose, so every branch is testable without a socket, a
/// client or a wallet.
///
/// Returns the txid the server reported. Throws [BroadcastFailure] otherwise,
/// with the outcome classified; the caller must still check the returned value
/// against the transaction's own id, because a txid-shaped answer is not
/// necessarily *our* txid.
String classifyBroadcastReply(Object? result) {
  if (result is String && isTxidShaped(result)) return result;

  // A non-txid string is the interesting case, and the one that produced the
  // bug: several ElectrumX builds put the daemon's rejection text in `result`
  // rather than in `error`, so `"sandbox error: dust"` was returned as a
  // transaction id, became a cache key, and became a receipt in the user's
  // history. The text quotes our own transaction back, so it is classified here
  // rather than carried anywhere.
  if (result is String) {
    if (looksAlreadyKnown(result)) {
      throw const BroadcastFailure(
        BroadcastOutcome.alreadyKnown,
        detail: 'the server already has this transaction',
      );
    }
    throw const BroadcastFailure(
      BroadcastOutcome.rejected,
      detail: 'the server answered with something that is not a transaction id',
    );
  }

  throw const BroadcastFailure(
    BroadcastOutcome.rejected,
    detail: 'the server answered with a non-string reply',
  );
}

/// Sorts a thrown broadcast error into "it is in the network", "it is not", and
/// "the bytes went out and we never heard back".
///
/// [isDisconnect] is injected so this stays free of the client's own error
/// predicate, and so a test can drive the third case directly.
BroadcastFailure classifyBroadcastError(
  Object error, {
  required bool Function(Object) isDisconnect,
}) {
  if (error is BroadcastFailure) return error;

  // Nothing came back. We cannot tell "never sent" from "sent, reply lost", and
  // must not guess: calling it rejected invites a double-send, calling it
  // accepted invites a false receipt. This third outcome had no representation
  // at all; a socket that dropped after the frame went out left no record.
  if (error is TimeoutException || isDisconnect(error)) {
    return const BroadcastFailure(
      BroadcastOutcome.unknown,
      detail: 'the connection ended before the server answered',
    );
  }

  if (looksAlreadyKnown(error.toString())) {
    return const BroadcastFailure(
      BroadcastOutcome.alreadyKnown,
      detail: 'the server already has this transaction',
    );
  }

  return const BroadcastFailure(
    BroadcastOutcome.rejected,
    detail: 'the server refused the transaction',
  );
}

/// Whether a server's complaint means "I already have this".
///
/// Worth telling apart from a rejection: the transaction *is* in the network, so
/// reporting failure would push a user into re-sending a payment that has
/// already gone out. These are Bitcoin Core's `AlreadyKnown` rejection strings
/// and the ElectrumX text that wraps them.
bool looksAlreadyKnown(String text) {
  final t = text.toLowerCase();
  return t.contains('already in mempool') ||
      t.contains('already-in-mempool') ||
      t.contains('txn-already-known') ||
      t.contains('txn-already-in-mempool') ||
      t.contains('already known') ||
      t.contains('already in block chain') ||
      t.contains('transaction already in chain');
}
