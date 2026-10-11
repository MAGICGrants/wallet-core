import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_backup/src/cbor.dart';
import 'package:wallet_backup/src/crypto.dart';
import 'package:wallet_backup/wallet_backup.dart';

BackupKeys testKeys([int fill = 7]) =>
    BackupKeys.fromMetadataRoot(Uint8List(32)..fillRange(0, 32, fill));

BackupFileBody body({List<BackupRecord> records = const [], int seq = 1, Uint8List? device}) =>
    BackupFileBody(
      deviceId: device ?? Uint8List(16)
        ..fillRange(0, 16, 0xaa),
      seq: seq,
      kind: FileKind.change,
      lamport: 3,
      created: 1791000000,
      seen: {toHex(Uint8List(16)..fillRange(0, 16, 0xbb)): 9},
      records: records,
    );

ContactRecord contact(String id, String name, int lamport, {int device = 1}) => ContactRecord(
  id: id,
  name: name,
  addresses: {'XMR': '4Addr$name'},
  lamport: lamport,
  deviceId: Uint8List(16)..fillRange(0, 16, device),
);

/// Seals [plaintext] by hand, to build files a writer would never produce.
Uint8List sealRaw(BackupKeys keys, Uint8List plaintext, {int version = 1}) {
  final header = Uint8List.fromList([version, 0, 0]);
  final nonce = Uint8List(24);
  final sealed = XChaCha20Poly1305.seal(keys.encryptionKey(0), nonce, header, plaintext);
  return Uint8List.fromList([...header, ...nonce, ...sealed]);
}

Uint8List plaintextFor(Uint8List encodedBody, int total) {
  final p = Uint8List(total - 43);
  ByteData.sublistView(p).setUint32(0, encodedBody.length, Endian.big);
  p.setRange(4, 4 + encodedBody.length, encodedBody);
  return p;
}

void main() {
  group('CBOR', () {
    test('round-trips the value types the format uses', () {
      final value = <Object, Object?>{
        0: 1,
        1: Uint8List.fromList([1, 2, 3]),
        2: 'text',
        3: [1, -1, true, false, null],
        4: BigInt.parse('18446744073709551615'),
        5: -9223372036854775808,
        'a': {'b': 1},
      };
      final encoded = cborEncode(value);
      cborCheckCanonical(encoded);
      final decoded = cborDecode(encoded) as Map;
      expect(decoded[4], BigInt.parse('18446744073709551615'));
      expect(decoded[5], -9223372036854775808);
      expect(cborEncode(decoded), encoded);
    });

    test('sorts map keys by their encoding', () {
      expect(toHex(cborEncode({10: 0, 1: 0, 'a': 0, 100: 0})), 'a401000a00186400616100');
      expect(toHex(cborEncode({'bb': 0, 'a': 0})), 'a261610062626200');
    });

    final rejects = {
      'non-shortest int': '1801',
      'non-shortest length': '5801ff',
      'unsorted keys': 'a2020001 00'.replaceAll(' ', ''),
      'duplicate keys': 'a201000100',
      'float': 'f93c00',
      'tag': 'c101',
      'indefinite array': '9f01ff',
      'undefined': 'f7',
      'trailing bytes': '0101',
      'bad utf-8': '61ff',
      'truncated': '5a000000ff00',
    };
    for (final e in rejects.entries) {
      test('rejects ${e.key}', () {
        expect(() => cborCheckCanonical(fromHex(e.value)), throwsA(isA<CborFormatException>()));
      });
    }
  });

  group('padding', () {
    test('PADMÉ matches the plan’s reference values', () {
      const expected = {
        1: 1,
        47: 48,
        1023: 1024,
        1024: 1024,
        1025: 1088,
        1071: 1088,
        2000: 2048,
        4097: 4352,
        10000: 10240,
        33000: 34816,
        65000: 65536,
        65536: 65536,
      };
      for (final e in expected.entries) {
        expect(padme(e.key), e.value, reason: '${e.key}');
      }
    });

    test('every file is at least 1 KiB', () {
      expect(paddedFileSize(48), 1024);
      expect(paddedFileSize(1025), 1088);
    });
  });

  group('file', () {
    test('seals and opens; common changes are all 1,024 bytes', () {
      final keys = testKeys();
      final payment = OutgoingPaymentRecord(
        txid: Uint8List(32)..fillRange(0, 32, 1),
        account: 0,
        fee: BigInt.from(61440000),
        destinations: [
          for (var i = 0; i < 7; i++)
            PaymentDestination(
              kind: 0,
              spendPublicKey: Uint8List(32),
              viewPublicKey: Uint8List(32),
              amount: BigInt.from(1234567890123),
              txKey: Uint8List(32),
            ),
        ],
      );
      for (final records in [
        <BackupRecord>[payment],
        <BackupRecord>[contact('00112233445566778899aabbccddeeff', 'Alice', 4)],
      ]) {
        final file = sealBackupFile(keys, body(records: records));
        expect(file.length, 1024);
        expect(file[0], 1);
        final opened = openBackupFile(keys, file);
        expect(opened.seq, 1);
        expect(opened.records.single.raw, records.single.raw);
      }
    });

    test('nothing but the version and epoch is visible', () {
      final keys = testKeys();
      final a = sealBackupFile(keys, body());
      final b = sealBackupFile(keys, body());
      expect(a.sublist(0, 3), [1, 0, 0]);
      // Fresh nonce each time: the rest differs entirely.
      expect(toHex(a.sublist(3)) == toHex(b.sublist(3)), isFalse);
    });

    test('a different seed cannot open it', () {
      final file = sealBackupFile(testKeys(1), body());
      expect(
        () => openBackupFile(testKeys(2), file),
        throwsA(
          isA<BackupFileException>().having((e) => e.error, 'error', BackupFileError.sealFailed),
        ),
      );
    });

    test('rejects an unknown version or epoch without trying to open', () {
      final keys = testKeys();
      final file = sealBackupFile(keys, body());
      final v2 = Uint8List.fromList(file)..[0] = 2;
      final e1 = Uint8List.fromList(file)..[2] = 1;
      expect(
        () => openBackupFile(keys, v2),
        throwsA(
          isA<BackupFileException>().having((e) => e.error, 'e', BackupFileError.unknownVersion),
        ),
      );
      expect(
        () => openBackupFile(keys, e1),
        throwsA(
          isA<BackupFileException>().having((e) => e.error, 'e', BackupFileError.unknownEpoch),
        ),
      );
    });

    test('the header is authenticated', () {
      final keys = testKeys();
      final file = sealBackupFile(keys, body());
      // Still version 1 and epoch 0 after the flip is impossible, so flip a
      // nonce byte instead, and a ciphertext byte.
      for (final i in [5, 500]) {
        final bad = Uint8List.fromList(file)..[i] ^= 0x10;
        expect(
          () => openBackupFile(keys, bad),
          throwsA(
            isA<BackupFileException>().having((e) => e.error, 'e', BackupFileError.sealFailed),
          ),
        );
      }
    });

    test('rejects non-zero padding', () {
      final keys = testKeys();
      final encoded = body().encode();
      final p = plaintextFor(encoded, 1024);
      p[p.length - 1] = 1;
      expect(
        () => openBackupFile(keys, sealRaw(keys, p)),
        throwsA(isA<BackupFileException>().having((e) => e.error, 'e', BackupFileError.badPadding)),
      );
      // The same with zero padding opens.
      expect(openBackupFile(keys, sealRaw(keys, plaintextFor(encoded, 1024))).seq, 1);
    });

    test('rejects a body that is not canonical CBOR', () {
      final keys = testKeys();
      final encoded = body().encode();
      // Re-encode the seq (key 1, value 1) with a one-byte argument: 18 01.
      final idx = encoded.indexOf(0x01, 1);
      final tampered = Uint8List.fromList([
        ...encoded.sublist(0, idx + 1),
        0x18,
        0x01,
        ...encoded.sublist(idx + 2),
      ]);
      expect(
        () => openBackupFile(keys, sealRaw(keys, plaintextFor(tampered, 1024))),
        throwsA(
          isA<BackupFileException>().having((e) => e.error, 'e', BackupFileError.notCanonical),
        ),
      );
    });

    test('the transaction key is stored once per destination', () {
      final r = Uint8List(32)..fillRange(0, 32, 0x11);
      final extra = Uint8List(32)..fillRange(0, 32, 0x22);
      PaymentDestination dest(int b) => PaymentDestination(
        kind: 1,
        spendPublicKey: Uint8List(32)..fillRange(0, 32, b),
        viewPublicKey: Uint8List(32),
        amount: BigInt.from(b),
        txKey: r,
        additionalTxKeys: [extra],
      );
      final record = OutgoingPaymentRecord(
        txid: Uint8List(32),
        account: 0,
        fee: BigInt.one,
        destinations: [dest(1), dest(2)],
      );
      final decoded = cborDecode(record.raw) as Map;
      expect(decoded.keys.toSet(), {0, 1, 2, 3, 4}, reason: 'no record-level key');
      for (final d in decoded[4] as List) {
        expect((d as Map)[4], r);
        expect(d[5], [extra]);
      }
      final parsed = BackupRecord.parse(record.raw) as OutgoingPaymentRecord;
      expect(parsed.destinations.map((d) => d.txKeyHex), [
        '11' * 32 + '22' * 32,
        '11' * 32 + '22' * 32,
      ]);
      expect(parsed.txKeyHex, '11' * 32 + '22' * 32);
    });

    test('keeps unknown record types byte for byte', () {
      final keys = testKeys();
      final unknownRaw = cborEncode({
        0: 42,
        1: 'from the future',
        99: [1, 2],
      });
      final file = sealBackupFile(keys, body(records: [UnknownRecord(unknownRaw, 42)]));
      final opened = openBackupFile(keys, file);
      expect(opened.records.single, isA<UnknownRecord>());
      expect(opened.records.single.raw, unknownRaw);
    });

    test('a snapshot chunk is exactly 64 KiB', () {
      final keys = testKeys();
      final chunk = BackupFileBody(
        deviceId: Uint8List(16),
        seq: 1,
        kind: FileKind.snapshotChunk,
        lamport: 1,
        created: 0,
        seen: const {},
        records: const [],
        snapshotId: Uint8List(16)..fillRange(0, 16, 3),
        chunkIndex: 0,
        chunkCount: 1,
        covers: {toHex(Uint8List(16)): 4},
      );
      final file = sealBackupFile(keys, chunk);
      expect(file.length, 65536);
      final opened = openBackupFile(keys, file);
      expect(BackupNames.plainNameOf(opened), startsWith('s-03030303'));
      expect(opened.covers, {toHex(Uint8List(16)): 4});
    });
  });

  group('names', () {
    test('plain names', () {
      final device = Uint8List(16)..fillRange(0, 16, 0xab);
      expect(BackupNames.change(device, 255), 'c-${'ab' * 16}-00000000000000ff');
      expect(BackupNames.isPlainName(BackupNames.change(device, 1)), isTrue);
    });

    test('hashed names are 26 lowercase base32 characters, per seed', () {
      final a = testKeys(1);
      final b = testKeys(2);
      final name = BackupNames.change(Uint8List(16), 1);
      expect(BackupNames.hashed(a, name), matches(RegExp(r'^[a-z2-7]{26}$')));
      expect(BackupNames.folder(a), matches(RegExp(r'^[a-z2-7]{26}$')));
      expect(BackupNames.hashed(a, name), isNot(BackupNames.hashed(b, name)));
      expect(BackupNames.folder(a), isNot(BackupNames.folder(b)));
    });

    test('base32 is RFC 4648 lowercase without padding', () {
      expect(base32(Uint8List.fromList('foobar'.codeUnits)), 'mzxw6ytboi');
    });
  });

  group('bundle', () {
    test('round-trips and rejects junk', () {
      final files = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4]),
      ];
      final bundle = BackupBundle.encode(files);
      expect(BackupBundle.decode(bundle).map(toHex).toSet(), {'010203', '04'});
      expect(() => BackupBundle.decode(Uint8List.fromList([0, 0, 0, 9, 1])), throwsFormatException);
      expect(() => BackupBundle.decode(Uint8List.fromList([0, 0])), throwsFormatException);
    });
  });

  group('Monero addresses', () {
    const ledger =
        '49vDbkSo7eve3J41sBdjvjaBUyz8qHohsQcGtRf63qEUTMBvmA45fpp5pSacMdSg7A3b71RejLzB8EkGbfjp5PELVF2N4Zn';

    test('decodes and re-encodes a mainnet address', () {
      final a = MoneroAddress.tryParse(ledger)!;
      expect(a.network, MoneroNetwork.mainnet);
      expect(a.kind, MoneroAddressKind.standard);
      expect(a.encode(), ledger);
    });

    test('rejects a bad checksum', () {
      final bad =
          '${ledger.substring(0, 90)}${ledger[90] == 'a' ? 'b' : 'a'}${ledger.substring(91)}';
      expect(MoneroAddress.tryParse(bad), isNull);
      expect(MoneroAddress.tryParse('not an address'), isNull);
    });

    test('integrated addresses keep their payment id', () {
      final base = MoneroAddress.tryParse(ledger)!;
      final integrated = MoneroAddress(
        network: MoneroNetwork.mainnet,
        kind: MoneroAddressKind.integrated,
        spendPublicKey: base.spendPublicKey,
        viewPublicKey: base.viewPublicKey,
        paymentId: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]),
      ).encode();
      expect(integrated, hasLength(106));
      expect(integrated, startsWith('4'));
      final back = MoneroAddress.tryParse(integrated)!;
      expect(back.kind, MoneroAddressKind.integrated);
      expect(back.paymentId, [1, 2, 3, 4, 5, 6, 7, 8]);
    });
  });
}
