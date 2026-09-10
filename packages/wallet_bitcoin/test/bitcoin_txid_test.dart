import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_bitcoin/wallet_bitcoin.dart';

/// The vector is BIP143's P2WPKH example; the canonical signed segwit
/// transaction, reproduced in the BIP itself and in every implementation's test
/// suite. It is used here rather than a transaction this repo builds because the
/// whole point of [computeTxid] is to be an *independent* check on what
/// `bitcoin_base` produced; anchoring it to a vector from outside the repo is
/// what makes it independent.
const _bip143SignedP2wpkh =
    '01000000000102fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f'
    '00000000494830450221008b9d1dc26ba6a9cb62127b02742fa9d754cd3bebf337f7a55d114c8e5cdd30be'
    '022040529b194ba3f9281a99f2b1c0a19c0489bc22ede944ccf4ecbab4cc618ef3ed01eeffffffef51e1b8'
    '04cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100000000ffffffff02202cb20600'
    '0000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac9093510d000000001976a9143bde'
    '42dbee7e4dbe6a21b2d50ce2f0167faa815988ac000247304402203609e17b84f6a7d30c80bfa610b5b454'
    '2f32a8a0d5447a12fb1366d7f01cc44a0220573a954c4518331561406f90300e8f3358f51928d43c212a8ca'
    'ed02de67eebee0121025476c2e83188368da1ff3e292e7acafcdb3566bb0ad253f62fc70f07aeee63571100'
    '0000';

/// The same transaction with the marker, flag and both witness stacks removed;
/// which is what a txid is computed over. Assembled from the pieces BIP143
/// documents (two inputs, the first with a 0x49-byte scriptSig and the second
/// with none, two P2PKH outputs, nLockTime 0x11).
const _bip143Stripped =
    '01000000'
    '02'
    'fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f00000000'
    '494830450221008b9d1dc26ba6a9cb62127b02742fa9d754cd3bebf337f7a55d114c8e5cdd30be'
    '022040529b194ba3f9281a99f2b1c0a19c0489bc22ede944ccf4ecbab4cc618ef3ed01'
    'eeffffff'
    'ef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a01000000'
    '00ffffffff'
    '02'
    '202cb2060000000019'
    '76a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac'
    '9093510d0000000019'
    '76a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac'
    '11000000';

void main() {
  group('computeTxid', () {
    test('matches the BIP143 P2WPKH vector', () {
      expect(
        computeTxid(_bip143SignedP2wpkh),
        'e8151a2af31c368a35053ddd4bdb285a8595c769a3ad83e0fa02314a602d4609',
      );
    });

    test('is NOT the hash of the broadcast bytes', () {
      // The distinction this function exists for. Hashing the raw serialization
      // yields the wtxid, which no Electrum server will ever return, so a
      // comparison built on it would fail on every single send.
      expect(
        computeTxid(_bip143SignedP2wpkh),
        isNot('c36c38370907df2324d9ce9d149d191192f338b37665a82e78e76a12c909b762'),
      );
    });

    test('the witness-stripped form is a fixed point', () {
      // A pre-segwit transaction is already its own txid preimage, so stripping
      // it again must change nothing, and the stripped form of a segwit
      // transaction is exactly such a transaction.
      expect(computeTxid(_bip143Stripped), computeTxid(_bip143SignedP2wpkh));
    });

    test('rejects a truncated transaction rather than hashing a prefix', () {
      expect(
        () => computeTxid(_bip143SignedP2wpkh.substring(0, _bip143SignedP2wpkh.length - 4)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects trailing bytes', () {
      // Silent acceptance here would mean a server could append padding and get
      // a different txid for the same transaction.
      expect(() => computeTxid('${_bip143SignedP2wpkh}00'), throwsA(isA<FormatException>()));
    });

    test('rejects a segwit marker with a zero flag', () {
      final bad = '010000000000${_bip143SignedP2wpkh.substring(12)}';
      expect(() => computeTxid(bad), throwsA(isA<FormatException>()));
    });

    test('rejects malformed hex', () {
      expect(() => computeTxid('abc'), throwsA(isA<FormatException>()));
      expect(() => computeTxid('zz00'), throwsA(isA<FormatException>()));
    });

    test('rejects an absurd field length instead of allocating on it', () {
      // Version, marker, flag, then an 8-byte varint input count of 2^63-1.
      const bad = '010000000001ffffffffffffffff7f';
      expect(() => computeTxid(bad), throwsA(isA<FormatException>()));
    });
  });

  group('isTxidShaped', () {
    test('accepts a 64-char lowercase hex string', () {
      expect(isTxidShaped('a' * 64), isTrue);
      expect(isTxidShaped('0123456789abcdef' * 4), isTrue);
    });

    test('rejects what a rejecting server actually sends', () {
      // These are the shapes that used to be recorded as a transaction id, and
      // therefore as a sent payment.
      for (final reply in [
        '',
        'sandbox error: dust',
        'the transaction was rejected by network rules.',
        '258: txn-mempool-conflict',
        'A' * 64, // uppercase: not the form a server returns
        'a' * 63,
        'a' * 65,
        '0x${'a' * 64}', // hex-prefixed, i.e. not a Bitcoin txid
      ]) {
        expect(isTxidShaped(reply), isFalse, reason: reply);
      }
    });
  });
}
