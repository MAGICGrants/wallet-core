import 'package:intl/intl.dart';
import 'package:wallet_domain/wallet_domain.dart';

import 'tx_activity_row.dart' show TxEntry;

/// Newest-first merge of every wallet's history into one multi-coin timeline.
List<TxEntry> combinedTxTimeline(WalletManager manager) => <TxEntry>[
  for (final asset in manager.allWallets)
    for (final tx in asset.txHistory) (tx: tx, asset: asset),
]..sort((a, b) => b.tx.timestamp.compareTo(a.tx.timestamp));

/// Interleaves `d MMMM` day-label headers (uppercase [String]s) among [items],
/// which must already be newest-first; [epochSeconds] reads each item's unix
/// timestamp. Headers and entries share one list so every screen groups by day
/// identically.
List<Object> withDayHeaders<T extends Object>(List<T> items, int Function(T) epochSeconds) {
  final rows = <Object>[];
  DateTime? lastDay;
  for (final item in items) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochSeconds(item) * 1000);
    final day = DateTime(d.year, d.month, d.day);
    if (day != lastDay) {
      rows.add(DateFormat('d MMMM').format(day).toUpperCase());
      lastDay = day;
    }
    rows.add(item);
  }
  return rows;
}
