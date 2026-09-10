import 'dart:convert';

import 'package:wallet_infra/wallet_infra.dart';

/// One output of a transaction.
///
/// [amountBaseUnits] is in the coin's smallest unit: piconero, satoshi, wei.
/// Never a `double`. JSON numbers are IEEE doubles, so the value is
/// serialised as a **string**; writing it as a number would reintroduce the
/// precision loss this type exists to prevent.
class TxRecipient {
  final String address;
  final BigInt amountBaseUnits;
  final bool isChange;

  // Not const: BigInt has no const constructor, so a const invocation is
  // impossible anyway.
  TxRecipient(this.address, this.amountBaseUnits, {this.isChange = false});

  Map<String, dynamic> toJson() => {
    'address': address,
    'amount': amountBaseUnits.toString(),
    if (isChange) 'isChange': true,
  };

  factory TxRecipient.fromJson(Map<String, dynamic> json) => TxRecipient(
    json['address'] as String,
    _readBaseUnits(json['amount']),
    isChange: json['isChange'] as bool? ?? false,
  );

  @override
  String toString() =>
      'TxRecipient(${Redact.id(address)}, ${Redact.amount(amountBaseUnits)}'
      '${isChange ? ', change' : ''})';
}

/// Whether the chain says a transaction did what it was signed to do.
///
/// Added because Ethereum's receipt `status` had **four writers and no readers**:
/// it was fetched, stored and persisted, and then dropped on the floor here,
/// because [TxDetails] had nowhere to put it. A reverted transaction (gas
/// spent, funds not moved) was recorded and displayed as completed.
///
/// Defaults to [ok] at every construction site, so a coin that cannot express
/// the distinction says nothing rather than claiming success.
enum TxStatus {
  /// Nothing indicates a problem: in the mempool, or mined and (where the chain
  /// reports it) successful.
  ok,

  /// Mined and reverted. On Ethereum this is receipt `status == 0`: the
  /// transaction is on chain, the gas was spent, and the transfer did not
  /// happen. Displaying this as completed is the bug this enum closes.
  failed,

  /// Genuinely unknown. The broadcast's outcome was never observed; the bytes
  /// went out and no answer came back; so the transaction may or may not be in
  /// the network. Distinct from [ok] on purpose: "we do not know" must not read
  /// as "it worked".
  unknown;

  static TxStatus fromName(String? name) => switch (name) {
    'failed' => TxStatus.failed,
    'unknown' => TxStatus.unknown,
    // Absent covers every cache written before this field existed.
    _ => TxStatus.ok,
  };
}

/// A transaction as the wallet knows it.
class TxDetails {
  final int? index;
  final int direction;
  final String hash;
  final BigInt amountBaseUnits;
  final BigInt feeBaseUnits;
  final List<TxRecipient> recipients;
  final int? accountIndex;
  final List<int> subaddrIndexList;
  final int timestamp;
  final int height;
  final int confirmations;
  final String key;

  /// Unix seconds when the tx was first seen in the mempool or broadcast by
  /// this wallet. Used for display instead of block time when set.
  final int? broadcastAt;

  /// What the chain says about the transaction's own success, as distinct from
  /// how many blocks are on top of it. See [TxStatus].
  final TxStatus status;

  TxDetails({
    required this.index,
    required this.direction,
    required this.hash,
    required this.amountBaseUnits,
    required this.feeBaseUnits,
    required this.recipients,
    required this.accountIndex,
    required this.subaddrIndexList,
    required this.timestamp,
    required this.height,
    required this.confirmations,
    required this.key,
    this.broadcastAt,
    this.status = TxStatus.ok,
  });

  Map<String, dynamic> toJson() => {
    'index': index,
    'direction': direction,
    'hash': hash,
    'amount': amountBaseUnits.toString(),
    'fee': feeBaseUnits.toString(),
    'recipients': recipients.map((r) => r.toJson()).toList(),
    'accountIndex': accountIndex,
    'subaddrIndexList': subaddrIndexList,
    'timestamp': timestamp,
    'height': height,
    'confirmations': confirmations,
    'key': key,
    if (broadcastAt != null) 'broadcastAt': broadcastAt,
    // Omitted when ok, so this field costs nothing in the common case and an
    // older reader sees exactly what it saw before.
    if (status != TxStatus.ok) 'status': status.name,
  };

  factory TxDetails.fromJson(Map<String, dynamic> json) => TxDetails(
    index: json['index'] as int?,
    direction: json['direction'] as int,
    hash: json['hash'] as String,
    amountBaseUnits: _readBaseUnits(json['amount']),
    feeBaseUnits: _readBaseUnits(json['fee']),
    recipients: (json['recipients'] as List<dynamic>? ?? const [])
        .map((r) => TxRecipient.fromJson(r as Map<String, dynamic>))
        .toList(),
    accountIndex: json['accountIndex'] as int?,
    subaddrIndexList: (json['subaddrIndexList'] as List<dynamic>? ?? const []).cast<int>(),
    timestamp: json['timestamp'] as int,
    height: json['height'] as int,
    confirmations: json['confirmations'] as int,
    key: json['key'] as String,
    broadcastAt: json['broadcastAt'] as int?,
    status: TxStatus.fromName(json['status'] as String?),
  );

  /// Redacted; this type names an address and an amount, so its default
  /// rendering must not.
  @override
  String toString() =>
      'TxDetails(${Redact.id(hash)}, dir=$direction, ${Redact.amount(amountBaseUnits)}, '
      'h=$height, conf=$confirmations, status=${status.name})';
}

/// Reads a base-unit amount written either as a string (current) or a number.
///
/// The numeric form is what older unreleased builds wrote. It is
/// accepted so an existing dev cache still loads, but it is lossy above 2^53
/// and the value is rewritten as a string on the next save. Nothing shipped
/// ever wrote the numeric form.
BigInt _readBaseUnits(Object? raw) => switch (raw) {
  null => BigInt.zero,
  final String s => BigInt.tryParse(s) ?? BigInt.zero,
  final int i => BigInt.from(i),
  final num n => BigInt.from(n.toInt()),
  _ => BigInt.zero,
};

/// Parses a cached transaction list.
///
/// **Never throws.** The cache is derived data on disk that can be truncated by
/// a crash mid-write, corrupted, or left over from an older format. A parse
/// failure must degrade to "no cached history", which re-syncs, rather than
/// taking down whatever was loading it. Individual malformed entries are
/// dropped so one bad record cannot discard a good list.
List<TxDetails> parseCachedTxHistory(String txJson) {
  try {
    final decoded = jsonDecode(txJson);
    if (decoded is! List) return const [];

    final out = <TxDetails>[];
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        out.add(TxDetails.fromJson(entry));
      } catch (_) {
        // Skip the bad record, keep the rest.
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// A transaction built but not yet broadcast.
abstract class PendingTransaction {
  BigInt get amountBaseUnits;

  /// The exact fee this transaction will pay, in the fee coin's base units.
  ///
  /// **Not capped, and never will be.** Whether the number is reasonable for
  /// current conditions is the application's call: any ceiling here would be a
  /// guess about a fast-moving market, and a wrong guess silently refuses a
  /// correctly-priced urgent send from inside a dependency.
  ///
  /// It is populated on every coin before the user confirms anything, and the
  /// application is expected to:
  ///
  ///  - show it in coin terms **unconditionally**: never gated on a fiat rate,
  ///    which fails closed over Tor;
  ///  - warn when it is a large fraction of [amountBaseUnits];
  ///  - for a foreign fee (an ERC-20 send: fee in ETH, amount in the token),
  ///    convert both sides to fiat and still make that percentage comparison;
  ///    and when no rate is available, say the comparison could not be made
  ///    rather than showing nothing.
  BigInt get feeBaseUnits;
}

class WalletConnectionDetails {
  final String address;
  final String proxyPort;
  final bool useTor;

  /// Coin-specific server kind (Monero's `lws` vs `node`). Empty = default.
  final String connectionType;

  const WalletConnectionDetails({
    required this.address,
    required this.proxyPort,
    required this.useTor,
    this.connectionType = '',
  });

  @override
  String toString() => 'WalletConnectionDetails($address, tor=$useTor, type=$connectionType)';
}
