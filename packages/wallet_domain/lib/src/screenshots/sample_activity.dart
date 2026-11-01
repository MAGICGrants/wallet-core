import 'dart:math';

import '../amounts.dart';
import '../crypto_wallet.dart' show txDirectionIncoming, txDirectionOutgoing;
import '../tx/tx_details.dart';

/// One transaction of a [SampleActivity]: when it happened, which way it went,
/// and what it was worth.
class SampleTx {
  const SampleTx({
    required this.daysAgo,
    required this.at,
    required this.incoming,
    required this.fiat,
    this.confirmations,
  });

  /// The day it happened, counted back from the capture's (0 is that day).
  final int daysAgo;

  /// The time of day it happened, as (hour, minute).
  final (int, int) at;

  final bool incoming;

  /// Its worth at [SampleActivity.price]. The coin amount is derived from it,
  /// so the fiat column reads as plain figures ($182.00, $47.50).
  final double fiat;

  /// Null for a settled transaction; a number below
  /// [SampleActivity]'s `requiredConfirmations` shows it as pending, and its
  /// amount as the balance still locked.
  final int? confirmations;
}

/// A fixed balance and history for a store screenshot: plausible, the same on
/// every run, and dated back from the moment of capture.
class SampleActivity {
  SampleActivity({
    required this.decimals,
    required this.price,
    required String balance,
    required String fee,
    required List<SampleTx> txs,
    required this.height,
    required Duration blockTime,
    required String counterparty,
    int requiredConfirmations = 10,
    int shownDigits = 8,
    int seed = 1,
    DateTime? now,
  }) : total = decimalToBaseUnits(balance, decimals),
       feeBaseUnits = decimalToBaseUnits(fee, decimals) {
    final at = now ?? DateTime.now();
    final random = Random(seed);
    DateTime when(SampleTx tx) =>
        DateTime(at.year, at.month, at.day - tx.daysAgo, tx.at.$1, tx.at.$2);
    final sorted = [...txs]..sort((a, b) => when(b).compareTo(when(a)));
    var pending = BigInt.zero;
    for (final (i, tx) in sorted.indexed) {
      final amount = amountFor(tx.fiat, shownDigits: shownDigits);
      final blocks = at.difference(when(tx)).inSeconds ~/ max(blockTime.inSeconds, 1);
      final confirmations = tx.confirmations ?? blocks;
      if (tx.incoming && confirmations < requiredConfirmations) pending += amount;
      transactions.add(
        TxDetails(
          index: i,
          direction: tx.incoming ? txDirectionIncoming : txDirectionOutgoing,
          hash: List.generate(
            32,
            (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join(),
          amountBaseUnits: amount,
          feeBaseUnits: tx.incoming ? BigInt.zero : feeBaseUnits,
          recipients: tx.incoming ? const [] : [TxRecipient(counterparty, amount)],
          accountIndex: 0,
          subaddrIndexList: [tx.incoming ? i + 1 : 0],
          timestamp: when(tx).millisecondsSinceEpoch ~/ 1000,
          height: height - blocks,
          confirmations: confirmations,
          key: '',
        ),
      );
    }
    unlocked = total - pending;
  }

  final int decimals;

  /// The coin's price in the shown currency, also handed to the app as its
  /// fiat rate (`FiatRates.fixedRates`) so every figure agrees.
  final double price;

  /// The chain height the wallet reports as synced to.
  final int height;

  final BigInt total;
  late final BigInt unlocked;

  /// The network fee on each outgoing transaction and on a send's
  /// confirmation.
  final BigInt feeBaseUnits;

  /// Newest first, as wallets report them.
  final List<TxDetails> transactions = [];

  /// The coin amount worth [fiat] at [price], kept to [shownDigits] decimals.
  BigInt amountFor(double fiat, {int shownDigits = 8}) =>
      decimalToBaseUnits((fiat / price).toStringAsFixed(min(shownDigits, decimals)), decimals);
}
