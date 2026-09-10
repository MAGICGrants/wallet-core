import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// Tests pass an explicit low count so the suite isn't dominated by PBKDF2.
/// Iteration *policy* is asserted separately against [WalletFileCrypto.defaultIterations].
const _fastRounds = 1000;

const _password = 'correct horse battery staple';
const _plaintext = '{"v":1,"mnemonic":"not a real seed","restore_date_iso":"2026-01-01"}';

Future<Uint8List> _blob({String plaintext = _plaintext, String password = _password}) =>
    WalletFileCrypto.encrypt(utf8.encode(plaintext), password, iterations: _fastRounds);

void main() {
  setUpAll(() {
    // `package:webcrypto` needs a host BoringSSL build to run under
    // `flutter test`. Substitute the pure-Dart backend, which pbkdf2_test.dart
    // proves byte-identical against published vectors.
    WalletFileCrypto.kdf = const PointyCastlePbkdf2();
  });

  tearDownAll(() {
    WalletFileCrypto.kdf = const WebCryptoPbkdf2();
  });

  group('round trip', () {
    test('recovers the plaintext', () async {
      final b64 = await WalletFileCrypto.encryptToBase64(
        _plaintext,
        _password,
        iterations: _fastRounds,
      );
      expect(await WalletFileCrypto.decryptFromBase64(b64, _password), _plaintext);
    });

    test('handles empty plaintext', () async {
      final blob = await _blob(plaintext: '');
      expect(blob.length, WalletFileCrypto.minBlobLength);
      expect(utf8.decode(await WalletFileCrypto.decrypt(blob, _password)), '');
    });

    test('handles non-ASCII plaintext', () async {
      const unicode = 'símbolo ¥ монеро 🙂';
      final blob = await _blob(plaintext: unicode);
      expect(utf8.decode(await WalletFileCrypto.decrypt(blob, _password)), unicode);
    });

    test('two encryptions of the same input differ (fresh salt and IV)', () async {
      final a = await _blob();
      final b = await _blob();
      expect(a, isNot(equals(b)));
    });
  });

  group('rejection', () {
    test('wrong password', () async {
      final blob = await _blob();
      expect(() => WalletFileCrypto.decrypt(blob, 'wrong'), throwsA(isA<FormatException>()));
    });

    test('flipped ciphertext byte is caught by the GCM tag', () async {
      final blob = await _blob();
      final tampered = Uint8List.fromList(blob)..[blob.length - 1] ^= 0x01;
      expect(() => WalletFileCrypto.decrypt(tampered, _password), throwsA(isA<FormatException>()));
    });

    test('bad magic', () async {
      final blob = await _blob();
      final tampered = Uint8List.fromList(blob)..[0] = 0x00;
      expect(
        () => WalletFileCrypto.decrypt(tampered, _password),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('magic'))),
      );
    });

    test('unsupported version', () async {
      final blob = await _blob();
      final tampered = Uint8List.fromList(blob)..[4] = 0x02;
      expect(
        () => WalletFileCrypto.decrypt(tampered, _password),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('version'))),
      );
    });

    test('truncated below minBlobLength', () async {
      final blob = await _blob();
      final short = blob.sublist(0, WalletFileCrypto.minBlobLength - 1);
      expect(
        () => WalletFileCrypto.decrypt(short, _password),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('too short'))),
      );
    });
  });

  group('iteration header', () {
    test('decrypt uses the count in the header, not the platform default', () async {
      // Written at a count that is deliberately not defaultIterations. If
      // decrypt ignored the header and used the platform value, the derived
      // key would differ and the tag check would fail.
      expect(_fastRounds, isNot(WalletFileCrypto.defaultIterations));
      final blob = await _blob();
      expect(utf8.decode(await WalletFileCrypto.decrypt(blob, _password)), _plaintext);
    });

    test('an absurd iteration count is refused rather than derived', () async {
      // The header is outside the GCM tag, so a corrupt file can claim any
      // count. Deriving at 2^32-1 would wedge the app for hours; this must
      // fail immediately instead.
      final blob = await _blob();
      final tampered = Uint8List.fromList(blob);
      tampered.buffer.asByteData().setUint32(5, 0xFFFFFFFF);
      expect(
        () => WalletFileCrypto.decrypt(tampered, _password),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', contains('out of range')),
        ),
      );
    });

    test('a too-low iteration count is refused', () async {
      final blob = await _blob();
      final tampered = Uint8List.fromList(blob);
      tampered.buffer.asByteData().setUint32(5, 1);
      expect(() => WalletFileCrypto.decrypt(tampered, _password), throwsA(isA<FormatException>()));
    });

    test('the platform default stays within the accepted range', () {
      expect(
        WalletFileCrypto.defaultIterations,
        inInclusiveRange(
          WalletFileCrypto.minAcceptedIterations,
          WalletFileCrypto.maxAcceptedIterations,
        ),
      );
      // Desktop is the user-chosen-password case and must meet the OWASP count.
      expect(WalletFileCrypto.defaultIterations, greaterThanOrEqualTo(100000));
    });
  });

  group('isValidEncryptedBlobBase64', () {
    test('accepts a real blob', () async {
      final b64 = await WalletFileCrypto.encryptToBase64(
        _plaintext,
        _password,
        iterations: _fastRounds,
      );
      expect(WalletFileCrypto.isValidEncryptedBlobBase64(b64), isTrue);
    });

    test('rejects empty, short and non-base64 input', () {
      expect(WalletFileCrypto.isValidEncryptedBlobBase64(''), isFalse);
      expect(WalletFileCrypto.isValidEncryptedBlobBase64('   '), isFalse);
      expect(WalletFileCrypto.isValidEncryptedBlobBase64('!!!not base64!!!'), isFalse);
      expect(WalletFileCrypto.isValidEncryptedBlobBase64(base64.encode([1, 2, 3])), isFalse);
    });
  });
}
