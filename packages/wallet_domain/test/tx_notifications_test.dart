import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';

/// Covers `decideTxNotifications`.
///
/// The mempool and reorg group is the reason this logic is not just "compare
/// timestamps": a transaction's timestamp moves when it is mined, so a timestamp
/// alone either re-announces a payment on confirmation or, if the cutoff is
/// advanced from an unconfirmed transaction, silences blocks the wallet has not
/// scanned yet.

/// A transaction as a wallet reports it. [height] of -1 means unconfirmed.
TxDetails tx({
  required String hash,
  required int timestamp,
  int direction = txDirectionIncoming,
  int height = 100,
}) => TxDetails(
  index: 0,
  direction: direction,
  hash: hash,
  amountBaseUnits: BigInt.from(1500000000000),
  feeBaseUnits: BigInt.zero,
  recipients: const [],
  accountIndex: 0,
  subaddrIndexList: const [0],
  timestamp: timestamp,
  height: height,
  confirmations: height > 0 ? 10 : 0,
  key: '',
);

/// A transaction with an amount that matters, and an [index] so several entries
/// can share one hash, which is how a coin reports both sides of a self-send.
TxDetails amountTx({
  required String hash,
  required int timestamp,
  required BigInt amount,
  int direction = txDirectionIncoming,
  int height = 100,
  int index = 0,
}) => TxDetails(
  index: index,
  direction: direction,
  hash: hash,
  amountBaseUnits: amount,
  feeBaseUnits: BigInt.zero,
  recipients: const [],
  accountIndex: 0,
  subaddrIndexList: const [0],
  timestamp: timestamp,
  height: height,
  confirmations: height > 0 ? 10 : 0,
  key: '',
);

/// Wallets hand history back newest first.
List<TxDetails> newestFirst(List<TxDetails> txs) =>
    [...txs]..sort((a, b) => b.timestamp.compareTo(a.timestamp));

List<String> hashesOf(List<TxDetails> txs) => txs.map((t) => t.hash).toList();

void main() {
  group('decideTxNotifications', () {
    test('announces an incoming transaction newer than the cutoff', () {
      final decision = decideTxNotifications(
        txHistory: newestFirst([tx(hash: 'a', timestamp: 1000)]),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(hashesOf(decision.toAnnounce), ['a']);
      expect(decision.cutoff, 1000);
      expect(decision.announcedHashes, ['a']);
    });

    test('ignores outgoing transactions', () {
      final decision = decideTxNotifications(
        txHistory: newestFirst([tx(hash: 'out', timestamp: 1000, direction: txDirectionOutgoing)]),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(decision.toAnnounce, isEmpty);
      // The cutoff still moves: it tracks what has been seen, not what was said.
      expect(decision.cutoff, 1000);
    });

    test('ignores anything at or before the cutoff', () {
      final decision = decideTxNotifications(
        txHistory: newestFirst([
          tx(hash: 'old', timestamp: 400),
          tx(hash: 'exactly-at', timestamp: 500),
        ]),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(decision.toAnnounce, isEmpty);
      expect(decision.cutoff, 500);
    });

    test('announces a burst oldest first', () {
      final decision = decideTxNotifications(
        txHistory: newestFirst([
          tx(hash: 'c', timestamp: 3000),
          tx(hash: 'a', timestamp: 1000),
          tx(hash: 'b', timestamp: 2000),
        ]),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(hashesOf(decision.toAnnounce), ['a', 'b', 'c']);
      expect(decision.cutoff, 3000);
    });

    test('a second pass over the same history announces nothing', () {
      final history = newestFirst([tx(hash: 'a', timestamp: 1000)]);

      final first = decideTxNotifications(
        txHistory: history,
        cutoff: 500,
        announcedHashes: const [],
      );
      final second = decideTxNotifications(
        txHistory: history,
        cutoff: first.cutoff,
        announcedHashes: first.announcedHashes,
      );

      expect(second.toAnnounce, isEmpty);
      expect(second.cutoff, first.cutoff);
    });

    test('nothing is announced when the history is empty', () {
      final decision = decideTxNotifications(
        txHistory: const [],
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(decision.toAnnounce, isEmpty);
      expect(decision.cutoff, 500);
    });

    test('the cutoff never moves backwards', () {
      final decision = decideTxNotifications(
        txHistory: newestFirst([tx(hash: 'old', timestamp: 100)]),
        cutoff: 9000,
        announcedHashes: const [],
      );

      expect(decision.cutoff, 9000);
    });
  });

  group('only a transaction that increased the balance is a receipt', () {
    /// One transaction's worth of history, as a coin that reports both sides of a
    /// self-send hands it over: entries sharing a hash, summed per direction.
    List<TxDetails> oneTx({
      required BigInt sent,
      required List<BigInt> received,
      String hash = 'self',
      int timestamp = 1000,
    }) => newestFirst([
      amountTx(hash: hash, timestamp: timestamp, direction: txDirectionOutgoing, amount: sent),
      for (final (i, amount) in received.indexed)
        amountTx(hash: hash, timestamp: timestamp, amount: amount, index: i),
    ]);

    test('a self-send is not announced, and the two sides are exactly equal', () {
      // The knife-edge this rule turns on. wallet2 reports the outgoing amount
      // with the change and the fee already taken out, so it equals what arrived
      // to the piconero; `>=` here would announce every self-send.
      final decision = decideTxNotifications(
        txHistory: oneTx(sent: BigInt.from(500000000000), received: [BigInt.from(500000000000)]),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(decision.toAnnounce, isEmpty);
      // Still seen: the cutoff moves, so it is not reconsidered next tick either.
      expect(decision.cutoff, 1000);
      expect(decision.announcedHashes, isEmpty, reason: 'the 50-hash cap is for real receipts');
    });

    test('a pocketsend across several of our own outputs is not announced', () {
      // One transaction paying us in three places. Each output on its own is
      // smaller than what left, so only the sum answers the question.
      final decision = decideTxNotifications(
        txHistory: oneTx(
          sent: BigInt.from(900000000000),
          received: [
            BigInt.from(300000000000),
            BigInt.from(300000000000),
            BigInt.from(300000000000),
          ],
        ),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(decision.toAnnounce, isEmpty);
    });

    test('change coming back from a payment is not a receipt', () {
      // The everyday case: spend a large output, pay a little, get most of it
      // back. The returned change dwarfs the payment, which is exactly why
      // "something arrived" is the wrong question to ask.
      final decision = decideTxNotifications(
        txHistory: oneTx(sent: BigInt.from(2000000000000), received: [BigInt.from(1899670000000)]),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(decision.toAnnounce, isEmpty);
    });

    test('a transaction we contributed to that still paid us is announced', () {
      // The collaborative shape; a payjoin, where the wallet supplies an input
      // and is also the party being paid. The balance went up, so this is a real
      // receipt and suppressing it would lose a payment.
      final decision = decideTxNotifications(
        txHistory: oneTx(sent: BigInt.from(100000000000), received: [BigInt.from(600000000000)]),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(hashesOf(decision.toAnnounce), ['self']);
    });

    test('an ordinary receipt is unaffected by unrelated sends', () {
      // Guards the grouping: the totals are per transaction, so a send sitting
      // in the same history must not net against a payment from someone else.
      final decision = decideTxNotifications(
        txHistory: newestFirst([
          amountTx(
            hash: 'our-send',
            timestamp: 900,
            direction: txDirectionOutgoing,
            amount: BigInt.from(5000000000000),
          ),
          amountTx(hash: 'their-payment', timestamp: 1000, amount: BigInt.from(1000000)),
        ]),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(hashesOf(decision.toAnnounce), ['their-payment']);
    });

    test('the two sides are matched case-insensitively', () {
      // Hashes are hex, and nothing guarantees which case a backend echoes.
      final decision = decideTxNotifications(
        txHistory: newestFirst([
          amountTx(
            hash: 'ABCDEF',
            timestamp: 1000,
            direction: txDirectionOutgoing,
            amount: BigInt.from(500000000000),
          ),
          amountTx(hash: 'abcdef', timestamp: 1000, amount: BigInt.from(500000000000)),
        ]),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(decision.toAnnounce, isEmpty);
    });

    test('a zero-amount incoming entry is not a receipt', () {
      final decision = decideTxNotifications(
        txHistory: newestFirst([amountTx(hash: 'nothing', timestamp: 1000, amount: BigInt.zero)]),
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(decision.toAnnounce, isEmpty);
    });
  });

  group('mempool and reorg edge cases', () {
    test('a mempool transaction is announced once, not again when mined', () {
      // Seen unconfirmed at t=1000...
      final first = decideTxNotifications(
        txHistory: [tx(hash: 'a', timestamp: 1000, height: -1)],
        cutoff: 500,
        announcedHashes: const [],
      );

      expect(hashesOf(first.toAnnounce), ['a']);
      // An unconfirmed transaction must not drag the cutoff forward.
      expect(first.cutoff, 500);

      // ...then mined into a block stamped later than it was seen.
      final second = decideTxNotifications(
        txHistory: [tx(hash: 'a', timestamp: 1600, height: 3000)],
        cutoff: first.cutoff,
        announcedHashes: first.announcedHashes,
      );

      expect(second.toAnnounce, isEmpty, reason: 'the hash is remembered');
      expect(second.cutoff, 1600);
    });

    test('a block timestamp earlier than when the tx was seen is still not repeated', () {
      final first = decideTxNotifications(
        txHistory: [tx(hash: 'a', timestamp: 1000, height: -1)],
        cutoff: 500,
        announcedHashes: const [],
      );
      final second = decideTxNotifications(
        // Miner clocks drift; a block can be stamped before the tx was seen.
        txHistory: [tx(hash: 'a', timestamp: 900, height: 3000)],
        cutoff: first.cutoff,
        announcedHashes: first.announcedHashes,
      );

      expect(second.toAnnounce, isEmpty);
    });

    test('a dropped transaction that reappears is not announced twice', () {
      final first = decideTxNotifications(
        txHistory: [tx(hash: 'a', timestamp: 1000, height: -1)],
        cutoff: 500,
        announcedHashes: const [],
      );

      // Dropped from the mempool: gone from history entirely.
      final whileGone = decideTxNotifications(
        txHistory: const [],
        cutoff: first.cutoff,
        announcedHashes: first.announcedHashes,
      );

      // Rebroadcast and mined later.
      final back = decideTxNotifications(
        txHistory: [tx(hash: 'a', timestamp: 5000, height: 3100)],
        cutoff: whileGone.cutoff,
        announcedHashes: whileGone.announcedHashes,
      );

      expect(back.toAnnounce, isEmpty);
    });

    test('a reorged-out transaction is not announced again when it returns', () {
      final first = decideTxNotifications(
        txHistory: [tx(hash: 'a', timestamp: 1000, height: 3000)],
        cutoff: 500,
        announcedHashes: const [],
      );
      expect(hashesOf(first.toAnnounce), ['a']);

      // Reorged out and re-mined in a different block, with a new timestamp.
      final after = decideTxNotifications(
        txHistory: [tx(hash: 'a', timestamp: 1200, height: 3001)],
        cutoff: first.cutoff,
        announcedHashes: first.announcedHashes,
      );

      expect(after.toAnnounce, isEmpty);
    });

    test('an unconfirmed tx does not silence older blocks still being scanned', () {
      // A mempool payment is seen while the scanner is far behind the tip.
      final first = decideTxNotifications(
        txHistory: [tx(hash: 'mempool', timestamp: 9000, height: -1)],
        cutoff: 500,
        announcedHashes: const [],
      );
      expect(first.cutoff, 500, reason: 'unconfirmed must not move the cutoff');

      // The scan then reaches an older block holding another payment.
      final second = decideTxNotifications(
        txHistory: newestFirst([
          tx(hash: 'mempool', timestamp: 9000, height: -1),
          tx(hash: 'older-block', timestamp: 4000, height: 2900),
        ]),
        cutoff: first.cutoff,
        announcedHashes: first.announcedHashes,
      );

      expect(hashesOf(second.toAnnounce), ['older-block']);
    });
  });

  group('remembered hashes', () {
    test('are capped, keeping the most recent', () {
      var cutoff = 0;
      var hashes = <String>[];

      // 10 unconfirmed transactions, so the cutoff never advances and the cap
      // is the only thing keeping the list bounded.
      for (var i = 1; i <= 10; i++) {
        final decision = decideTxNotifications(
          txHistory: [tx(hash: 'tx$i', timestamp: i * 100, height: -1)],
          cutoff: cutoff,
          announcedHashes: hashes,
          maxHashes: 3,
        );
        cutoff = decision.cutoff;
        hashes = decision.announcedHashes;
      }

      expect(hashes, ['tx8', 'tx9', 'tx10']);
    });

    test('a hash is not duplicated when the same tx is re-seen', () {
      final first = decideTxNotifications(
        txHistory: [tx(hash: 'a', timestamp: 1000, height: -1)],
        cutoff: 500,
        announcedHashes: const [],
      );
      final second = decideTxNotifications(
        txHistory: [tx(hash: 'a', timestamp: 1000, height: -1)],
        cutoff: first.cutoff,
        announcedHashes: first.announcedHashes,
      );

      expect(second.announcedHashes, ['a']);
    });

    test('the default cap is 50', () => expect(maxRememberedTxHashes, 50));
  });

  group('isTxInABlock', () {
    test('treats -1 and 0 as not in a block', () {
      expect(isTxInABlock(tx(hash: 'a', timestamp: 1, height: -1)), isFalse);
      expect(isTxInABlock(tx(hash: 'a', timestamp: 1, height: 0)), isFalse);
      expect(isTxInABlock(tx(hash: 'a', timestamp: 1, height: 1)), isTrue);
    });

    // The contrast with CryptoWallet.isTxConfirmed needs a wallet, so it lives
    // in tx_notification_store_test.dart.
  });
}
