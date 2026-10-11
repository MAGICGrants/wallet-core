import 'dart:typed_data';

import 'cbor.dart';
import 'crypto.dart';

/// The record registry (plan §2.2, §6). Placeholder numbers until a Monero
/// addendum fixes them; a number, once used, is never reused.
///
/// This version writes two types: outgoing payments (1) and contacts (3).
/// Every other type, and every field these two do not know, is kept byte for
/// byte, so an older wallet never drops what a newer one wrote.
///
/// **Type 1, outgoing payment** (immutable; merged by union on txid):
///
/// | key | value |
/// |---|---|
/// | 0 | 1 |
/// | 1 | txid, 32-byte bstr |
/// | 2 | account (major index), uint |
/// | 3 | fee, piconero, uint |
/// | 4 | destinations: array of destination maps, below |
///
/// Each destination carries its own transaction key (plan §2.2: "per
/// destination: … tx key"):
///
/// | key | value |
/// |---|---|
/// | 0 | kind: 0 standard, 1 subaddress, 2 integrated |
/// | 1 | spend public key, 32-byte bstr |
/// | 2 | view public key, 32-byte bstr |
/// | 3 | amount, piconero, uint |
/// | 4 | tx secret key for this destination, 32-byte bstr (absent if unknown): `r` for a legacy transaction, `d_e` for a Carrot one |
/// | 5 | additional tx secret keys, array of 32-byte bstr (legacy transactions with them only) |
/// | 6 | payment ID, 8-byte bstr (integrated addresses only) |
///
/// A legacy transaction's additional keys are per output, and which output is
/// a given destination's is not known without scanning the transaction, so a
/// legacy destination carries `r` and every additional key: exactly what
/// `check_tx_key` and `get_tx_proof` take for that destination.
///
/// Addresses are mainnet: both apps back up mainnet Monero only.
///
/// **Type 3, contact** (mutable; last writer wins on `(lamport, device_id)`):
///
/// | key | value |
/// |---|---|
/// | 0 | 3 |
/// | 1 | contact id: 16-byte bstr, or tstr for an id written before ids were random |
/// | 2 | name, tstr (absent when deleted) |
/// | 3 | addresses, map of coin symbol (tstr) to address (tstr) (absent when deleted) |
/// | 4 | description, tstr (optional; neither app writes one yet) |
/// | 5 | lamport, uint |
/// | 6 | device_id, 16-byte bstr |
/// | 7 | `true` when this version is a deletion |
abstract final class RecordType {
  static const outgoingPayment = 1;
  static const contact = 3;
}

/// Thrown when a record of a known type is missing a field or has one of the
/// wrong type. The file that holds it is rejected whole.
class RecordFormatException implements Exception {
  const RecordFormatException(this.message);

  final String message;

  @override
  String toString() => 'RecordFormatException: $message';
}

sealed class BackupRecord {
  BackupRecord(this.raw);

  /// The record's canonical encoding, as read or as written. Snapshots and
  /// re-uploads carry exactly these bytes.
  final Uint8List raw;

  int get type;

  /// Parses one record from its canonical encoding.
  static BackupRecord parse(Uint8List raw) {
    final value = CborReader(raw).read();
    if (value is! Map<Object, Object?>) throw const RecordFormatException('record is not a map');
    final type = value[0];
    if (type is! int) throw const RecordFormatException('record type missing');
    return switch (type) {
      RecordType.outgoingPayment => OutgoingPaymentRecord._parse(raw, value),
      RecordType.contact => ContactRecord._parse(raw, value),
      _ => UnknownRecord(raw, type),
    };
  }
}

class UnknownRecord extends BackupRecord {
  UnknownRecord(super.raw, this.type);

  @override
  final int type;
}

class PaymentDestination {
  PaymentDestination({
    required this.kind,
    required this.spendPublicKey,
    required this.viewPublicKey,
    required this.amount,
    this.txKey,
    this.additionalTxKeys = const [],
    this.paymentId,
  });

  /// 0 standard, 1 subaddress, 2 integrated.
  final int kind;
  final Uint8List spendPublicKey;
  final Uint8List viewPublicKey;
  final BigInt amount;

  /// This destination's transaction secret key, or null when unknown.
  final Uint8List? txKey;

  /// A legacy transaction's additional keys; empty when it has none.
  final List<Uint8List> additionalTxKeys;
  final Uint8List? paymentId;

  /// The key as `Wallet_getTxKey` returns it: `r` then each additional key,
  /// hex, concatenated. Empty when there is none.
  String get txKeyHex => txKey == null ? '' : toHex(txKey!) + additionalTxKeys.map(toHex).join();

  Map<Object, Object?> _toCbor() => {
    0: kind,
    1: spendPublicKey,
    2: viewPublicKey,
    3: amount,
    4: ?txKey,
    if (additionalTxKeys.isNotEmpty) 5: additionalTxKeys,
    6: ?paymentId,
  };

  static PaymentDestination _parse(Object? v) {
    if (v is! Map<Object, Object?>) throw const RecordFormatException('destination');
    final extra = v[5];
    if (extra != null && extra is! List) throw const RecordFormatException('additional keys');
    return PaymentDestination(
      kind: _int(v[0], 'destination kind'),
      spendPublicKey: _bytes(v[1], 32, 'destination spend key'),
      viewPublicKey: _bytes(v[2], 32, 'destination view key'),
      amount: _uint(v[3], 'destination amount'),
      txKey: v[4] == null ? null : _bytes(v[4], 32, 'tx key'),
      additionalTxKeys: [for (final k in (extra as List?) ?? const []) _bytes(k, 32, 'tx key')],
      paymentId: v[6] == null ? null : _bytes(v[6], 8, 'payment id'),
    );
  }
}

class OutgoingPaymentRecord extends BackupRecord {
  OutgoingPaymentRecord._(
    super.raw, {
    required this.txid,
    required this.account,
    required this.fee,
    required this.destinations,
  });

  factory OutgoingPaymentRecord({
    required Uint8List txid,
    required int account,
    required BigInt fee,
    required List<PaymentDestination> destinations,
  }) {
    final raw = cborEncode({
      0: RecordType.outgoingPayment,
      1: txid,
      2: account,
      3: fee,
      4: [for (final d in destinations) d._toCbor()],
    });
    return OutgoingPaymentRecord._(
      raw,
      txid: txid,
      account: account,
      fee: fee,
      destinations: destinations,
    );
  }

  static OutgoingPaymentRecord _parse(Uint8List raw, Map<Object, Object?> v) {
    final dests = v[4];
    if (dests is! List) throw const RecordFormatException('destinations');
    return OutgoingPaymentRecord._(
      raw,
      txid: _bytes(v[1], 32, 'txid'),
      account: _int(v[2], 'account'),
      fee: _uint(v[3], 'fee'),
      destinations: [for (final d in dests) PaymentDestination._parse(d)],
    );
  }

  @override
  int get type => RecordType.outgoingPayment;

  final Uint8List txid;
  final int account;
  final BigInt fee;
  final List<PaymentDestination> destinations;

  String get txidHex => toHex(txid);

  /// Whether any destination carries a transaction key.
  bool get hasTxKey => destinations.any((d) => d.txKey != null);

  /// The first destination's key in `Wallet_getTxKey`'s form, for a history
  /// entry, which holds one key per transaction. Empty when there is none.
  String get txKeyHex =>
      destinations.map((d) => d.txKeyHex).firstWhere((k) => k.isNotEmpty, orElse: () => '');
}

class ContactRecord extends BackupRecord {
  ContactRecord._(
    super.raw, {
    required this.id,
    required this.name,
    required this.addresses,
    required this.description,
    required this.lamport,
    required this.deviceId,
    required this.deleted,
  });

  factory ContactRecord({
    required String id,
    required String name,
    required Map<String, String> addresses,
    required int lamport,
    required Uint8List deviceId,
  }) {
    final raw = cborEncode({
      0: RecordType.contact,
      1: encodeContactId(id),
      2: name,
      3: Map<Object, Object?>.from(addresses),
      5: lamport,
      6: deviceId,
    });
    return ContactRecord._(
      raw,
      id: id,
      name: name,
      addresses: Map.unmodifiable(addresses),
      description: null,
      lamport: lamport,
      deviceId: deviceId,
      deleted: false,
    );
  }

  factory ContactRecord.deletion({
    required String id,
    required int lamport,
    required Uint8List deviceId,
  }) {
    final raw = cborEncode({
      0: RecordType.contact,
      1: encodeContactId(id),
      5: lamport,
      6: deviceId,
      7: true,
    });
    return ContactRecord._(
      raw,
      id: id,
      name: '',
      addresses: const {},
      description: null,
      lamport: lamport,
      deviceId: deviceId,
      deleted: true,
    );
  }

  static ContactRecord _parse(Uint8List raw, Map<Object, Object?> v) {
    final deleted = v[7] == true;
    final rawAddresses = v[3];
    final addresses = <String, String>{};
    if (!deleted) {
      if (rawAddresses is! Map) throw const RecordFormatException('contact addresses');
      for (final e in rawAddresses.entries) {
        if (e.key is! String || e.value is! String) {
          throw const RecordFormatException('contact address entry');
        }
        addresses[e.key as String] = e.value as String;
      }
    }
    final name = v[2];
    if (!deleted && name is! String) throw const RecordFormatException('contact name');
    final description = v[4];
    return ContactRecord._(
      raw,
      id: decodeContactId(v[1]),
      name: deleted ? '' : name as String,
      addresses: Map.unmodifiable(addresses),
      description: description is String ? description : null,
      lamport: _int(v[5], 'lamport'),
      deviceId: _bytes(v[6], 16, 'device id'),
      deleted: deleted,
    );
  }

  @override
  int get type => RecordType.contact;

  final String id;
  final String name;
  final Map<String, String> addresses;
  final String? description;
  final int lamport;
  final Uint8List deviceId;
  final bool deleted;

  /// Whether this version beats [other] under last-writer-wins: the higher
  /// `(lamport, device_id)`.
  bool beats(ContactRecord other) {
    if (lamport != other.lamport) return lamport > other.lamport;
    final byDevice = compareBytes(deviceId, other.deviceId);
    if (byDevice != 0) return byDevice > 0;
    // Same writer and clock: the same version, unless a writer misbehaved.
    // Order on the bytes so every reader still picks the same one.
    return compareBytes(raw, other.raw) > 0;
  }

  /// Ids from [newContactId] travel as their 16 bytes; anything else (the
  /// millisecond timestamps earlier builds used) as text.
  static Object encodeContactId(String id) {
    if (RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) return fromHex(id);
    return id;
  }

  static String decodeContactId(Object? v) => switch (v) {
    final Uint8List b when b.length == 16 => toHex(b),
    final String s => s,
    _ => throw const RecordFormatException('contact id'),
  };
}

int _int(Object? v, String what) {
  if (v is! int || v < 0) throw RecordFormatException(what);
  return v;
}

BigInt _uint(Object? v, String what) => switch (v) {
  final int i when i >= 0 => BigInt.from(i),
  final BigInt b when !b.isNegative => b,
  _ => throw RecordFormatException(what),
};

Uint8List _bytes(Object? v, int length, String what) {
  if (v is! Uint8List || v.length != length) throw RecordFormatException(what);
  return v;
}
