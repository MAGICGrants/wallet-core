import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart';

/// XChaCha20-Poly1305: libsodium's `crypto_aead_xchacha20poly1305_ietf_*`,
/// through fhse_native ([BackupNative]).
///
/// Random 24-byte nonces are safe to draw independently on every device, which
/// is why the backup uses the X variant: no counter has to be shared.
class XChaCha20Poly1305 {
  XChaCha20Poly1305._();

  static const keyLength = 32;
  static const nonceLength = 24;
  static const tagLength = 16;

  /// `ciphertext ‖ tag`.
  static Uint8List seal(Uint8List key, Uint8List nonce, Uint8List ad, Uint8List plaintext) {
    final native = BackupNative.instance;
    return _run(native, native.encrypt, key, nonce, ad, plaintext, plaintext.length + tagLength);
  }

  /// The plaintext, or throws [AuthenticationFailed] if any byte of the
  /// ciphertext, tag, nonce or [ad] was changed.
  static Uint8List open(Uint8List key, Uint8List nonce, Uint8List ad, Uint8List sealed) {
    if (sealed.length < tagLength) throw const AuthenticationFailed();
    final native = BackupNative.instance;
    return _run(native, native.decrypt, key, nonce, ad, sealed, sealed.length - tagLength);
  }

  /// Runs [operation] with every buffer copied into native memory, and wipes
  /// each before it is freed, so no key or plaintext is left in the native
  /// heap.
  static Uint8List _run(
    BackupNative native,
    AeadD operation,
    Uint8List key,
    Uint8List nonce,
    Uint8List ad,
    Uint8List input,
    int outputLength,
  ) {
    if (key.length != keyLength) throw ArgumentError('key must be 32 bytes');
    if (nonce.length != nonceLength) throw ArgumentError('nonce must be 24 bytes');
    final buffers = <(Pointer<Uint8>, int)>[];
    // calloc(0) may return null; one byte keeps a valid pointer for empty input.
    Pointer<Uint8> copy(Uint8List bytes) {
      final size = bytes.isEmpty ? 1 : bytes.length;
      final ptr = calloc<Uint8>(size);
      buffers.add((ptr, size));
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return ptr;
    }

    try {
      final out = copy(Uint8List(outputLength));
      final rc = operation(
        out,
        outputLength,
        copy(input),
        input.length,
        copy(ad),
        ad.length,
        copy(nonce),
        nonce.length,
        copy(key),
        key.length,
      );
      if (rc == BackupNative.decryptionFailure) throw const AuthenticationFailed();
      if (rc != 0) throw StateError('XChaCha20-Poly1305 failed: error $rc');
      return Uint8List.fromList(out.asTypedList(outputLength));
    } finally {
      for (final (ptr, size) in buffers) {
        native.memzero(ptr.cast(), size);
        calloc.free(ptr);
      }
    }
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
