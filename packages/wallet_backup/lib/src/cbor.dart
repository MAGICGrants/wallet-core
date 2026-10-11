import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart' show compareBytes;

/// The subset of deterministic CBOR (RFC 8949 §4.2.1, "core deterministic
/// encoding") that backup format version 1 uses.
///
/// Allowed: unsigned and negative integers up to 64 bits, byte strings, UTF-8
/// text strings, arrays, maps, `false`, `true` and `null`, all with
/// definite lengths and shortest-form heads, map keys sorted by their encoded
/// bytes with no duplicates. Not allowed: tags, floats, other simple values,
/// indefinite lengths. A body outside this subset is not canonical, and the
/// whole file is rejected (plan §2.1).
///
/// Dart values: `int` (or `BigInt` past 63 bits), [Uint8List], [String],
/// `List<Object?>`, `Map<Object, Object?>`, `bool`, `null`; and [CborRaw] for an
/// item that is already encoded, which is how records of unknown types are
/// carried byte for byte.
class CborRaw {
  CborRaw(this.bytes);

  final Uint8List bytes;
}

class CborFormatException implements Exception {
  const CborFormatException(this.message);

  final String message;

  @override
  String toString() => 'CborFormatException: $message';
}

const _maxDepth = 16;

// ----- Encoding -----

Uint8List cborEncode(Object? value) {
  final out = BytesBuilder(copy: false);
  _encode(out, value);
  return out.takeBytes();
}

void _head(BytesBuilder out, int major, BigInt n) {
  final m = major << 5;
  if (n < BigInt.from(24)) {
    out.addByte(m | n.toInt());
  } else if (n < BigInt.from(0x100)) {
    out
      ..addByte(m | 24)
      ..addByte(n.toInt());
  } else if (n < BigInt.from(0x10000)) {
    out.addByte(m | 25);
    out.add(_be(n, 2));
  } else if (n < BigInt.from(0x100000000)) {
    out.addByte(m | 26);
    out.add(_be(n, 4));
  } else if (n < BigInt.one << 64) {
    out.addByte(m | 27);
    out.add(_be(n, 8));
  } else {
    throw ArgumentError('integer out of CBOR range');
  }
}

Uint8List _be(BigInt n, int size) {
  final out = Uint8List(size);
  var v = n;
  for (var i = size - 1; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

void _encode(BytesBuilder out, Object? v) {
  switch (v) {
    case null:
      out.addByte(0xf6);
    case final bool b:
      out.addByte(b ? 0xf5 : 0xf4);
    case final int i:
      _encodeInt(out, BigInt.from(i));
    case final BigInt i:
      _encodeInt(out, i);
    case final Uint8List b:
      _head(out, 2, BigInt.from(b.length));
      out.add(b);
    case final String s:
      final b = utf8.encode(s);
      _head(out, 3, BigInt.from(b.length));
      out.add(b);
    case final CborRaw r:
      out.add(r.bytes);
    case final List<Object?> l:
      _head(out, 4, BigInt.from(l.length));
      for (final item in l) {
        _encode(out, item);
      }
    case final Map<Object?, Object?> m:
      final entries = [for (final e in m.entries) (cborEncode(e.key), e.value)]
        ..sort((a, b) => compareBytes(a.$1, b.$1));
      for (var i = 1; i < entries.length; i++) {
        if (compareBytes(entries[i - 1].$1, entries[i].$1) == 0) {
          throw ArgumentError('duplicate map key');
        }
      }
      _head(out, 5, BigInt.from(entries.length));
      for (final (key, value) in entries) {
        out.add(key);
        _encode(out, value);
      }
    default:
      throw ArgumentError('cannot encode ${v.runtimeType} as CBOR');
  }
}

void _encodeInt(BytesBuilder out, BigInt i) {
  if (i.isNegative) {
    _head(out, 1, -i - BigInt.one);
  } else {
    _head(out, 0, i);
  }
}

// ----- Decoding -----

/// Reads one CBOR item at a time from [data], enforcing the canonical subset.
class CborReader {
  CborReader(this.data, [this.pos = 0]);

  final Uint8List data;
  int pos;

  bool get atEnd => pos >= data.length;

  int _byte() {
    if (pos >= data.length) throw const CborFormatException('truncated');
    return data[pos++];
  }

  /// The major type and argument of the next head, checking it is the
  /// shortest form.
  (int, BigInt) _readHead() {
    final initial = _byte();
    final major = initial >> 5;
    final ai = initial & 0x1f;
    if (major == 7) {
      if (ai == 20 || ai == 21 || ai == 22) return (7, BigInt.from(ai));
      throw const CborFormatException('floats and simple values other than false/true/null');
    }
    if (major == 6) throw const CborFormatException('tags are not allowed');
    if (ai < 24) return (major, BigInt.from(ai));
    final size = switch (ai) {
      24 => 1,
      25 => 2,
      26 => 4,
      27 => 8,
      _ => throw const CborFormatException('indefinite or reserved length'),
    };
    var n = BigInt.zero;
    for (var i = 0; i < size; i++) {
      n = (n << 8) | BigInt.from(_byte());
    }
    final minimum = switch (size) {
      1 => BigInt.from(24),
      2 => BigInt.from(0x100),
      4 => BigInt.from(0x10000),
      _ => BigInt.from(0x100000000),
    };
    if (n < minimum) throw const CborFormatException('non-shortest head');
    return (major, n);
  }

  int _length(BigInt n) {
    if (n > BigInt.from(data.length - pos)) throw const CborFormatException('length past end');
    return n.toInt();
  }

  /// Skips one item, validating it, and returns its encoded bytes.
  Uint8List readRaw() {
    final start = pos;
    _skip(0);
    return Uint8List.sublistView(data, start, pos);
  }

  void _skip(int depth) {
    if (depth > _maxDepth) throw const CborFormatException('nested too deeply');
    final (major, n) = _readHead();
    switch (major) {
      case 0 || 1 || 7:
        return;
      case 2:
        pos += _length(n);
      case 3:
        final len = _length(n);
        _checkUtf8(pos, len);
        pos += len;
      case 4:
        final count = _length(n);
        for (var i = 0; i < count; i++) {
          _skip(depth + 1);
        }
      case 5:
        final count = _length(n);
        Uint8List? previous;
        for (var i = 0; i < count; i++) {
          final keyStart = pos;
          _skip(depth + 1);
          final key = Uint8List.sublistView(data, keyStart, pos);
          if (previous != null && compareBytes(previous, key) >= 0) {
            throw const CborFormatException('map keys out of order or duplicated');
          }
          previous = key;
          _skip(depth + 1);
        }
    }
  }

  void _checkUtf8(int start, int len) {
    try {
      utf8.decode(Uint8List.sublistView(data, start, start + len));
    } on FormatException {
      throw const CborFormatException('invalid UTF-8');
    }
  }

  /// Reads one item as a Dart value. Map keys must be integers or text.
  Object? read([int depth = 0]) {
    if (depth > _maxDepth) throw const CborFormatException('nested too deeply');
    final start = pos;
    final (major, n) = _readHead();
    switch (major) {
      case 0:
        return n.isValidInt ? n.toInt() : n;
      case 1:
        final v = -n - BigInt.one;
        return v.isValidInt ? v.toInt() : v;
      case 2:
        final len = _length(n);
        final out = Uint8List.fromList(Uint8List.sublistView(data, pos, pos + len));
        pos += len;
        return out;
      case 3:
        final len = _length(n);
        _checkUtf8(pos, len);
        final s = utf8.decode(Uint8List.sublistView(data, pos, pos + len));
        pos += len;
        return s;
      case 4:
        final count = _length(n);
        return [for (var i = 0; i < count; i++) read(depth + 1)];
      case 5:
        // Validate order on the raw bytes, then decode.
        pos = start;
        _skip(depth);
        final end = pos;
        pos = start;
        _readHead();
        final count = n.toInt();
        final out = <Object, Object?>{};
        for (var i = 0; i < count; i++) {
          final key = read(depth + 1);
          if (key is! int && key is! String) {
            throw const CborFormatException('map key is not an integer or text');
          }
          out[key!] = read(depth + 1);
        }
        assert(pos == end);
        return out;
      case 7:
        return switch (n.toInt()) {
          20 => false,
          21 => true,
          _ => null,
        };
    }
    throw const CborFormatException('unreachable');
  }

  /// The count from a map head, for reading a map entry by entry.
  int readMapHeader() {
    final (major, n) = _readHead();
    if (major != 5) throw const CborFormatException('expected a map');
    return _length(n);
  }

  /// The count from an array head, for reading an array item by item.
  int readArrayHeader() {
    final (major, n) = _readHead();
    if (major != 4) throw const CborFormatException('expected an array');
    return _length(n);
  }
}

/// Decodes [data] as exactly one canonical item.
Object? cborDecode(Uint8List data) {
  final check = CborReader(data)..readRaw();
  if (!check.atEnd) throw const CborFormatException('trailing bytes');
  return CborReader(data).read();
}

/// Throws unless [data] is exactly one item in the canonical subset.
void cborCheckCanonical(Uint8List data) {
  final r = CborReader(data)..readRaw();
  if (!r.atEnd) throw const CborFormatException('trailing bytes');
}
