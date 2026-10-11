import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_backup/wallet_backup.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'support/fake_wallet.dart';

const raven =
    'raven tail swear infant grief assist regular lamp duck valid someone little harsh puppy '
    'airport language';
const abandon =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const recipient =
    '49vDbkSo7eve3J41sBdjvjaBUyz8qHohsQcGtRf63qEUTMBvmA45fpp5pSacMdSg7A3b71RejLzB8EkGbfjp5PELVF2N4Zn';
final txid = 'ab' * 32;
final txKey = '11' * 32 + '22' * 32;

/// One device: its own local copy and address book, sharing [cloud] with the
/// others.
class Device {
  Device(
    this.root,
    this.cloud, {
    Duration delay = Duration.zero,
    List<BackupLocationConfig>? extra,
  }) {
    service = MetadataBackupService(
      localRoot: () async => Directory('${root.path}/local'),
      locations: [
        BackupLocationConfig(location: cloud, defaultEnabled: true, delayPayments: true),
        ...?extra,
      ],
      paymentUploadDelay: delay,
      observeLifecycle: false,
      readContacts: () async => contacts,
      applyContactChanges: (changes) async {
        contacts = applyContactChanges(contacts, changes);
      },
      clock: () => now,
    );
  }

  final Directory root;
  final MemoryLocation cloud;
  late final MetadataBackupService service;
  final wallet = FakeWallet('XMR', seedFormats: {SeedFormat.polyseed, SeedFormat.bip39});
  List<String> contacts = [];
  DateTime now = DateTime.utc(2026, 10, 10);

  List<Contact> get contactList => [
    for (final e in contacts) Contact.fromJson(json.decode(e) as Map<String, dynamic>),
  ];

  void setContacts(List<Contact> list) =>
      contacts = [for (final c in list) json.encode(c.toJson())];

  Future<void> open(SeedSource seed, {bool restored = false}) =>
      service.open(seed, wallets: [wallet], restored: restored);
}

void main() {
  late Directory tmp;
  late MemoryLocation cloud;

  setUp(() async {
    SharedPreferencesService.store = MemoryPreferenceStore();
    tmp = await Directory.systemTemp.createTemp('wallet_backup_test');
    WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
    cloud = MemoryLocation('icloud');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Device device(String name, {Duration delay = Duration.zero}) =>
      Device(Directory('${tmp.path}/$name'), cloud, delay: delay);

  test('a sent payment reaches the cloud and a restored device reads it back', () async {
    final a = device('a');
    await a.open(const PolyseedSeed(raven));
    a.service.outgoingPaymentSent(
      a.wallet,
      txid: txid,
      accountIndex: 0,
      fee: BigInt.from(61440000),
      recipients: [TxRecipient(recipient, BigInt.from(1234567890123))],
      txKey: txKey,
    );
    await a.service.idle();

    final folder = a.service.folderName!;
    expect(cloud.folders[folder], hasLength(1));
    final name = cloud.folders[folder]!.keys.single;
    expect(name, matches(RegExp(r'^[a-z2-7]{26}$')));
    expect(cloud.folders[folder]![name], hasLength(1024));

    final b = device('b');
    await b.open(const PolyseedSeed(raven), restored: true);
    final saved = b.service.outgoingPayment(b.wallet, txid)!;
    expect(saved.txKey, txKey);
    expect(saved.recipients.single.address, recipient);
    expect(saved.recipients.single.amountBaseUnits, BigInt.from(1234567890123));
    expect(b.service.lastRestoreReport!.payments, 1);
    expect(b.service.lastRestoreReport!.isClean, isTrue);
    expect(b.service.deviceIdHex, isNot(a.service.deviceIdHex));

    await a.service.close();
    await b.service.close();
  });

  test('a restored wallet history gets its destinations and key from the backup', () async {
    final a = device('a');
    await a.open(const PolyseedSeed(raven));
    a.service.outgoingPaymentSent(
      a.wallet,
      txid: txid,
      accountIndex: 0,
      fee: BigInt.one,
      recipients: [TxRecipient(recipient, BigInt.two)],
      txKey: txKey,
    );
    await a.service.idle();

    final b = device('b');
    MetadataBackup.instance = b.service;
    addTearDown(() => MetadataBackup.instance = null);
    await b.open(const PolyseedSeed(raven), restored: true);
    b.wallet.history = [
      TxDetails(
        index: 0,
        direction: txDirectionOutgoing,
        hash: txid,
        amountBaseUnits: BigInt.two,
        feeBaseUnits: BigInt.one,
        recipients: const [],
        accountIndex: 0,
        subaddrIndexList: const [],
        timestamp: 1,
        height: 10,
        confirmations: 20,
        key: '',
      ),
    ];
    await b.wallet.loadTxHistory();
    final tx = b.wallet.txHistory.single;
    expect(tx.key, txKey);
    expect(tx.recipients.single.address, recipient);

    await a.service.close();
    await b.service.close();
  });

  test('history scan records payments sent before the backup existed', () async {
    final a = device('a');
    a.wallet.history = [
      TxDetails(
        index: 0,
        direction: txDirectionOutgoing,
        hash: txid,
        amountBaseUnits: BigInt.two,
        feeBaseUnits: BigInt.one,
        recipients: [TxRecipient(recipient, BigInt.two)],
        accountIndex: 0,
        subaddrIndexList: const [],
        timestamp: 1,
        height: 10,
        confirmations: 20,
        key: txKey,
      ),
    ];
    await a.wallet.loadTxHistory();
    await a.open(const Bip39Seed(abandon));
    expect(a.service.paymentCount, 1);
    expect(a.service.unrecordedOutgoingCount, 0);
    await a.service.close();
  });

  test('address-book edits travel between devices, deletions included', () async {
    final a = device('a');
    a.setContacts([
      const Contact(id: 'legacy-1', name: 'Alice', addresses: {'XMR': recipient}),
    ]);
    await a.open(const PolyseedSeed(raven));

    final b = device('b');
    await b.open(const PolyseedSeed(raven), restored: true);
    expect(b.contactList.single.name, 'Alice');
    expect(b.service.lastRestoreReport!.contactsRestored, 1);

    // B renames Alice and adds Bob.
    final bob = Contact(id: newContactId(), name: 'Bob', addresses: const {'XMR': recipient});
    b.setContacts([b.contactList.single.copyWith(name: 'Alice B'), bob]);
    b.service.contactsChanged();
    await b.service.sync();

    await a.service.sync();
    expect(a.contactList.map((c) => c.name), ['Alice B', 'Bob']);

    // A deletes Bob; B follows.
    a.setContacts(a.contactList.where((c) => c.name != 'Bob').toList());
    await a.service.sync();
    await b.service.sync();
    expect(b.contactList.map((c) => c.name), ['Alice B']);

    // Nothing changed: a further sync writes nothing.
    final files = cloud.folders[a.service.folderName]!.length;
    await a.service.sync();
    await b.service.sync();
    expect(cloud.folders[a.service.folderName]!.length, files);

    await a.service.close();
    await b.service.close();
  });

  test('payment uploads to delayed locations wait, the local copy does not', () async {
    final a = device('a', delay: const Duration(minutes: 10));
    await a.open(const PolyseedSeed(raven));
    a.service.outgoingPaymentSent(
      a.wallet,
      txid: txid,
      accountIndex: 0,
      fee: BigInt.one,
      recipients: [TxRecipient(recipient, BigInt.two)],
      txKey: txKey,
    );
    await a.service.idle();
    expect(a.service.fileCount, 1);
    // The delay is random up to ten minutes; at most it has elapsed already
    // when it drew zero.
    final uploadedEarly = (cloud.folders[a.service.folderName] ?? const {}).length;
    a.now = a.now.add(const Duration(minutes: 11));
    await a.service.sync();
    expect(cloud.folders[a.service.folderName], hasLength(1));
    expect(uploadedEarly <= 1, isTrue);
    await a.service.close();
  });

  test('export and import move a backup without any shared location', () async {
    final a = device('a');
    a.setContacts([
      const Contact(id: 'c1', name: 'Carol', addresses: {'XMR': recipient}),
    ]);
    await a.open(const PolyseedSeed(raven));
    final bundle = await a.service.exportBundle();

    final lone = Device(Directory('${tmp.path}/lone'), MemoryLocation('elsewhere'));
    await lone.open(const PolyseedSeed(raven), restored: true);
    expect(lone.contactList, isEmpty);
    final result = await lone.service.importBundle(bundle);
    expect(result.added, 1);
    expect(lone.contactList.single.name, 'Carol');
    // Importing again adds nothing.
    expect((await lone.service.importBundle(bundle)).alreadyPresent, 1);

    final stranger = Device(Directory('${tmp.path}/stranger'), MemoryLocation('x'));
    await stranger.open(const Bip39Seed(abandon), restored: true);
    expect(() => stranger.service.importBundle(bundle), throwsFormatException);

    for (final d in [a, lone, stranger]) {
      await d.service.close();
    }
  });

  test('a different file under one of our names is never overwritten, and uploads go on', () async {
    final a = device('a');
    a.setContacts([const Contact(id: 'c1', name: 'One', addresses: {})]);
    await a.open(const PolyseedSeed(raven));
    final folder = a.service.folderName!;
    final taken = cloud.folders[folder]!.keys.single;
    cloud.folders[folder]![taken] = Uint8List(1024)..[0] = 1;

    // Lose the cloud's knowledge of nothing else; write a second change.
    a.setContacts([...a.contactList, const Contact(id: 'c2', name: 'Two', addresses: {})]);
    await a.service.sync();
    expect(cloud.folders[folder], hasLength(2));
    expect(cloud.folders[folder]![taken]![0], 1);
    await a.service.close();
  });

  test('25-word seeds have no backup', () async {
    final a = device('a');
    await a.open(MoneroLegacySeed(List.filled(25, 'abbey').join(' ')));
    expect(a.service.availability, BackupAvailability.legacySeed);
    expect(a.service.isOpen, isFalse);
  });

  test('a file that does not open is reported once and never deleted', () async {
    final a = device('a');
    await a.open(const PolyseedSeed(raven));
    final folder = a.service.folderName!;
    cloud.folders[folder] = {'aaaaaaaaaaaaaaaaaaaaaaaaaa': Uint8List(1024)};
    await a.service.sync();
    await a.service.sync();
    expect(a.service.failedFiles, hasLength(1));
    expect(a.service.failedFiles.single.reason, 'unknownVersion');
    expect(cloud.folders[folder]!.containsKey('aaaaaaaaaaaaaaaaaaaaaaaaaa'), isTrue);
    await a.service.close();
  });

  test('an instance writing as this device forces a new device id', () async {
    final a = device('a');
    a.setContacts([const Contact(id: 'c1', name: 'One', addresses: {})]);
    await a.open(const PolyseedSeed(raven));
    await a.service.close();

    // Clone A's local copy and state, as a phone backup restored elsewhere
    // would.
    final clone = device('clone');
    await _copyDir(Directory('${tmp.path}/a'), Directory('${tmp.path}/clone'));
    clone.contacts = List.of(a.contacts);

    // A writes again under its id.
    await a.open(const PolyseedSeed(raven));
    a.setContacts([...a.contactList, const Contact(id: 'c2', name: 'Two', addresses: {})]);
    await a.service.sync();

    await clone.open(const PolyseedSeed(raven));
    expect(clone.service.deviceIdHex, isNot(a.service.deviceIdHex));
    expect(clone.contactList.map((c) => c.name), ['One', 'Two']);
    await a.service.close();
    await clone.service.close();
  });

  test('turning off an on-device location deletes its copy', () async {
    final auto = FolderLocation('auto', () async => Directory('${tmp.path}/auto'));
    final a = Device(
      Directory('${tmp.path}/a'),
      cloud,
      extra: [BackupLocationConfig(location: auto, defaultEnabled: true, onDevice: true)],
    );
    a.setContacts([const Contact(id: 'c1', name: 'One', addresses: {})]);
    await a.open(const PolyseedSeed(raven));
    expect(await auto.list(a.service.folderName!), hasLength(1));
    await a.service.setLocationEnabled('auto', false);
    expect(await auto.list(a.service.folderName!), isEmpty);
    await a.service.deleteLocal();
    expect(await Directory('${tmp.path}/a/local').exists(), isFalse);
    // The cloud copy is untouched by a wallet delete.
    expect(cloud.folders.values.single, hasLength(1));
  });
}

Future<void> _copyDir(Directory from, Directory to) async {
  await for (final e in from.list(recursive: true)) {
    final rel = e.path.substring(from.path.length);
    if (e is Directory) {
      await Directory('${to.path}$rel').create(recursive: true);
    } else if (e is File) {
      await File('${to.path}$rel').parent.create(recursive: true);
      await e.copy('${to.path}$rel');
    }
  }
}
