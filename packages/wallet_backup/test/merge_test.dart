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

  test('address labels: one per (coin, address), last writer wins, removals too', () {
    AddressLabelRecord l(String address, String label, int lamport, int device) =>
        AddressLabelRecord(
          coin: 'xmr',
          address: address,
          label: label,
          lamport: lamport,
          deviceId: dev(device),
        );
    final s = BackupState()
      ..add('a1', file(1, 1, [l('8one', 'Rent', 1, 1), l('8two', 'Tips', 1, 1)]))
      ..add('b1', file(2, 1, [l('8one', 'Rent B', 1, 2)]))
      ..add(
        'a2',
        file(1, 2, [
          AddressLabelRecord.deletion(coin: 'XMR', address: '8two', lamport: 2, deviceId: dev(1)),
        ]),
      );
    // Same lamport: device 2 is higher. The coin is upper-cased into the key.
    expect(s.labelVersions['XMR:8one']!.label, 'Rent B');
    expect(s.labelVersions['XMR:8two']!.deleted, isTrue);
    expect(s.labels.map((v) => v.key), ['XMR:8one']);
    expect(s.maxLamport, 2);

    // A record reads back as what was written.
    final parsed = BackupRecord.parse(l('8one', 'Rent', 7, 3).raw) as AddressLabelRecord;
    expect((parsed.coin, parsed.address, parsed.label, parsed.lamport), ('XMR', '8one', 'Rent', 7));
    expect(parsed.type, RecordType.addressLabel);
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
