import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_monero/wallet_monero.dart';

/// `get_address_txs` as the view-only check (behind security keys) reads it.
void main() {
  String response(List<Map<String, Object?>> txs) => jsonEncode({
    'total_received': '0',
    'scanned_height': 3200000,
    'scanned_block_height': 3200000,
    'start_height': 0,
    'blockchain_height': 3200005,
    'transactions': txs,
  });

  test('a receipt with nothing spent is incoming', () {
    final parsed = MoneroWallet.parseLwsAddressTxs(
      response([
        {
          'id': 1,
          'hash': 'aa' * 32,
          'timestamp': '2026-10-01T12:00:00Z',
          'total_received': '1500000000000',
          'total_sent': '0',
          'height': 3200001,
          'spent_outputs': <Object?>[],
          'mempool': false,
        },
      ]),
    );
    expect(parsed.scannedHeight, 3200000);
    final tx = parsed.history.single;
    expect(tx.direction, txDirectionIncoming);
    expect(tx.amountBaseUnits, BigInt.parse('1500000000000'));
    expect(tx.height, 3200001);
    expect(tx.confirmations, 5);
    expect(tx.timestamp, DateTime.utc(2026, 10, 1, 12).millisecondsSinceEpoch ~/ 1000);
  });

  test('anything listing spent outputs is never announced as incoming', () {
    // Without the spend key a key image cannot be checked: our own send with
    // change, or someone's ring using our output as a decoy. Both read outgoing.
    final parsed = MoneroWallet.parseLwsAddressTxs(
      response([
        {
          'hash': 'bb' * 32,
          'total_received': '200',
          'total_sent': '1000',
          'height': 3200002,
          'spent_outputs': [
            {'amount': '1000', 'key_image': 'cc' * 32},
          ],
        },
      ]),
    );
    expect(parsed.history.single.direction, txDirectionOutgoing);
  });

  test('a mempool receipt has no height and is still incoming', () {
    final parsed = MoneroWallet.parseLwsAddressTxs(
      response([
        {'hash': 'dd' * 32, 'total_received': 7, 'total_sent': 0, 'mempool': true},
      ]),
    );
    final tx = parsed.history.single;
    expect(tx.direction, txDirectionIncoming);
    expect(tx.height, -1);
    expect(tx.confirmations, 0);
  });

  test('the notifier announces exactly the new receipt', () {
    final parsed = MoneroWallet.parseLwsAddressTxs(
      response([
        {
          'hash': 'ee' * 32,
          'timestamp': '2026-10-02T00:00:00Z',
          'total_received': '5',
          'total_sent': '0',
          'height': 3200003,
          'spent_outputs': <Object?>[],
        },
        {
          'hash': 'ff' * 32,
          'timestamp': '2026-09-01T00:00:00Z',
          'total_received': '5',
          'total_sent': '0',
          'height': 3100000,
          'spent_outputs': <Object?>[],
        },
      ]),
    );
    final decision = decideTxNotifications(
      txHistory: parsed.history,
      cutoff: DateTime.utc(2026, 9, 15).millisecondsSinceEpoch ~/ 1000,
      announcedHashes: const [],
    );
    expect(decision.toAnnounce.map((t) => t.hash), ['ee' * 32]);
  });
}
