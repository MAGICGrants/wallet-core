import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:blockchain_utils/blockchain_utils.dart';

/// Just enough Monero key arithmetic to give a test wallet outputs it really
/// owns: the one-time output key, the RingCT mask and commitment, and decoys
/// that are valid curve points. Checked against Monero's own crypto test
/// vectors in `monero_test_crypto_test.dart`.
///
/// Test-only. Nothing here is constant-time.
abstract final class MoneroTestCrypto {
  static final _curve = Curves.curveEd25519;
  static final EDPoint _g = Curves.generatorED25519;

  /// The order of the prime subgroup, l.
  static final BigInt l = Curves.generatorED25519.order!;

  /// Monero's second Pedersen generator, H (`rct::H`).
  static final EDPoint _h = point(
    BytesUtils.fromHexString('8b655970153799af2aeadc9ff1add0ea6c7251d54154cfa92c173a0dd39c1f94'),
  );

  static final _random = Random.secure();

  static EDPoint point(List<int> bytes) => EDPoint.fromBytes(curve: _curve, data: bytes);

  static List<int> encode(EDPoint p) => p.toBytes();

  /// A 32-byte little-endian scalar, reduced mod l.
  static BigInt scalar(List<int> bytes) =>
      BigintUtils.fromBytes(bytes, byteOrder: Endian.little) % l;

  static List<int> scalarBytes(BigInt s) =>
      BigintUtils.toBytes(s % l, length: 32, order: Endian.little);

  /// Monero's `hash_to_scalar`: Keccak-256, reduced mod l.
  static BigInt hashToScalar(List<int> data) => scalar(QuickCrypto.keccack256Hash(data));

  /// Monero's varint: seven bits per byte, low bits first.
  static List<int> varint(int value) {
    final out = <int>[];
    var v = value;
    while (v >= 0x80) {
      out.add((v & 0x7f) | 0x80);
      v >>= 7;
    }
    out.add(v);
    return out;
  }

  static List<int> publicKey(BigInt secret) => encode(_g * (secret % l));

  /// `generate_key_derivation`: 8·(a·R). Multiplied in that order, as Monero
  /// does, so a point with a torsion component gives the same answer.
  static List<int> keyDerivation(List<int> txPublicKey, BigInt viewSecret) =>
      encode((point(txPublicKey) * viewSecret) * BigInt.from(8));

  /// `derivation_to_scalar`: Hs(derivation || varint(index)).
  static BigInt derivationToScalar(List<int> derivation, int index) =>
      hashToScalar([...derivation, ...varint(index)]);

  /// `derive_public_key`: Hs(derivation || index)·G + base.
  static List<int> derivePublicKey(List<int> derivation, int index, List<int> base) =>
      encode(_g * derivationToScalar(derivation, index) + point(base));

  /// `rct::genCommitmentMask`: the mask of an output whose amount is encrypted
  /// with the shared secret `Hs(derivation || index)`.
  static BigInt commitmentMask(BigInt sharedSecret) =>
      hashToScalar([...utf8.encode('commitment_mask'), ...scalarBytes(sharedSecret)]);

  /// `rct::ecdhDecode` for an 8-byte encrypted amount: the little-endian
  /// amount, XORed with Keccak("amount" || shared secret).
  static BigInt decodeAmount(List<int> encrypted, BigInt sharedSecret) => BigintUtils.fromBytes([
    for (final (i, b) in amountPad(sharedSecret).indexed) encrypted[i] ^ b,
  ], byteOrder: Endian.little);

  /// The 8 bytes an amount is XORed with.
  static List<int> amountPad(BigInt sharedSecret) => QuickCrypto.keccack256Hash([
    ...utf8.encode('amount'),
    ...scalarBytes(sharedSecret),
  ]).sublist(0, 8);

  /// `rct::commit`: mask·G + amount·H. The point library cannot add the point
  /// at infinity, so a zero amount is the blinding term alone.
  static List<int> commit(BigInt amount, BigInt mask) {
    final blinding = _g * (mask % l);
    return encode(amount == BigInt.zero ? blinding : blinding + _h * amount);
  }

  static List<int> add(List<int> a, List<int> b) => encode(point(a) + point(b));

  static BigInt randomScalar() =>
      BigintUtils.fromBytes(List<int>.generate(64, (_) => _random.nextInt(256))) % l;

  /// A random point in the prime subgroup, for decoy keys and commitments.
  static List<int> randomPoint() => publicKey(randomScalar());
}
