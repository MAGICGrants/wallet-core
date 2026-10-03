import 'package:blockchain_utils/blockchain_utils.dart';

import 'monero_test_crypto.dart';

/// One input of a [MoneroTx]: its ring, as absolute global output indices, and
/// its key image.
typedef MoneroTxInput = ({List<int> ring, List<int> keyImage});

/// One output of a [MoneroTx]: its one-time key and, when it has one, its view
/// tag.
typedef MoneroTxOutput = ({List<int> key, int? viewTag});

/// A Monero RingCT transaction, read far enough to check what a wallet built:
/// the rings and key images, the output keys, the transaction public key, and
/// the fee, encrypted amounts and commitments in the RingCT base. The prunable
/// part (range proof and ring signatures) is hashed, not parsed.
///
/// Test-only. It accepts the transactions current wallets build (version 2,
/// key inputs, Bulletproofs or Bulletproofs+ with compact amounts) and throws
/// a [FormatException] on anything else.
final class MoneroTx {
  MoneroTx._({
    required this.unlockTime,
    required this.inputs,
    required this.outputs,
    required this.extra,
    required this.rctType,
    required this.fee,
    required this.encryptedAmounts,
    required this.commitments,
    required this.hash,
  });

  factory MoneroTx.parse(List<int> blob) {
    final r = _Reader(blob);

    final version = r.varint();
    if (version != BigInt.two) throw FormatException('transaction version $version');
    final unlockTime = r.varint();

    final inputs = <MoneroTxInput>[];
    for (var i = r.count(); i > 0; i--) {
      final tag = r.byte();
      if (tag != _txinToKey) throw FormatException('input type 0x${tag.toRadixString(16)}');
      r.varint(); // amount: 0 for RingCT
      // The ring is stored as offsets, each relative to the one before.
      final ring = <int>[];
      var index = 0;
      for (var n = r.count(); n > 0; n--) {
        index += r.varint().toInt();
        ring.add(index);
      }
      inputs.add((ring: ring, keyImage: r.bytes(32)));
    }

    final outputs = <MoneroTxOutput>[];
    for (var i = r.count(); i > 0; i--) {
      r.varint(); // amount: 0 for RingCT
      final tag = r.byte();
      if (tag == _txoutToKey) {
        outputs.add((key: r.bytes(32), viewTag: null));
      } else if (tag == _txoutToTaggedKey) {
        outputs.add((key: r.bytes(32), viewTag: r.byte()));
      } else {
        throw FormatException('output type 0x${tag.toRadixString(16)}');
      }
    }

    final extra = r.bytes(r.count());
    final prefixEnd = r.position;

    final rctType = r.byte();
    if (!_compactAmountTypes.contains(rctType)) throw FormatException('RingCT type $rctType');
    final fee = r.varint();
    final encryptedAmounts = [for (var i = 0; i < outputs.length; i++) r.bytes(8)];
    final commitments = [for (var i = 0; i < outputs.length; i++) r.bytes(32)];
    final baseEnd = r.position;

    // The transaction id hashes the hashes of its three parts: the prefix, the
    // RingCT base, and the prunable rest.
    final hash = QuickCrypto.keccack256Hash([
      ...QuickCrypto.keccack256Hash(blob.sublist(0, prefixEnd)),
      ...QuickCrypto.keccack256Hash(blob.sublist(prefixEnd, baseEnd)),
      ...QuickCrypto.keccack256Hash(blob.sublist(baseEnd)),
    ]);

    return MoneroTx._(
      unlockTime: unlockTime,
      inputs: inputs,
      outputs: outputs,
      extra: extra,
      rctType: rctType,
      fee: fee,
      encryptedAmounts: encryptedAmounts,
      commitments: commitments,
      hash: hash,
    );
  }

  static const _txinToKey = 0x02;
  static const _txoutToKey = 0x02;
  static const _txoutToTaggedKey = 0x03;

  /// `RCTTypeBulletproof2`, `RCTTypeCLSAG` and `RCTTypeBulletproofPlus`: the
  /// types whose base stores 8-byte encrypted amounts and no pseudo-outputs.
  static const _compactAmountTypes = {4, 5, 6};

  /// `rct::RCTTypeBulletproofPlus`, what wallets build today.
  static const rctTypeBulletproofPlus = 6;

  final BigInt unlockTime;
  final List<MoneroTxInput> inputs;
  final List<MoneroTxOutput> outputs;
  final List<int> extra;
  final int rctType;
  final BigInt fee;
  final List<List<int>> encryptedAmounts;
  final List<List<int>> commitments;

  /// The transaction id.
  final List<int> hash;

  /// The transaction public key, R, from the extra field.
  List<int>? get txPublicKey => _extraFields()[_extraPublicKey]?.single;

  /// The per-output public keys a transaction carries when it pays
  /// subaddresses alongside other addresses.
  List<List<int>> get additionalPublicKeys => _extraFields()[_extraAdditionalKeys] ?? const [];

  /// What output [i] pays the address whose spend key is [spendPublicKey], as
  /// the holder of [viewSecret] reads it, or null when it pays someone else.
  ///
  /// Throws a [StateError] when the output's key is theirs but its commitment
  /// does not open to the amount it decrypts to: an output its owner could
  /// not spend.
  BigInt? amountPaidTo(int i, {required BigInt viewSecret, required List<int> spendPublicKey}) {
    final txKeys = [
      ?txPublicKey,
      if (additionalPublicKeys.length == outputs.length) additionalPublicKeys[i],
    ];
    for (final txKey in txKeys) {
      final derivation = MoneroTestCrypto.keyDerivation(txKey, viewSecret);
      final key = MoneroTestCrypto.derivePublicKey(derivation, i, spendPublicKey);
      if (!BytesUtils.bytesEqual(key, outputs[i].key)) continue;

      final shared = MoneroTestCrypto.derivationToScalar(derivation, i);
      final amount = MoneroTestCrypto.decodeAmount(encryptedAmounts[i], shared);
      final opened = MoneroTestCrypto.commit(amount, MoneroTestCrypto.commitmentMask(shared));
      if (!BytesUtils.bytesEqual(opened, commitments[i])) {
        throw StateError('output $i is theirs, but its commitment does not open to $amount');
      }
      return amount;
    }
    return null;
  }

  static const _extraPublicKey = 0x01;
  static const _extraNonce = 0x02;
  static const _extraAdditionalKeys = 0x04;

  /// The extra fields wallets write, by tag. Padding runs to the end and an
  /// unknown field's length cannot be known, so reading stops at either, as
  /// Monero's own parser does.
  Map<int, List<List<int>>> _extraFields() {
    final r = _Reader(extra);
    final fields = <int, List<List<int>>>{};
    while (r.remaining > 0) {
      final tag = r.byte();
      if (tag == _extraPublicKey) {
        fields[tag] = [r.bytes(32)];
      } else if (tag == _extraNonce) {
        fields[tag] = [r.bytes(r.count())];
      } else if (tag == _extraAdditionalKeys) {
        fields[tag] = [for (var n = r.count(); n > 0; n--) r.bytes(32)];
      } else {
        break;
      }
    }
    return fields;
  }
}

final class _Reader {
  _Reader(this._data);

  final List<int> _data;
  var position = 0;

  int get remaining => _data.length - position;

  int byte() {
    if (remaining < 1) throw const FormatException('transaction ends early');
    return _data[position++];
  }

  List<int> bytes(int n) {
    if (n < 0 || remaining < n) throw const FormatException('transaction ends early');
    return _data.sublist(position, position += n);
  }

  /// Monero's varint: seven bits per byte, low bits first.
  BigInt varint() {
    var value = BigInt.zero;
    for (var shift = 0; shift < 64; shift += 7) {
      final b = byte();
      value |= BigInt.from(b & 0x7f) << shift;
      if (b & 0x80 == 0) return value;
    }
    throw const FormatException('varint too long');
  }

  /// A length or count, which must fit what is left of the transaction.
  int count() {
    final n = varint();
    if (n > BigInt.from(remaining)) throw FormatException('count $n exceeds the transaction');
    return n.toInt();
  }
}
