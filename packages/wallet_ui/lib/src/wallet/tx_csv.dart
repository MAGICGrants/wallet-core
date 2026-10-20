import 'package:wallet_domain/wallet_domain.dart';

import 'tx_activity_row.dart' show TxEntry;

/// The CSV's columns. In English, as are the values, so a spreadsheet or a tax
/// tool reads the file the same whatever language the app is in.
const txCsvHeader = [
  'Date (UTC)',
  'Asset',
  'Blockchain',
  'Direction',
  'Amount',
  'Fee',
  'Fee asset',
  'Status',
  'Confirmations',
  'Height',
  'Addresses',
  'Transaction ID',
];

/// [entries] as CSV (RFC 4180, CRLF line ends), one row per transaction in
/// the order given, under [txCsvHeader].
///
/// Amounts are exact decimals in each asset's own units (no rounding, no
/// fiat), positive, with the direction saying which way they went. The fee is
/// the sender's, so only a sent transaction has one, in its fee asset (ETH for
/// a token on Ethereum). Addresses are where it was received, or who was paid;
/// change is left out. Transaction keys are never written.
String txHistoryCsv(Iterable<TxEntry> entries) {
  final buffer = StringBuffer()..write(_line(txCsvHeader));
  for (final e in entries) {
    buffer.write(_line(_row(e.tx, e.asset)));
  }
  return buffer.toString();
}

List<String> _row(TxDetails tx, CryptoWallet asset) {
  final sent = tx.direction == txDirectionOutgoing;
  return [
    _utc(tx.timestamp),
    asset.coinSymbol,
    asset.blockchainName,
    switch (tx.direction) {
      txDirectionIncoming => 'Received',
      txDirectionOutgoing => 'Sent',
      _ => 'Other',
    },
    decimalAmount(tx.amountBaseUnits, asset.baseUnitDecimals),
    sent ? decimalAmount(tx.feeBaseUnits, asset.feeBaseUnitDecimals) : '',
    sent ? asset.feeCoinSymbol : '',
    switch (tx.status) {
      TxStatus.failed => 'Failed',
      TxStatus.unknown => 'Unknown',
      TxStatus.ok => asset.isTxConfirmed(tx) ? 'Confirmed' : 'Pending',
    },
    '${tx.confirmations}',
    tx.height > 0 ? '${tx.height}' : '',
    [
      for (final r in tx.recipients)
        if (!r.isChange) r.address,
    ].join('; '),
    tx.hash,
  ];
}

/// [units] base units as an exact decimal with [decimals] places, trailing
/// zeros dropped: 1500000000000 at 12 places is `1.5`.
String decimalAmount(BigInt units, int decimals) {
  final sign = units.isNegative ? '-' : '';
  final digits = units.abs().toString();
  if (decimals <= 0) return '$sign$digits';
  final padded = digits.padLeft(decimals + 1, '0');
  final whole = padded.substring(0, padded.length - decimals);
  final fraction = padded.substring(padded.length - decimals).replaceFirst(RegExp(r'0+$'), '');
  return fraction.isEmpty ? '$sign$whole' : '$sign$whole.$fraction';
}

/// `2026-10-17T14:03:05Z`.
String _utc(int epochSeconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}'
      'T${two(d.hour)}:${two(d.minute)}:${two(d.second)}Z';
}

String _line(List<String> fields) => '${fields.map(_field).join(',')}\r\n';

/// One field: quoted when it holds a comma, a quote or a line break, with its
/// quotes doubled. A field a spreadsheet would run as a formula (one starting
/// with `=`, `+`, `-`, `@`, a tab or a carriage return) gets a leading `'`, so
/// opening the file runs nothing.
String _field(String value) {
  var v = value;
  if (v.isNotEmpty && '=+-@\t\r'.contains(v[0])) v = "'$v";
  if (v.contains(RegExp(r'[",\r\n]'))) v = '"${v.replaceAll('"', '""')}"';
  return v;
}
