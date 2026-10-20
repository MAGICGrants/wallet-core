import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// XChaCha20-Poly1305, as libsodium's `crypto_aead_xchacha20poly1305_ietf_*`:
/// HChaCha20 turns the key and the first 16 nonce bytes into a subkey, and
/// ChaCha20-Poly1305 (RFC 8439) runs under it with the nonce
/// `0x00000000 ‖ nonce[16:24]`.
///
/// Random 24-byte nonces are safe to draw independently on every device, which
/// is why the backup uses the X variant: no counter has to be shared.
class XChaCha20Poly1305 {
  XChaCha20Poly1305._();

  static const keyLength = 32;
  static const nonceLength = 24;
  static const tagLength = 16;

  /// `ciphertext ‖ tag`.
  static Uint8List seal(Uint8List key, Uint8List nonce, Uint8List ad, Uint8List plaintext) =>
      _run(true, key, nonce, ad, plaintext);

  /// The plaintext, or throws [AuthenticationFailed] if any byte of the
  /// ciphertext, tag, nonce or [ad] was changed.
  static Uint8List open(Uint8List key, Uint8List nonce, Uint8List ad, Uint8List sealed) {
    if (sealed.length < tagLength) throw const AuthenticationFailed();
    try {
      return _run(false, key, nonce, ad, sealed);
    } on ArgumentError {
      // pointycastle reports a tag mismatch as an ArgumentError.
      throw const AuthenticationFailed();
    }
  }

  static Uint8List _run(
    bool encrypt,
    Uint8List key,
    Uint8List nonce,
    Uint8List ad,
    Uint8List input,
  ) {
    if (key.length != keyLength) throw ArgumentError('key must be 32 bytes');
    if (nonce.length != nonceLength) throw ArgumentError('nonce must be 24 bytes');
    final subkey = hChaCha20(key, Uint8List.sublistView(nonce, 0, 16));
    final ietfNonce = Uint8List(12)..setRange(4, 12, nonce, 16);
    final aead = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
      ..init(encrypt, AEADParameters(KeyParameter(subkey), tagLength * 8, ietfNonce, ad));
    final out = Uint8List(encrypt ? input.length + tagLength : input.length - tagLength);
    try {
      var n = aead.processBytes(input, 0, input.length, out, 0);
      n += aead.doFinal(out, n);
      return n == out.length ? out : Uint8List.sublistView(out, 0, n);
    } catch (_) {
      // Decryption writes plaintext before it checks the tag; drop it.
      out.fillRange(0, out.length, 0);
      rethrow;
    } finally {
      subkey.fillRange(0, subkey.length, 0);
    }
  }

  /// HChaCha20 (draft-irtf-cfrg-xchacha §2.2): 20 ChaCha rounds over
  /// constants ‖ key ‖ nonce16, output words 0–3 and 12–15, no feed-forward.
  static Uint8List hChaCha20(Uint8List key, Uint8List nonce16) {
    final s = Uint32List(16);
    s[0] = 0x61707865;
    s[1] = 0x3320646e;
    s[2] = 0x79622d32;
    s[3] = 0x6b206574;
    final k = ByteData.sublistView(key);
    for (var i = 0; i < 8; i++) {
      s[4 + i] = k.getUint32(4 * i, Endian.little);
    }
    final n = ByteData.sublistView(nonce16);
    for (var i = 0; i < 4; i++) {
      s[12 + i] = n.getUint32(4 * i, Endian.little);
    }
    for (var round = 0; round < 10; round++) {
      _qr(s, 0, 4, 8, 12);
      _qr(s, 1, 5, 9, 13);
      _qr(s, 2, 6, 10, 14);
      _qr(s, 3, 7, 11, 15);
      _qr(s, 0, 5, 10, 15);
      _qr(s, 1, 6, 11, 12);
      _qr(s, 2, 7, 8, 13);
      _qr(s, 3, 4, 9, 14);
    }
    final out = Uint8List(32);
    final o = ByteData.sublistView(out);
    for (var i = 0; i < 4; i++) {
      o.setUint32(4 * i, s[i], Endian.little);
      o.setUint32(16 + 4 * i, s[12 + i], Endian.little);
    }
    s.fillRange(0, 16, 0);
    return out;
  }

  static int _rotl(int v, int c) => ((v << c) | (v >> (32 - c))) & 0xffffffff;

  static void _qr(Uint32List s, int a, int b, int c, int d) {
    s[a] = s[a] + s[b];
    s[d] = _rotl(s[d] ^ s[a], 16);
    s[c] = s[c] + s[d];
    s[b] = _rotl(s[b] ^ s[c], 12);
    s[a] = s[a] + s[b];
    s[d] = _rotl(s[d] ^ s[a], 8);
    s[c] = s[c] + s[d];
    s[b] = _rotl(s[b] ^ s[c], 7);
  }
}

class AuthenticationFailed implements Exception {
  const AuthenticationFailed();

  @override
  String toString() => 'AuthenticationFailed';
}

final _random = Random.secure();

Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _random.nextInt(256);
  }
  return out;
}

String toHex(List<int> bytes) {
  const digits = '0123456789abcdef';
  final out = StringBuffer();
  for (final b in bytes) {
    out
      ..write(digits[b >> 4])
      ..write(digits[b & 15]);
  }
  return out.toString();
}

Uint8List fromHex(String hex) {
  if (hex.length.isOdd) throw const FormatException('odd-length hex');
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final v = int.tryParse(hex.substring(2 * i, 2 * i + 2), radix: 16);
    if (v == null) throw const FormatException('not hex');
    out[i] = v;
  }
  return out;
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Bytewise lexicographic order, shorter first on a common prefix.
int compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
