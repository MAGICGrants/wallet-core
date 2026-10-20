import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
]);

/// Vectors computed independently of this code: `r_p` from the reference C
/// polyseed library, the rest from a standalone Python implementation of
/// SLIP-21 and Carrot's hash (stdlib `hashlib`), which also reproduces the
/// SLIP-21 spec's own vector.
void main() {
  const raven =
      'raven tail swear infant grief assist regular lamp duck valid someone little harsh '
      'puppy airport language';
  const abandon =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon about';

  String polyseed(SeedPurpose purpose) =>
      hex(SeedSecret.deriveSync(SeedFormat.polyseed, raven, '', purpose));
  String bip39(SeedPurpose purpose, {String passphrase = '', int account = 0}) =>
      hex(SeedSecret.deriveSync(SeedFormat.bip39, abandon, passphrase, purpose, account: account));

  test('polyseed: r_p is the second PBKDF2 block of polyseed_keygen', () {
    expect(
      hex(SeedSecret.polyseedBase(raven)),
      '4fc0b85f6898ac7a75bcf7662edbc14160b9dca3ccb0b110a327b53ede5a4926',
    );
  });

  test('polyseed: M and the FHSE seed', () {
    expect(
      polyseed(SeedPurpose.metadata),
      '9abb0ca6e643fffe0e397e411f7dd005a403994ce9b0e02d50560cf8e603e50e',
    );
    expect(
      polyseed(SeedPurpose.fhse),
      '0cd96b9ca2aae3af3eaea5d679c272c40a216886c041fd1364f1d1ade565f4d8',
    );
  });

  test('SLIP-21 matches the spec vector for m/"SLIP-0021"', () {
    final s = unhex(
      'c76c4ac4f4e4a00d6b274d5c39c700bb4a7ddc04fbc6f78e85ca75007b5b495f'
      '74a9043eeb77bdd53aa6fc3a0e31462270316fa04b8c19114c8798706cd02ac8',
    );
    expect(
      hex(SeedSecret.slip21Key(s, 'SLIP-0021'.codeUnits)),
      '1d065e3ac1bbe5c7fad32cf2305f7d709dc070d672044a19e610c77cdf33de0d',
    );
  });

  test('BIP39: r is SLIP-21 m/"Monero" of the BIP39 seed', () {
    expect(
      hex(SeedSecret.bip39Base(abandon, '')),
      'c72a7cd56dd4c99c474d0fc04c862643d083bc58b3466000cb2407ff10d48405',
    );
  });

  test('BIP39: M and the FHSE seed for account 0', () {
    expect(
      bip39(SeedPurpose.metadata),
      '99ac2ade2bbcd583c98f2c37b51cae3ed402258ffd9f0971cd864aa11bab2861',
    );
    expect(
      bip39(SeedPurpose.fhse),
      '524b1b466ea9bb86e19cdc221886da67e3463687660f45151809883815354625',
    );
  });

  test('every purpose has its own domain string', () {
    final domains = SeedPurpose.values.map((p) => p.domain).toSet();
    expect(domains, hasLength(SeedPurpose.values.length));
  });

  test('the BIP39 passphrase and account change every purpose', () {
    for (final purpose in SeedPurpose.values) {
      final base = bip39(purpose);
      expect(bip39(purpose, passphrase: 'x'), isNot(base));
      expect(bip39(purpose, account: 1), isNot(base));
    }
  });

  test('25-word seeds and polyseed offsets have no seed secrets', () async {
    final legacy = MoneroLegacySeed(List.filled(25, 'abbey').join(' '));
    expect(SeedSecret.isAvailableFor(legacy), isFalse);
    expect(
      () => SeedSecret.derive(legacy, SeedPurpose.metadata),
      throwsA(isA<SeedSecretUnavailable>()),
    );
    const offset = PolyseedSeed(raven, passphrase: 'offset');
    expect(SeedSecret.isAvailableFor(offset), isFalse);
  });

  test('derive runs off-isolate and agrees with deriveSync', () async {
    expect(
      hex(await SeedSecret.derive(const PolyseedSeed(raven), SeedPurpose.metadata)),
      '9abb0ca6e643fffe0e397e411f7dd005a403994ce9b0e02d50560cf8e603e50e',
    );
  });
}
