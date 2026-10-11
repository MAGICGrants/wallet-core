import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_backup/src/crypto.dart';
import 'package:wallet_backup/wallet_backup.dart';

Uint8List dev(int b) => Uint8List(16)..fillRange(0, 16, b);

BackupFileBody file(int device, int seq, List<BackupRecord> records, {Map<String, int>? seen}) =>
    BackupFileBody(
      deviceId: dev(device),
      seq: seq,
      kind: FileKind.change,
      lamport: seq,
      created: 0,
      seen: seen ?? const {},
      records: records,
    );

ContactRecord c(String id, String name, int lamport, int device) => ContactRecord(
  id: id,
  name: name,
  addresses: {'XMR': 'a$name'},
  lamport: lamport,
  deviceId: dev(device),
);

OutgoingPaymentRecord pay(int b, {bool key = true}) => OutgoingPaymentRecord(
  txid: Uint8List(32)..fillRange(0, 32, b),
  account: 0,
  fee: BigInt.one,
  destinations: [
    PaymentDestination(
      kind: 0,
      spendPublicKey: Uint8List(32),
      viewPublicKey: Uint8List(32),
      amount: BigInt.one,
      txKey: key ? Uint8List(32) : null,
    ),
  ],
);

String fingerprint(BackupState s) {
  final contacts = s.contactVersions.values.map((v) => '${v.id}:${v.name}:${v.deleted}').toList()
    ..sort();
  final payments = s.payments.map((p) => toHex(p.raw)).toList()..sort();
  return '$contacts|$payments|${s.gaps}|${s.missingTails}|${s.maxLamport}';
}

void main() {
  final files = <(String, BackupFileBody)>[
    ('a1', file(1, 1, [c('x', 'one', 1, 1), pay(1)])),
    ('a2', file(1, 2, [c('x', 'two', 2, 1)])),
    ('b1', file(2, 1, [c('x', 'other', 2, 2), c('y', 'why', 2, 2)])),
    ('b2', file(2, 2, [ContactRecord.deletion(id: 'y', lamport: 3, deviceId: dev(2)), pay(1)])),
    ('b4', file(2, 4, [pay(2, key: false), pay(2)], seen: {toHex(dev(1)): 5})),
  ];

  test('merging is order-independent and repeatable', () {
    final reference = BackupState();
    for (final (n, f) in files) {
      reference.add(n, f);
    }
    final rng = Random(1);
    for (var round = 0; round < 50; round++) {
      final shuffled = List.of(files)..shuffle(rng);
      final s = BackupState();
      for (final (n, f) in [...shuffled, ...shuffled.take(2)]) {
        s.add(n, f);
      }
      expect(fingerprint(s), fingerprint(reference));
    }
  });

  test('last writer wins on (lamport, device id); deletions win too', () {
    final s = BackupState();
    for (final (n, f) in files) {
      s.add(n, f);
    }
    // x: lamport 2 from device 1 and device 2 tie on lamport; device 2 is higher.
    expect(s.contactVersions['x']!.name, 'other');
    expect(s.contactVersions['y']!.deleted, isTrue);
    expect(s.contacts.map((v) => v.id), ['x']);
  });

  test('payments: identical copies collapse, differing ones are reported', () {
    final s = BackupState();
    for (final (n, f) in files) {
      s.add(n, f);
    }
    expect(s.paymentCount, 2);
    expect(s.conflictingPayments, [toHex(Uint8List(32)..fillRange(0, 32, 2))]);
    // The copy with a key is the one reported.
    expect(s.payment(toHex(Uint8List(32)..fillRange(0, 32, 2)))!.hasTxKey, isTrue);
  });

  test('gaps and devices seen further than their files reach', () {
    final s = BackupState();
    for (final (n, f) in files) {
      s.add(n, f);
    }
    expect(s.gaps, {
      toHex(dev(2)): [3],
    });
    expect(s.missingTails, {toHex(dev(1)): 3});
  });
}
