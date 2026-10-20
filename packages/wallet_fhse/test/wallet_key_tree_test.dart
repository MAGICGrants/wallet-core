import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:polyseed/polyseed.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fhse/wallet_fhse.dart';

import 'support/host_library.dart';

const bip39Mnemonic =
    'abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon address';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

String newPolyseed() => Polyseed.create().encode(
  PolyseedLang.getByEnglishName('English'),
  PolyseedCoin.POLYSEED_MONERO,
);

void main() {
  final skip = useHostLibrary();

  // The KDF FHSE uses for its root, here through wfhse_kdf: the same 32 bytes
  // as FHSE's test vector `seed1_bin`.
  test('kdf matches libsodium crypto_kdf_blake2b as FHSE uses it', () {
    final root = WalletKeyTree.kdf(
      Uint8List.fromList(utf8.encode('dummy seed 1 for fhse unit tests')),
      'FHSEROOT',
    );
    expect(
      root.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      'bc6949adcbc52b759d6db6764c2639503242fd243c4de0a2cf027aed7055e0f6',
    );
  }, skip: skip);

  // The FHSE seed is SeedSecret's FHSE purpose, a sibling of the metadata root
  // (vectors from wallet_domain's seed_secret_test.dart).
  test('polyseed: the FHSE seed is H_32[r_p]("Monero FHSE seed")', () async {
    const raven =
        'raven tail swear infant grief assist regular lamp duck valid someone little harsh '
        'puppy airport language';
    final sf = await WalletKeyTree.fhseSeedFor(const PolyseedSeed(raven));
    expect(hex(sf), '0cd96b9ca2aae3af3eaea5d679c272c40a216886c041fd1364f1d1ade565f4d8');
    final m = SeedSecret.deriveSync(SeedFormat.polyseed, raven, '', SeedPurpose.metadata);
    expect(sf, isNot(m));
  }, skip: skip);

  test('BIP39: the FHSE seed is H_32[r]("Monero FHSE seed" ‖ IntToBytes32(0))', () async {
    const abandon =
        'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon about';
    expect(
      hex(await WalletKeyTree.fhseSeedFor(const Bip39Seed(abandon))),
      '524b1b466ea9bb86e19cdc221886da67e3463687660f45151809883815354625',
    );
  }, skip: skip);

  test('polyseed: the FHSE seed is a function of the seed alone', () async {
    final mnemonic = newPolyseed();
    final a = await WalletKeyTree.fhseSeedFor(PolyseedSeed(mnemonic));
    final b = await WalletKeyTree.fhseSeedFor(PolyseedSeed(mnemonic));
    final other = await WalletKeyTree.fhseSeedFor(PolyseedSeed(newPolyseed()));
    expect(a, hasLength(32));
    expect(a, b);
    expect(a, isNot(other));
    expect(WalletKeyTree.isSeedDerived(PolyseedSeed(mnemonic)), isTrue);
  }, skip: skip);

  test('BIP39: deterministic, and the passphrase changes it', () async {
    final a = await WalletKeyTree.fhseSeedFor(const Bip39Seed(bip39Mnemonic));
    final b = await WalletKeyTree.fhseSeedFor(const Bip39Seed(bip39Mnemonic));
    final withPassphrase = await WalletKeyTree.fhseSeedFor(
      const Bip39Seed(bip39Mnemonic, passphrase: 'x'),
    );
    expect(a, b);
    expect(a, isNot(withPassphrase));
  }, skip: skip);

  test('25-word legacy: random, never derived from the spend key', () async {
    final seed = MoneroLegacySeed(List.filled(25, 'abbey').join(' '));
    final a = await WalletKeyTree.fhseSeedFor(seed);
    final b = await WalletKeyTree.fhseSeedFor(seed);
    expect(a, hasLength(32));
    expect(a, isNot(b));
    expect(WalletKeyTree.isSeedDerived(seed), isFalse);
  }, skip: skip);
}
