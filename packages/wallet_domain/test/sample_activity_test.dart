import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/screenshots.dart';
import 'package:wallet_domain/wallet_domain.dart';

/// `SampleActivity`, the figures the store screenshots show. What matters is
/// that they read as a real wallet would report them: plain fiat values,
/// newest first, dated back from the capture, and a pending receipt counted
/// as locked rather than spendable.
void main() {
  final now = DateTime(2026, 10, 31, 9, 41);

  SampleActivity activity() => SampleActivity(
    decimals: 12,
    price: 500,
    balance: '8.25',
    fee: '0.00003',
    height: 3790200,
    blockTime: const Duration(minutes: 2),
    counterparty: 'counterparty',
    now: now,
    txs: const [
      SampleTx(daysAgo: 4, at: (13, 52), incoming: true, fiat: 125),
      SampleTx(daysAgo: 0, at: (9, 34), incoming: true, fiat: 50, confirmations: 3),
      SampleTx(daysAgo: 1, at: (18, 29), incoming: false, fiat: 25),
    ],
  );

  test('amounts follow from the fiat values at the price', () {
    final amounts = activity().transactions.map((tx) => tx.amountBaseUnits).toList();
    expect(amounts, [
      decimalToBaseUnits('0.1', 12),
      decimalToBaseUnits('0.05', 12),
      decimalToBaseUnits('0.25', 12),
    ]);
  });

  test('transactions come newest first, at their day and time', () {
    final times = activity().transactions
        .map((tx) => DateTime.fromMillisecondsSinceEpoch(tx.timestamp * 1000))
        .toList();
    expect(times, [
      DateTime(2026, 10, 31, 9, 34),
      DateTime(2026, 10, 30, 18, 29),
      DateTime(2026, 10, 27, 13, 52),
    ]);
  });

  test('a pending receipt is locked, the rest is spendable', () {
    final a = activity();
    expect(a.total, decimalToBaseUnits('8.25', 12));
    expect(a.unlocked, decimalToBaseUnits('8.15', 12));
    expect(a.transactions.first.confirmations, 3);
    expect(a.transactions[1].confirmations, greaterThan(10));
  });

  test('only sends carry the fee and a recipient', () {
    final [received, sent, _] = activity().transactions;
    expect(received.direction, txDirectionIncoming);
    expect(received.feeBaseUnits, BigInt.zero);
    expect(received.recipients, isEmpty);
    expect(sent.direction, txDirectionOutgoing);
    expect(sent.feeBaseUnits, decimalToBaseUnits('0.00003', 12));
    expect(sent.recipients.single.address, 'counterparty');
  });
}
