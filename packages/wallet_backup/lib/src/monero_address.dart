import 'dart:typed_data';

import 'package:pointycastle/export.dart' show KeccakDigest;

import 'crypto.dart' show bytesEqual;

/// The three kinds of Monero address, as the outgoing-payment record stores
/// them (plan §2.2: "address kind and public keys").
enum MoneroAddressKind { standard, subaddress, integrated }

enum MoneroNetwork {
  mainnet(18, 42, 19),
  testnet(53, 63, 54),
  stagenet(24, 36, 25);

  const MoneroNetwork(this.standardTag, this.subaddressTag, this.integratedTag);

  final int standardTag;
  final int subaddressTag;
  final int integratedTag;

  int tagFor(MoneroAddressKind kind) => switch (kind) {
    MoneroAddressKind.standard => standardTag,
    MoneroAddressKind.subaddress => subaddressTag,
    MoneroAddressKind.integrated => integratedTag,
  };
}

/// A decoded address: its kind and network, the two public keys, and the
/// 8-byte payment ID of an integrated address.
class MoneroAddress {
  MoneroAddress({
    required this.network,
    required this.kind,
    required this.spendPublicKey,
    required this.viewPublicKey,
    this.paymentId,
  });

  final MoneroNetwork network;
  final MoneroAddressKind kind;
  final Uint8List spendPublicKey;
  final Uint8List viewPublicKey;
  final Uint8List? paymentId;

  /// Null when [address] is not a well-formed Monero address with a valid
  /// checksum.
  static MoneroAddress? tryParse(String address) {
    final raw = _base58Decode(address);
    if (raw == null || raw.length < 1 + 64 + 4) return null;
    final body = Uint8List.sublistView(raw, 0, raw.length - 4);
    final checksum = Uint8List.sublistView(raw, raw.length - 4);
    if (!bytesEqual(_keccak256(body).sublist(0, 4), checksum)) return null;

    // Every tag in use is below 0x80, so its varint is one byte.
    final tag = raw[0];
    for (final network in MoneroNetwork.values) {
      for (final kind in MoneroAddressKind.values) {
        if (network.tagFor(kind) != tag) continue;
        final expected = 1 + 64 + (kind == MoneroAddressKind.integrated ? 8 : 0);
        if (body.length != expected) return null;
        return MoneroAddress(
          network: network,
          kind: kind,
          spendPublicKey: Uint8List.fromList(body.sublist(1, 33)),
          viewPublicKey: Uint8List.fromList(body.sublist(33, 65)),
          paymentId: kind == MoneroAddressKind.integrated
              ? Uint8List.fromList(body.sublist(65, 73))
              : null,
        );
      }
    }
    return null;
  }

  String encode() {
    final integrated = kind == MoneroAddressKind.integrated;
    final body = Uint8List(1 + 64 + (integrated ? 8 : 0))
      ..[0] = network.tagFor(kind)
      ..setRange(1, 33, spendPublicKey)
      ..setRange(33, 65, viewPublicKey);
    if (integrated) body.setRange(65, 73, paymentId!);
    final raw = Uint8List(body.length + 4)
      ..setRange(0, body.length, body)
      ..setRange(body.length, body.length + 4, _keccak256(body));
    return _base58Encode(raw);
  }
}

Uint8List _keccak256(Uint8List data) => KeccakDigest(256).process(data);

// Monero's base58: 8-byte blocks, each encoded to exactly 11 characters, the
// last partial block to the length in [_encodedBlockSizes].
const _alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const _encodedBlockSizes = [0, 2, 3, 5, 6, 7, 9, 10, 11];
const _fullBlockSize = 8;
const _fullEncodedBlockSize = 11;

String _base58Encode(Uint8List data) {
  final out = StringBuffer();
  for (var i = 0; i < data.length; i += _fullBlockSize) {
    final end = i + _fullBlockSize < data.length ? i + _fullBlockSize : data.length;
    var n = BigInt.zero;
    for (var j = i; j < end; j++) {
      n = (n << 8) | BigInt.from(data[j]);
    }
    final chars = List.filled(_encodedBlockSizes[end - i], _alphabet[0]);
    for (var k = chars.length - 1; k >= 0 && n > BigInt.zero; k--) {
      chars[k] = _alphabet[(n % BigInt.from(58)).toInt()];
      n ~/= BigInt.from(58);
    }
    out.writeAll(chars);
  }
  return out.toString();
}

Uint8List? _base58Decode(String s) {
  final fullBlocks = s.length ~/ _fullEncodedBlockSize;
  final lastChars = s.length % _fullEncodedBlockSize;
  final lastBytes = _encodedBlockSizes.indexOf(lastChars);
  if (lastBytes < 0) return null;
  final out = Uint8List(fullBlocks * _fullBlockSize + lastBytes);
  var o = 0;
  for (var i = 0; i < s.length; i += _fullEncodedBlockSize) {
    final end = i + _fullEncodedBlockSize < s.length ? i + _fullEncodedBlockSize : s.length;
    final size = end - i == _fullEncodedBlockSize ? _fullBlockSize : lastBytes;
    var n = BigInt.zero;
    for (var j = i; j < end; j++) {
      final d = _alphabet.indexOf(s[j]);
      if (d < 0) return null;
      n = n * BigInt.from(58) + BigInt.from(d);
    }
    if (n >> (8 * size) != BigInt.zero) return null;
    for (var k = size - 1; k >= 0; k--) {
      out[o + k] = (n & BigInt.from(0xff)).toInt();
      n >>= 8;
    }
    o += size;
  }
  return out;
}
