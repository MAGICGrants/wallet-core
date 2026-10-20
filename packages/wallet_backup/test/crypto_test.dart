import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' show Blake2bDigest;
import 'package:wallet_backup/src/crypto.dart';
import 'package:wallet_domain/wallet_domain.dart' show carrotHash, carrotHash32;

Uint8List seq(int start, int n) => Uint8List.fromList(List.generate(n, (i) => (start + i) & 0xff));

String blake256(Uint8List data) => toHex(Blake2bDigest(digestSize: 32).process(data));

/// Expected values come from libsodium 1.0.22 (the copy vendored in
/// wallet_fhse), `crypto_aead_xchacha20poly1305_ietf_encrypt` with
/// key = 80..9f, nonce = 40..57, AD = 01 00 00, and plaintext byte i =
/// (31 i + 7) mod 256; the long ciphertexts are given by their BLAKE2b-256.
void main() {
  final key = seq(0x80, 32);
  final nonce = seq(0x40, 24);
  final ad = Uint8List.fromList([1, 0, 0]);
  Uint8List message(int n) => Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xff));

  test('HChaCha20 matches draft-irtf-cfrg-xchacha §2.2.1', () {
    final out = XChaCha20Poly1305.hChaCha20(
      seq(0, 32),
      fromHex('000000090000004a0000000031415927'),
    );
    expect(toHex(out), '82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc');
  });

  test('XChaCha20-Poly1305 matches draft-irtf-cfrg-xchacha A.3.1 (via libsodium)', () {
    const pt =
        "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the "
        'future, sunscreen would be it.';
    final sealed = XChaCha20Poly1305.seal(
      key,
      nonce,
      fromHex('50515253c0c1c2c3c4c5c6c7'),
      Uint8List.fromList(utf8.encode(pt)),
    );
    expect(
      toHex(sealed),
      'bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4e'
      'da7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2'
      '383565d3fff921f9664c97637da9768812f615c68b13b52ec0875924c1c7987947deafd8780acf49',
    );
  });

  const short = {
    0: '7f90ce08584b2a992c2f3056f1d80ce8',
    1: 'f6096fb307fd1eb61523f7f2ac45d2c321',
    63:
        'f62a3690d85235ba040c4a8f8d34248dc551473a76d62d3c25b4d84029dfa400e73a353948ef3ebdee2dfc7535e9c7e2'
        '16e7bf20ff4935c0610a9a7b360c1d820509b222c885ac8a4666344a3d4321',
    64:
        'f62a3690d85235ba040c4a8f8d34248dc551473a76d62d3c25b4d84029dfa400e73a353948ef3ebdee2dfc7535e9c7e2'
        '16e7bf20ff4935c0610a9a7b360c1d95df3678032842a9951e98f996754f92f1',
    65:
        'f62a3690d85235ba040c4a8f8d34248dc551473a76d62d3c25b4d84029dfa400e73a353948ef3ebdee2dfc7535e9c7e2'
        '16e7bf20ff4935c0610a9a7b360c1d958604c2c7930ff1e6e8a792a28779c51394',
  };
  const long = {
    977: 'c4cf3a861d211254a04481bba72d83f47bbd33a9d4741ca6aebf37988005a298',
    4096: '44d741a6d013862579d5da0db8a5acd0248ab740415323397f210abe8b29854c',
    65493: '9864e45a45822da8cbb28e593423158ade4a29512952a5b043e98d2af8aa6b8e',
  };

  for (final e in short.entries) {
    test('libsodium vector, ${e.key} bytes', () {
      final sealed = XChaCha20Poly1305.seal(key, nonce, ad, message(e.key));
      expect(toHex(sealed), e.value);
      expect(XChaCha20Poly1305.open(key, nonce, ad, sealed), message(e.key));
    });
  }
  for (final e in long.entries) {
    test('libsodium vector, ${e.key} bytes', () {
      final sealed = XChaCha20Poly1305.seal(key, nonce, ad, message(e.key));
      expect(blake256(sealed), e.value);
      expect(XChaCha20Poly1305.open(key, nonce, ad, sealed), message(e.key));
    });
  }

  test('any changed byte fails to open', () {
    final sealed = XChaCha20Poly1305.seal(key, nonce, ad, message(100));
    for (final i in [0, 50, sealed.length - 1]) {
      final bad = Uint8List.fromList(sealed)..[i] ^= 1;
      expect(
        () => XChaCha20Poly1305.open(key, nonce, ad, bad),
        throwsA(isA<AuthenticationFailed>()),
      );
    }
    final badAd = Uint8List.fromList([1, 0, 1]);
    expect(
      () => XChaCha20Poly1305.open(key, nonce, badAd, sealed),
      throwsA(isA<AuthenticationFailed>()),
    );
    final badNonce = Uint8List.fromList(nonce)..[20] ^= 1;
    expect(
      () => XChaCha20Poly1305.open(key, badNonce, ad, sealed),
      throwsA(isA<AuthenticationFailed>()),
    );
    expect(
      () => XChaCha20Poly1305.open(key, nonce, ad, Uint8List(5)),
      throwsA(isA<AuthenticationFailed>()),
    );
  });

  // libsodium crypto_generichash_blake2b_salt_personal, key 80..9f, personal
  // "Monero", input 0x19 ‖ "Monero metadata backup v1".
  test("Carrot's keyed BLAKE2b matches libsodium's salt_personal", () {
    expect(
      toHex(carrotHash32(key, 'Monero metadata backup v1')),
      '8d40b53a6476bce4cd18a7732144124572ba25683c6a860a995bf635db7ac1ee',
    );
    expect(
      toHex(carrotHash(16, key, 'Monero metadata backup v1')),
      '855546fabced1f3512d39e7f8059d23c',
    );
  });
}
