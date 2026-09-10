import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'pbkdf2.dart';

/// AES-256-GCM at-rest encryption for wallet files, keyed via PBKDF2-HMAC-SHA256.
///
/// Blob layout: `magic(4) | version(1) | iterations(4) | salt(32) | iv(12) | ct+tag`.
///
/// Used for the seed store and the per-coin wallet cache.
class WalletFileCrypto {
  /// 'SKLW'. Not renamed: test builds have written blobs with it and a change
  /// buys nothing.
  static const _magic = [0x53, 0x4B, 0x4C, 0x57];
  static const _version = 1;
  static const _saltLen = 32;
  static const _ivLen = 12;
  static const _keyLen = 32;
  static const _tagLenBits = 128;

  /// Low on mobile, OWASP count on desktop.
  ///
  /// On mobile the password is a full-entropy 128-bit value from
  /// `genWalletPassword()`, so there is no brute-force surface for iterations to
  /// defend. On desktop the user picks the password, so the count matters.
  static int get defaultIterations => (Platform.isAndroid || Platform.isIOS) ? 100000 : 600000;

  /// Bounds accepted when *reading* a blob's header.
  ///
  /// The header is not covered by the GCM tag (the AAD is empty), so a corrupt
  /// or hostile file can claim any iteration count. Deriving at 2^32-1 would
  /// wedge the app for hours; refusing out-of-range counts turns that into an
  /// immediate error. Tampering is not otherwise exploitable; a wrong count
  /// yields a wrong key and the tag check fails.
  static const minAcceptedIterations = 1000;
  static const maxAcceptedIterations = 10000000;

  /// Smallest on-disk blob that [decrypt] accepts (empty plaintext + GCM tag).
  static const int minBlobLength = 4 + 1 + 4 + 32 + 12 + 16;

  static final _random = Random.secure();

  /// Returns false for empty, truncated, or non-base64 wallet files.
  static bool isValidEncryptedBlobBase64(String base64Blob) {
    final trimmed = base64Blob.trim();
    if (trimmed.isEmpty) return false;
    try {
      return base64.decode(trimmed).length >= minBlobLength;
    } catch (_) {
      return false;
    }
  }

  /// Encrypts [plaintext] with [password], returning a base64 blob.
  ///
  /// [iterations] overrides [defaultIterations]. Intended for tests and format
  /// migration only; production callers should omit it.
  static Future<String> encryptToBase64(
    String plaintext,
    String password, {
    int? iterations,
    Pbkdf2Kdf? kdf,
  }) async {
    final blob = await encrypt(utf8.encode(plaintext), password, iterations: iterations, kdf: kdf);
    return base64.encode(blob);
  }

  /// Decrypts a blob previously produced by [encryptToBase64].
  static Future<String> decryptFromBase64(
    String base64Blob,
    String password, {
    Pbkdf2Kdf? kdf,
  }) async {
    final blob = base64.decode(base64Blob);
    final plaintext = await decrypt(blob, password, kdf: kdf);
    return utf8.decode(plaintext);
  }

  static Future<Uint8List> encrypt(
    List<int> plaintext,
    String password, {
    int? iterations,
    Pbkdf2Kdf? kdf,
  }) async {
    final rounds = iterations ?? defaultIterations;
    final salt = _randomBytes(_saltLen);
    final iv = _randomBytes(_ivLen);
    final key = await _deriveKey(password, salt, rounds, kdf);

    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), _tagLenBits, iv, Uint8List(0)));

    final ciphertext = cipher.process(Uint8List.fromList(plaintext));

    final iterationsBytes = Uint8List(4)..buffer.asByteData().setUint32(0, rounds, Endian.big);

    final out = BytesBuilder()
      ..add(_magic)
      ..addByte(_version)
      ..add(iterationsBytes)
      ..add(salt)
      ..add(iv)
      ..add(ciphertext);
    return out.toBytes();
  }

  static Future<Uint8List> decrypt(List<int> blob, String password, {Pbkdf2Kdf? kdf}) async {
    if (blob.length < minBlobLength) {
      throw const FormatException('Wallet blob is too short');
    }

    var offset = 0;
    for (var i = 0; i < _magic.length; i++) {
      if (blob[offset + i] != _magic[i]) {
        throw const FormatException('Wallet blob magic mismatch');
      }
    }
    offset += _magic.length;

    final version = blob[offset++];
    if (version != _version) {
      throw FormatException('Unsupported wallet blob version: $version');
    }

    final iterations = ByteData.sublistView(
      Uint8List.fromList(blob.sublist(offset, offset + 4)),
    ).getUint32(0, Endian.big);
    offset += 4;

    if (iterations < minAcceptedIterations || iterations > maxAcceptedIterations) {
      throw FormatException('Wallet blob iteration count out of range: $iterations');
    }

    final salt = Uint8List.fromList(blob.sublist(offset, offset + _saltLen));
    offset += _saltLen;
    final iv = Uint8List.fromList(blob.sublist(offset, offset + _ivLen));
    offset += _ivLen;
    final ciphertext = Uint8List.fromList(blob.sublist(offset));

    final key = await _deriveKey(password, salt, iterations, kdf);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), _tagLenBits, iv, Uint8List(0)));

    try {
      return cipher.process(ciphertext);
    } on InvalidCipherTextException {
      throw const FormatException('Wallet decryption failed (wrong password or corrupt file)');
    }
  }

  /// Key derivation backend. Defaults to native BoringSSL.
  ///
  /// Unit tests swap in [PointyCastlePbkdf2] because `package:webcrypto` needs
  /// a host BoringSSL build (cmake + Go) to run under `flutter test`. The two
  /// are proven byte-identical in `test/pbkdf2_test.dart`. Do not reassign this
  /// in production code.
  static Pbkdf2Kdf kdf = const WebCryptoPbkdf2();

  /// [override] wins over the static [kdf].
  ///
  /// This exists because **static state does not cross an isolate boundary**.
  /// `SeedStore` and `WalletCacheStore` decrypt inside `Isolate.run` to keep
  /// 600k PBKDF2 rounds off the UI thread, and the spawned isolate gets a fresh
  /// copy of this class with [kdf] back at its default; so an injected backend
  /// was silently ignored there, and every decrypt failed. Callers that cross
  /// an isolate must capture `WalletFileCrypto.kdf` outside and pass it in;
  /// the backends are const and field-free, so they send cheaply.
  static Future<Uint8List> _deriveKey(
    String password,
    Uint8List salt,
    int iterations,
    Pbkdf2Kdf? override,
  ) => (override ?? kdf).derive(
    password: password,
    salt: salt,
    iterations: iterations,
    keyLengthBytes: _keyLen,
  );

  static Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }
}
