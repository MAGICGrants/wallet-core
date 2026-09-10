import 'dart:typed_data';

import 'package:wallet_infra/wallet_infra.dart' show sha256d;

/// Whether [value] has the shape of a transaction id.
///
/// 64 lowercase hex characters, and nothing else. The reason this is a named
/// predicate rather than an inline regex: `broadcastTransaction` used to accept
/// *any* string the server returned as the txid, so a rejection message was
/// recorded as a successful send. Shape is the cheap half of catching that.
bool isTxidShaped(String value) => _txidPattern.hasMatch(value);

final _txidPattern = RegExp(r'^[0-9a-f]{64}$');

/// The transaction id of the raw transaction in [rawHex].
///
/// A txid is `HASH256` over the **witness-stripped** serialization, reversed;
/// *not* over the bytes as broadcast. For the P2WPKH transactions this wallet
/// builds those differ, so hashing the raw bytes directly would produce the
/// wtxid and every comparison against a server's answer would fail.
///
/// Written here rather than taken from `bitcoin_base`, which built the
/// transaction in the first place. The point of the comparison in `commitTx` is
/// to catch a server that returns something other than our transaction's id; a
/// check that shares its implementation with the code under check is worth
/// noticeably less, and this one is small enough to own.
///
/// Throws [FormatException] on anything that is not a well-formed transaction.
String computeTxid(String rawHex) {
  final bytes = _decodeHex(rawHex);
  final stripped = _stripWitness(bytes);
  // Little-endian on the wire, big-endian when displayed; hence the reverse.
  return _encodeHex(Uint8List.fromList(sha256d(stripped).reversed.toList()));
}

/// Re-serializes [bytes] without the segwit marker, flag and witness stacks.
///
/// Returns [bytes] unchanged for a pre-segwit transaction, whose serialization is
/// already the txid preimage.
Uint8List _stripWitness(Uint8List bytes) {
  final r = _Cursor(bytes);

  final versionStart = r.offset;
  r.skip(4);
  final versionEnd = r.offset;

  // A marker byte of 0x00 cannot be a real input count: a transaction with no
  // inputs is invalid, which is precisely why BIP144 chose 0x00 for it.
  final isSegwit = r.peek() == 0x00;
  if (!isSegwit) return bytes;
  r.skip(1); // marker
  final flag = r.readByte();
  if (flag == 0x00) {
    throw const FormatException('Transaction has a segwit marker with a zero flag');
  }

  final bodyStart = r.offset;
  final inputCount = r.readVarInt();
  if (inputCount == 0) {
    throw const FormatException('Segwit transaction declares zero inputs');
  }
  for (var i = 0; i < inputCount; i++) {
    r.skip(36); // 32-byte previous txid + 4-byte output index
    r.skip(r.readVarInt()); // scriptSig
    r.skip(4); // nSequence
  }
  final outputCount = r.readVarInt();
  for (var i = 0; i < outputCount; i++) {
    r.skip(8); // value
    r.skip(r.readVarInt()); // scriptPubKey
  }
  final bodyEnd = r.offset;

  // Witness stacks: one per input, each a count followed by that many items.
  for (var i = 0; i < inputCount; i++) {
    final items = r.readVarInt();
    for (var j = 0; j < items; j++) {
      r.skip(r.readVarInt());
    }
  }

  final lockTimeStart = r.offset;
  r.skip(4);
  if (r.offset != bytes.length) {
    throw FormatException(
      'Transaction has ${bytes.length - r.offset} trailing byte(s) after nLockTime',
    );
  }

  final out = BytesBuilder()
    ..add(Uint8List.sublistView(bytes, versionStart, versionEnd))
    ..add(Uint8List.sublistView(bytes, bodyStart, bodyEnd))
    ..add(Uint8List.sublistView(bytes, lockTimeStart, lockTimeStart + 4));
  return out.toBytes();
}

/// Bounds-checked forward reader. Every overrun is a [FormatException] rather
/// than a `RangeError`, so a malformed transaction is a parse failure and not a
/// crash on whatever isolate this runs on.
class _Cursor {
  _Cursor(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  void _require(int count) {
    if (offset + count > bytes.length) {
      throw FormatException(
        'Transaction ends mid-field: wanted $count byte(s) at $offset of ${bytes.length}',
      );
    }
  }

  int peek() {
    _require(1);
    return bytes[offset];
  }

  int readByte() {
    final value = peek();
    offset++;
    return value;
  }

  void skip(int count) {
    if (count < 0) throw const FormatException('Negative field length');
    _require(count);
    offset += count;
  }

  /// CompactSize, per BIP 144's underlying encoding.
  int readVarInt() {
    final first = readByte();
    if (first < 0xfd) return first;
    final width = switch (first) {
      0xfd => 2,
      0xfe => 4,
      _ => 8,
    };
    _require(width);
    var value = 0;
    for (var i = 0; i < width; i++) {
      value |= bytes[offset + i] << (8 * i);
    }
    offset += width;
    // A length above 2^31 cannot address anything in a transaction we could
    // hold. The `< 0` half is not redundant: an 8-byte CompactSize with the top
    // bit set overflows into the sign bit rather than growing, so without it a
    // hostile length would read as a small negative and skip backwards.
    if (value < 0 || value > 0x7fffffff) {
      throw const FormatException('Transaction field length is out of range');
    }
    return value;
  }
}

Uint8List _decodeHex(String hex) {
  if (hex.length.isOdd) {
    throw const FormatException('Raw transaction hex has an odd length');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = (_nibble(hex.codeUnitAt(i * 2)) << 4) | _nibble(hex.codeUnitAt(i * 2 + 1));
  }
  return out;
}

/// One hex digit's value.
///
/// Hand-rolled rather than `int.tryParse(..., radix: 16)`, which accepts a
/// leading `+` or `-`: `'-1'` would parse as -1 and land in a `Uint8List` as
/// 0xff, quietly decoding to a byte that was never in the input.
int _nibble(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30; // 0-9
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10; // a-f
  if (codeUnit >= 0x41 && codeUnit <= 0x46) return codeUnit - 0x41 + 10; // A-F
  throw const FormatException('Raw transaction hex has a non-hex character');
}

String _encodeHex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
