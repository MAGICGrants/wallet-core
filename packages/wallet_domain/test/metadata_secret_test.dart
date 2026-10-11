import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
]);

/// Vectors from ai-audit-resources, research-projects/2026-10-09-carrot-seed-derivations
/// (code/seed_to_carrot.out.txt), computed there from the reference C polyseed library
/// and checked against the SLIP-21 spec's own vectors.
void main() {
  const raven =
      'raven tail swear infant grief assist regular lamp duck valid someone little harsh '
      'puppy airport language';
  const abandon =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon about';

  test('PM-a: r_p is the second PBKDF2 block of polyseed_keygen', () {
    expect(
      hex(MetadataSecret.polyseedRoot(raven)),
      '4fc0b85f6898ac7a75bcf7662edbc14160b9dca3ccb0b110a327b53ede5a4926',
    );
  });

  test('PM-a: M for polyseed', () {
    expect(
      hex(MetadataSecret.deriveSync(SeedFormat.polyseed, raven, '')),
      '8f30e2453f4b16c9192e17da5ba83e5e26ca2f500cbd8a465518676483586cd3',
    );
  });

  test('SLIP-21 matches the spec vector for m/"SLIP-0021"', () {
    final s = unhex(
      'c76c4ac4f4e4a00d6b274d5c39c700bb4a7ddc04fbc6f78e85ca75007b5b495f'
      '74a9043eeb77bdd53aa6fc3a0e31462270316fa04b8c19114c8798706cd02ac8',
    );
    expect(
      hex(MetadataSecret.slip21Key(s, 'SLIP-0021'.codeUnits)),
      '1d065e3ac1bbe5c7fad32cf2305f7d709dc070d672044a19e610c77cdf33de0d',
    );
  });

  test('BM-a: M for BIP39, account 0', () {
    expect(
      hex(MetadataSecret.deriveSync(SeedFormat.bip39, abandon, '')),
      'b6a0415c177f66201dd5b0bb300bd72656c88053c59b4b29317b82f6a2adfb08',
    );
  });

  test('BIP39 passphrase and account change M', () {
    final base = MetadataSecret.deriveSync(SeedFormat.bip39, abandon, '');
    expect(MetadataSecret.deriveSync(SeedFormat.bip39, abandon, 'x'), isNot(base));
    expect(MetadataSecret.deriveSync(SeedFormat.bip39, abandon, '', account: 1), isNot(base));
  });

  test('25-word seeds and polyseed offsets have no M', () async {
    final legacy = MoneroLegacySeed(List.filled(25, 'abbey').join(' '));
    expect(MetadataSecret.isAvailableFor(legacy), isFalse);
    expect(() => MetadataSecret.derive(legacy), throwsA(isA<MetadataSecretUnavailable>()));
    const offset = PolyseedSeed(raven, passphrase: 'offset');
    expect(MetadataSecret.isAvailableFor(offset), isFalse);
  });

  test('derive runs off-isolate and agrees with deriveSync', () async {
    expect(
      hex(await MetadataSecret.derive(const PolyseedSeed(raven))),
      '8f30e2453f4b16c9192e17da5ba83e5e26ca2f500cbd8a465518676483586cd3',
    );
  });
}
