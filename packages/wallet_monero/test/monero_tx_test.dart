import 'dart:typed_data';

import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/monero_test_crypto.dart';
import 'support/monero_tx.dart';

/// The parser the LWSF send test reads a submitted transaction with. A real
/// mainnet transaction is the known answer: its id is a hash over exactly the
/// three parts the parser splits it into, so a misread length anywhere before
/// the prunable part changes the id.
void main() {
  test('reads a mainnet Bulletproofs+ transaction and computes its id', () {
    final tx = MoneroTx.parse(BytesUtils.fromHexString(_e89415));

    expect(
      BytesUtils.toHexString(tx.hash),
      'e89415b95564aa7e3587c91422756ba5303e727996e19c677630309a0d52a7ca',
    );
    expect(tx.unlockTime, BigInt.zero);
    expect(tx.inputs, hasLength(1));
    final ring = tx.inputs.single.ring;
    expect(ring, hasLength(16));
    expect(ring, orderedEquals([...ring.toSet()]..sort()), reason: 'absolute and ascending');
    expect(tx.inputs.single.keyImage, hasLength(32));
    expect(tx.outputs, hasLength(2));
    expect(tx.outputs.every((o) => o.viewTag != null), isTrue);
    expect(tx.rctType, MoneroTx.rctTypeBulletproofPlus);
    expect(tx.fee, greaterThan(BigInt.zero));
    expect(tx.encryptedAmounts, everyElement(hasLength(8)));
    expect(tx.commitments, everyElement(hasLength(32)));
    expect(tx.txPublicKey, hasLength(32));
    expect(tx.additionalPublicKeys, isEmpty);
  });

  test('rejects a transaction cut short before its prunable part', () {
    final blob = BytesUtils.fromHexString(_e89415);

    // This one's prefix is 202 bytes and its RingCT base 86 more.
    for (final length in [0, 1, 40, 201, 287]) {
      expect(() => MoneroTx.parse(blob.sublist(0, length)), throwsFormatException);
    }
  });

  group('amountPaidTo', () {
    final viewSecret = MoneroTestCrypto.randomScalar();
    final spendPublic = MoneroTestCrypto.randomPoint();
    final txSecret = MoneroTestCrypto.randomScalar();
    final amount = BigInt.from(123456789012);

    // Built the way a sender builds it: from the recipient's public view key
    // and the transaction secret. The recipient reaches the same derivation
    // from the transaction public key and their view secret.
    final derivation = MoneroTestCrypto.keyDerivation(
      MoneroTestCrypto.publicKey(viewSecret),
      txSecret,
    );
    final shared = MoneroTestCrypto.derivationToScalar(derivation, 0);
    final pad = MoneroTestCrypto.amountPad(shared);
    final encrypted = [
      for (final (i, b) in BigintUtils.toBytes(amount, length: 8, order: Endian.little).indexed)
        b ^ pad[i],
    ];
    final mask = MoneroTestCrypto.commitmentMask(shared);

    MoneroTx paying(BigInt committed) => MoneroTx.parse(
      _oneOutputTx(
        txPublicKey: MoneroTestCrypto.publicKey(txSecret),
        key: MoneroTestCrypto.derivePublicKey(derivation, 0, spendPublic),
        encryptedAmount: encrypted,
        commitment: MoneroTestCrypto.commit(committed, mask),
      ),
    );

    test('reads the amount an output pays its owner', () {
      expect(
        paying(amount).amountPaidTo(0, viewSecret: viewSecret, spendPublicKey: spendPublic),
        amount,
      );
    });

    test('finds nothing for another view key or another address', () {
      final tx = paying(amount);

      expect(
        tx.amountPaidTo(
          0,
          viewSecret: MoneroTestCrypto.randomScalar(),
          spendPublicKey: spendPublic,
        ),
        isNull,
      );
      expect(
        tx.amountPaidTo(0, viewSecret: viewSecret, spendPublicKey: MoneroTestCrypto.randomPoint()),
        isNull,
      );
    });

    test('refuses an output whose commitment is to another amount', () {
      final tx = paying(amount + BigInt.one);

      expect(
        () => tx.amountPaidTo(0, viewSecret: viewSecret, spendPublicKey: spendPublic),
        throwsStateError,
      );
    });
  });
}

/// A version-2 transaction with no inputs and one output, enough for
/// [MoneroTx.amountPaidTo].
List<int> _oneOutputTx({
  required List<int> txPublicKey,
  required List<int> key,
  required List<int> encryptedAmount,
  required List<int> commitment,
}) => [
  2, 0, // version, unlock time
  0, // inputs
  1, 0, 3, ...key, 0, // one output: amount, tagged key, view tag
  33, 1, ...txPublicKey, // extra: the transaction public key
  MoneroTx.rctTypeBulletproofPlus, 0, // RingCT type, fee
  ...encryptedAmount,
  ...commitment,
];

/// Mainnet transaction e89415b9… (block 2777777): one input with a ring of 16,
/// two outputs, Bulletproofs+. Monero's own test data,
/// `tests/data/txs/bpp_tx_e89415.bin` (1539 bytes, sha256 7226a844…6c69).
const _e89415 =
    '02000102001096a48a1ab1b9bd01d0ddae029feb1b91de319cb11dddd21be6ea28f2b107d661a0ab05abd104'
    'e294019653f709f48602af1f15c6fab3da19b3ef6ab0ceffe7cd19b19cd741eb0d4a1b695b37d9fb6ac20200'
    '03700516ab3178942b319e2e4e7985b3296b9393619905e37d616a819cca01e8b55200038d5b9072da48cbd4'
    '66bd3519fe92f92176f994dea73ac03762056ccae07806a5082c01ad7b21bd76c072b4d7af9ae8425374f19e'
    'f9bf28f800faf36e5e3c3a587a73420209019946ee952c1eb4ba0680b6b4f716920c12f293482b23ee59fdd8'
    '9b1a75670149d07055f4f8fcdde1c12896f8c0ee25c12fe389c3d4a4f40c6837163818c249b58fa1fc3331a7'
    '32e502e043e75a4106472192afcb4a6b7544dcc70e91418201acc177d2d2011289b6b310e259f4e0b2b68964'
    '86e6f15340bdb60b81e18156e4a74e96dd4675264177d1da677fcb9ecd152fbe48ba178c736cf4550ca55b58'
    '39e489a4bd317fedb66446191b00bb1785049c1352e1bce945d845f7aafb6373b45815a1ae2198b2feedda0d'
    '6e2de984079679c89eacc3306dd137f81a1db2250cc262357fef0fa6497c6611be391efa364f3b429d54b8e9'
    'd28ffe5563e05d8c01be256496cec8429aa02fc954cb68583a1d5cb5560070b4f66090de7640e0680c07c935'
    'fb1f1ff26337a5637578895549c4a10e09524004ff09bf39c04838ef517195537b44592f76abfcd8300b36a7'
    'a6f5e99288f55c9ac7d38c245f1de3774b399c1f7206f36904e23d5820e0b7155e04ba89dae2a62f7e3243bb'
    'abe425e78e1a488b529aac1eb37cbbb53afc54207e4861df0a9131bf73dd53a1ddb7ebc3f26ca5998d480804'
    '3f7e61185c607424d04529498fa8b8ca0f6082ccd84a9dd2940c45151d926ca16d7e26750d8af1cfeec5a166'
    '1b7d0b26ffdb106e35a687e9223acf072571b3d31a83cd6ead5c4baac0af1c5dde9820ba730a892868234b9e'
    'fa4a077cc27c6b34acae70e6a47d7fe1f869d1691a18476890af979d8095af286f5cd5d60e5c222686097cf3'
    '5086875d636c4df957854dd174ce1a17c3e0df3b48c9a14153573424d5b86c8477280ba7b2a25fc6ae929b30'
    '06ac6f2fab15a0b7ad5d0f3c98e27de967d8c3697487a6f6d68c1c40d1b83c7b39237ae94d237e47828e88b4'
    '9df7def2554eb8a44e9f3507f886d4b78c585313cef388b3676b1a8b736b49db114ad703493c47a7302188aa'
    'f677977d7e9449429e793677a1f8344042eb5e74b802d0528e5add817c132f63cde815c922aaed07c7f39583'
    'a302ef111b2988746fc3a12129f1dbff4e1f8cd869efa59750bfebd7558b0cc91cb410b2093e0cb7dc7b1089'
    'c31e93b7972c75283468f163292f01cf315a692de2f3dc014bf4090aa9fcdf024bd0dbe132be459e9ee685a6'
    '3f7cac13aa1032a1abfaa919a7380084a7f165401c3842074e6e6af8331313e078c3c7f45e3e719563e89f44'
    'f3550da4cdfd05af13ef2eea25e9650008a9cd53ba86a7dbddf4f85a106715e070aa0d8f28aea787dde78649'
    'bd6be31e07912ea9cbd3db97477d09289013815f4d890e667436176ad9592203621e39a45fac0a81d2b9856e'
    '2cf2769954c8c593900508465b9e2c814b6c57ddec35e378d33f06caebbdfd36fc0802b5246f85297ae8031d'
    'a24081543b1251f893e2587b1c90e43029e27c877a326f06ee5a06eb22e603e22b61f5da153ca733de95ea1d'
    '61cb7a79a00ceaea5e7cb555a5568e626aed0376efdc318a067a21ba4f45350fc18264c43c5dac4d0bf3fe81'
    '462fb65c7aff01008aa08a9fef54855a7ae4b1b595eb7d305c0e140052fc5ab9d9c13247f4620dbdabe63231'
    'd48abe2b00f746dfdeba2dffa7df9583ec389fb3589a1b1401390dd6366a8c23cc715a9792ce4391db9b0dcf'
    'fbb2c9f4339a204dc3cba9231abb0cf6c5564a5cc8bf98e7901e99022535944464ff805f7f38fe38eb15ef1b'
    'e1500d72e6df9fe591b45c326af5e646cb7ca3edc3ba6bd8852c26fd62435113e8c400ed68ec5a2b377d6f6e'
    '5f22a2cbafdf5053594d5e612db0c9dd7f648abb54ec02d25e883920b7951751f5712497c8fe6db6dad4b19d'
    '95d9ef632e25940c637d7eeb83fde4db28cfbb8ec0a785bcf6a7253099a7c9424161ae04c12f4bc2146408';
