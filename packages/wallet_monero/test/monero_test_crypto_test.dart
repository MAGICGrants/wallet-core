import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/monero_test_crypto.dart';

/// The arithmetic the LWSF send test uses to build outputs its wallet owns,
/// checked against vectors from Monero's `tests/crypto/tests.txt`. If any of
/// these fail, a failing send test says nothing about LWSF.
void main() {
  List<int> hex(String s) => BytesUtils.fromHexString(s);
  String toHex(List<int> b) => BytesUtils.toHexString(b);

  test('hash_to_scalar', () {
    const vectors = {
      '0b6a0ae839214674e9b275aa1986c6352ec7ec6c4ae583ab5a62b947a9dee972':
          '24f9167e1a3eaab18119c225577f0ecc7a488a309e54e2721cbaea62c3db3a06',
      '854b5522f6a7a50af76e305c65bc65d2ad7603a00e244aabab4b0e419576c7b1':
          '20a8a23806bfa8ac1e3d7a227bc4c3554a18f5e593e5f8b807767c3f818ebe06',
    };
    vectors.forEach((input, expected) {
      expect(
        toHex(MoneroTestCrypto.scalarBytes(MoneroTestCrypto.hashToScalar(hex(input)))),
        expected,
      );
    });
  });

  test('secret_key_to_public_key', () {
    const vectors = {
      'b2f420097cd63cdbdf834d090b1e604f08acf0af5a3827d0887863aaa4cc4406':
          'd764c19d6c14280315d81eb8f2fc777582941047918f52f8dcef8225e9c92c52',
      'f264699c939208870fecebc013b773b793dd18ea39dbe1cb712a19a692fdb000':
          'bcb483f075d37658b854d4b9968fafae976e5532ca99879479c85ef5da1deead',
      'bd65eb76171bb9b9542a6e06b9503c09fd4a9290fe51828ed766e5aeb742dc02':
          '1dec6cc63ff1984ee46a70a46687877a87fcc1e790562da73b33b1a8fd8cad37',
    };
    vectors.forEach((secret, expected) {
      expect(toHex(MoneroTestCrypto.publicKey(MoneroTestCrypto.scalar(hex(secret)))), expected);
    });
  });

  test('generate_key_derivation', () {
    const vectors = [
      (
        'ba7b73dfa3185875538871e425a4ec8d5f16cac09db14cefd5510568a66eff3e',
        'c9b52fd93365c57220178996d97cc979c752d56a8199568dd2c882486f7f1d0a',
        'f5bb6522dea0c40229928766fb7019ac4be3022469c8d825ae965b8af3d3c517',
      ),
      (
        '45f6f692d8dc545deff096b048e94ee25acd7bf67fb49f7d83107f9969b9bc67',
        '4451358855fb52b2199db97b33b6d7d47ac2b4067ecdf5ed20bb32162543270a',
        'bcdc1f0c4b6cc6bc1847728630c3060dd1982d51bb06873f53a4a13998510cc1',
      ),
      (
        '71329cf72de45f5b98fdd233707501f87aa4130db40b3570527801d5d24e2be5',
        'b8bc1ee2987bb7451e90c6e7885ce5f6d2f4ae12e5e724ab8432769af66a2307',
        '7498d5bf0b69e08653f6d420a17f866dd2bd490ab43074f46065cb501fe7e2d8',
      ),
    ];
    for (final (txPublicKey, viewSecret, expected) in vectors) {
      expect(
        toHex(
          MoneroTestCrypto.keyDerivation(
            hex(txPublicKey),
            MoneroTestCrypto.scalar(hex(viewSecret)),
          ),
        ),
        expected,
      );
    }
  });

  test('derive_public_key', () {
    const vectors = [
      (
        'b7884ba954056a2c33f2da970e4b14de9a9fee254d569e34c68c43a1835234c1',
        771,
        'fd90bc87b73dfcc94ddd5e1b5090ee6537b4ccbe1fade2b542d9073f980a1db4',
        'dc9700bfa55175403c5c2db22d2685252504e4379e4fc169fe52e1bb8b65e869',
      ),
      (
        '75c4b56550636fa58f837511c8054106633b577654e80f766cc608aaefb67dd4',
        7040,
        '6b7a50dc0993b9d7c96fd028153cf9e8abb150e461b25c15ba2c437e52aefcbe',
        'ff8bc368609807c9d3da866ac660d8f051b6f93b2709fb5dc303e5eeca4300bd',
      ),
      (
        'ce07639dd9afda564b2e6322c32660e53b699ee67d54ebc223d49eb424f8d2ab',
        20,
        'b4e4ca4f5c43f50487dbc6920e9928ae5d03963f436c7079e0d9d2eb0b9485f6',
        '7aa03cda46c000b1ef3ab295cbebc9fa810ff61a1d6ea047e66269fefda6dd94',
      ),
    ];
    for (final (derivation, index, base, expected) in vectors) {
      expect(toHex(MoneroTestCrypto.derivePublicKey(hex(derivation), index, hex(base))), expected);
    }
  });

  test('commitments: mask·G + amount·H, and additively homomorphic', () {
    final m1 = MoneroTestCrypto.randomScalar();
    final m2 = MoneroTestCrypto.randomScalar();
    final a1 = BigInt.from(700000000000);
    final a2 = BigInt.from(1234567);

    expect(MoneroTestCrypto.commit(BigInt.zero, m1), MoneroTestCrypto.publicKey(m1));
    expect(
      MoneroTestCrypto.commit(BigInt.one, m1),
      MoneroTestCrypto.add(
        MoneroTestCrypto.publicKey(m1),
        hex('8b655970153799af2aeadc9ff1add0ea6c7251d54154cfa92c173a0dd39c1f94'),
      ),
    );
    expect(
      MoneroTestCrypto.add(MoneroTestCrypto.commit(a1, m1), MoneroTestCrypto.commit(a2, m2)),
      MoneroTestCrypto.commit(a1 + a2, m1 + m2),
    );
  });
}
