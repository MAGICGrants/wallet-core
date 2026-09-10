import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_bitcoin/wallet_bitcoin.dart';
import 'package:wallet_domain/wallet_domain.dart';

/// The four outcomes this file pins used to be two: "a string came back" and
/// "something threw". A rejection was recorded as sent, and a connection that
/// died after the bytes went out left no record at all.
void main() {
  const txid = '3f4e2c9b8a7d6e5f4c3b2a1908f7e6d5c4b3a29180f7e6d5c4b3a29180f7e6d5';

  BroadcastOutcome outcomeOf(void Function() body) {
    try {
      body();
    } on BroadcastFailure catch (f) {
      return f.outcome;
    }
    return BroadcastOutcome.accepted;
  }

  group('classifyBroadcastReply', () {
    test('a txid-shaped reply is returned', () {
      expect(classifyBroadcastReply(txid), txid);
    });

    test('a rejection message in `result` is a rejection, not a txid', () {
      // The actual bug: ElectrumX builds that put the daemon's complaint in
      // `result` rather than `error`. Every one of these was previously accepted
      // as a transaction id and written into the user's history as a payment.
      for (final reply in [
        'sandbox error: dust',
        '258: txn-mempool-conflict',
        'the transaction was rejected by network rules. (code 64)',
        'bad-txns-inputs-missingorspent',
        '',
      ]) {
        expect(
          outcomeOf(() => classifyBroadcastReply(reply)),
          BroadcastOutcome.rejected,
          reason: reply,
        );
      }
    });

    test('"already known" in `result` is not a rejection', () {
      // Telling these apart matters: reporting failure would push the user into
      // re-sending a payment that is already in the network.
      for (final reply in [
        'txn-already-in-mempool',
        'Transaction already in block chain',
        '257: txn-already-known',
      ]) {
        expect(
          outcomeOf(() => classifyBroadcastReply(reply)),
          BroadcastOutcome.alreadyKnown,
          reason: reply,
        );
      }
    });

    test('a non-string reply is a rejection', () {
      for (final reply in [null, 0, false, <String>[], <String, String>{}]) {
        expect(
          outcomeOf(() => classifyBroadcastReply(reply)),
          BroadcastOutcome.rejected,
          reason: '$reply',
        );
      }
    });

    test('the failure never carries the server text', () {
      // A rejection quotes our own transaction back at us. The classification
      // travels; the text does not.
      const nosy = 'rejected: 0200000001cafebabe… pays to bc1qsecretaddress';
      try {
        classifyBroadcastReply(nosy);
        fail('must throw');
      } on BroadcastFailure catch (f) {
        expect(f.toString(), isNot(contains('cafebabe')));
        expect(f.toString(), isNot(contains('bc1qsecretaddress')));
        expect(f.toString(), contains('rejected'));
      }
    });
  });

  group('classifyBroadcastError', () {
    BroadcastFailure classify(Object e, {bool disconnect = false}) =>
        classifyBroadcastError(e, isDisconnect: (_) => disconnect);

    test('a timeout is unknown, not rejected', () {
      // The distinction the code did not have. Rejected invites a double-send;
      // accepted invites a false receipt. Neither is honest here.
      expect(classify(TimeoutException('broadcast')).outcome, BroadcastOutcome.unknown);
    });

    test('a dropped connection is unknown', () {
      expect(
        classify(Exception('socket closed'), disconnect: true).outcome,
        BroadcastOutcome.unknown,
      );
    });

    test('a JSON-RPC error saying "already known" is alreadyKnown', () {
      expect(
        classify(Exception('ElectrumError: {code: 257, message: txn-already-known}')).outcome,
        BroadcastOutcome.alreadyKnown,
      );
    });

    test('any other server error is a rejection', () {
      expect(
        classify(Exception('ElectrumError: {code: 1, message: bad-txns-in-belowout}')).outcome,
        BroadcastOutcome.rejected,
      );
    });

    test('an already-classified failure passes through unchanged', () {
      const original = BroadcastFailure(BroadcastOutcome.alreadyKnown, detail: 'x');
      expect(classify(original), same(original));
    });
  });

  group('BroadcastOutcome.isInNetwork', () {
    test('only accepted and alreadyKnown mean the transaction is out there', () {
      expect(BroadcastOutcome.accepted.isInNetwork, isTrue);
      expect(BroadcastOutcome.alreadyKnown.isInNetwork, isTrue);
      expect(BroadcastOutcome.rejected.isInNetwork, isFalse);
      // The one that must never be mistaken for success.
      expect(BroadcastOutcome.unknown.isInNetwork, isFalse);
    });
  });
}
