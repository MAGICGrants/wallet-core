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
        BackupLocationConfig(location: cloud, delayPayments: true),
        ...?extra,
      ],
      paymentUploadDelay: delay,
      watchDelay: Duration.zero,
      observeLifecycle: false,
      readContacts: () async => contacts,
      applyContactChanges: (changes) async {
        if (contactWritesFail) throw const FileSystemException('keystore unavailable');
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

  /// The address book cannot be written: changes from the backup are refused.
  bool contactWritesFail = false;

  List<Contact> get contactList => [
    for (final e in contacts) Contact.fromJson(json.decode(e) as Map<String, dynamic>),
  ];

  void setContacts(List<Contact> list) =>
      contacts = [for (final c in list) json.encode(c.toJson())];

  Future<void> open(SeedSource seed, {bool restored = false}) =>
      service.open(seed, wallets: [wallet], restored: restored);
}

/// iCloud as it can be: holding files it has not uploaded yet.
class UploadingLocation extends MemoryLocation {
  UploadingLocation(super.id);

  bool uploading = true;

  @override
  Future<bool?> isUploaded(String folder, String name) async => !uploading;
}

/// A location whose files can fail to read: [failing] as a passing error (a
/// download that timed out), [tooLarge] as no backup file can be.
class FlakyLocation extends MemoryLocation {
  FlakyLocation(super.id);

  final Set<String> failing = {};
  final Set<String> tooLarge = {};

  @override
  Future<Uint8List?> read(String folder, String name) async {
    if (tooLarge.contains(name)) throw BackupFileTooLarge(name);
    if (failing.contains(name)) throw const SocketException('iCloud did not answer in time');
    return super.read(folder, name);
  }
}

/// The backup and these locations turned on, as a user who opted in has them.
Future<void> turnOn(Iterable<String> locations) async {
  await SharedPreferencesService.set<bool>(MetadataBackupService.enabledPrefKey, true);
  for (final id in locations) {
    await SharedPreferencesService.set<bool>(MetadataBackupService.enabledKey(id), true);
  }
}

TxDetails sentTx() => TxDetails(
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
);

void main() {
  late Directory tmp;
  late MemoryLocation cloud;

  // Most tests run with the backup on (it is opt-in); the 'opt-in' group
  // starts from the default instead.
  setUp(() async {
    SharedPreferencesService.store = MemoryPreferenceStore();
    await turnOn(['icloud', 'elsewhere', 'x', 'auto']);
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

  test('a file not uploaded yet is not "up to date" after a restart', () async {
    final icloud = UploadingLocation('icloud');
    final first = Device(Directory('${tmp.path}/a'), icloud)
      ..setContacts([
        const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
      ]);
    await first.open(const PolyseedSeed(raven));
    expect(first.service.statusOf('icloud').awaitingConfirmation, greaterThan(0));
    await first.service.close();

    // The app restarts before iCloud has uploaded anything.
    final again = Device(Directory('${tmp.path}/a'), icloud)..contacts = first.contacts;
    await again.open(const PolyseedSeed(raven));
    expect(again.service.statusOf('icloud').awaitingConfirmation, greaterThan(0));

    icloud.uploading = false;
    await again.service.sync();
    expect(again.service.statusOf('icloud').awaitingConfirmation, 0);
    await again.service.close();
  });

  group('a file that cannot be read', () {
    Future<(Device, FlakyLocation)> restoredWith(Device a) async {
      final flaky = FlakyLocation('icloud')..folders.addAll(cloud.folders);
      final b = Device(Directory('${tmp.path}/b'), flaky);
      return (b, flaky);
    }

    test('one that times out is skipped, shown, and read at the next sync', () async {
      final a = device('a')
        ..setContacts([
          const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
        ]);
      await a.open(const PolyseedSeed(raven));
      final (b, flaky) = await restoredWith(a);
      flaky.failing.addAll(cloud.folders[a.service.folderName]!.keys);

      await b.open(const PolyseedSeed(raven), restored: true);
      expect(b.service.statusOf('icloud').lastError, contains('could not be read'));
      expect(b.contactList, isEmpty, reason: 'no join against a location not read in full');

      flaky.failing.clear();
      await b.service.sync();
      expect(b.service.statusOf('icloud').lastError, isNull);
      expect(b.contactList.map((c) => c.name), ['Alice']);
      await a.service.close();
      await b.service.close();
    });

    test('one too large is rejected, and the rest are read', () async {
      final a = device('a')
        ..setContacts([
          const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
        ]);
      await a.open(const PolyseedSeed(raven));
      final (b, flaky) = await restoredWith(a);
      final hostile = 'b' * 26; // shaped like one of ours
      flaky.folders[a.service.folderName]![hostile] = Uint8List(8);
      flaky.tooLarge.add(hostile);

      await b.open(const PolyseedSeed(raven), restored: true);
      expect(b.contactList.map((c) => c.name), ['Alice']);
      expect(b.service.failedFiles.map((f) => f.reason), contains('too large'));
      expect(b.service.statusOf('icloud').lastError, isNull);
      await a.service.close();
      await b.service.close();
    });
  });

  group('a sync folder', () {
    /// A device whose only location is a folder that a sync app fills.
    Device withFolder(String name, MemoryLocation folder) => Device(
      Directory('${tmp.path}/$name'),
      MemoryLocation('unused'),
      extra: [BackupLocationConfig(location: folder, retryUnreadable: true)],
    );

    test('a file still arriving is read again at the next sync, then merged', () async {
      final a = device('a')
        ..setContacts([
          const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
        ]);
      await a.open(const PolyseedSeed(raven));
      final folder = a.service.folderName!;
      final (name, bytes) = cloud.folders[folder]!.entries.map((e) => (e.key, e.value)).single;

      // The sync app has made the file but not filled it yet.
      final synced = MemoryLocation('elsewhere')..folders[folder] = {name: Uint8List(0)};
      final b = withFolder('b', synced);
      await b.open(const PolyseedSeed(raven), restored: true);
      expect(b.service.failedFiles, hasLength(1));
      expect(b.contactList, isEmpty);

      synced.folders[folder]![name] = bytes;
      await b.service.sync();
      expect(b.contactList.map((c) => c.name), ['Alice']);
      expect(b.service.failedFiles, isEmpty, reason: 'it opened after all');
      await a.service.close();
      await b.service.close();
    });

    test('elsewhere, a file that fails to open stays set aside until the next unlock', () async {
      final a = device('a')
        ..setContacts([
          const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
        ]);
      await a.open(const PolyseedSeed(raven));
      final folder = a.service.folderName!;
      final (name, bytes) = cloud.folders[folder]!.entries.map((e) => (e.key, e.value)).single;

      final other = MemoryLocation('icloud')..folders[folder] = {name: Uint8List(0)};
      final b = Device(Directory('${tmp.path}/b'), other);
      await b.open(const PolyseedSeed(raven), restored: true);
      other.folders[folder]![name] = bytes;
      await b.service.sync();
      expect(b.contactList, isEmpty);
      await a.service.close();
      await b.service.close();
    });

    test('a change there starts a sync without waiting for the timer', () async {
      final synced = MemoryLocation('elsewhere');
      final b = Device(
        Directory('${tmp.path}/b'),
        MemoryLocation('unused'),
        extra: [BackupLocationConfig(location: synced, retryUnreadable: true)],
      );
      await b.open(const PolyseedSeed(raven));
      final folder = b.service.folderName!;
      expect(synced.changes.hasListener, isTrue, reason: 'watched once on');

      final a = device('a')
        ..setContacts([
          const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
        ]);
      await a.open(const PolyseedSeed(raven));
      (synced.folders[folder] ??= {}).addAll(cloud.folders[folder]!);
      expect(b.contactList, isEmpty, reason: 'not read until something says so');
      synced.changes.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await b.service.idle();
      expect(b.contactList.map((c) => c.name), ['Alice']);

      await b.service.setLocationEnabled('elsewhere', false);
      expect(synced.changes.hasListener, isFalse, reason: 'not watched once off');
      await a.service.close();
      await b.service.close();
    });

    test('another folder chosen: what failed at the old one is read again', () async {
      final a = device('a')
        ..setContacts([
          const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
        ]);
      await a.open(const PolyseedSeed(raven));
      final folder = a.service.folderName!;
      final (name, bytes) = cloud.folders[folder]!.entries.map((e) => (e.key, e.value)).single;

      // Set aside at the first place (no retry there)...
      final place = MemoryLocation('elsewhere')..folders[folder] = {name: Uint8List(0)};
      final b = Device(
        Directory('${tmp.path}/b'),
        MemoryLocation('unused'),
        extra: [BackupLocationConfig(location: place)],
      );
      await b.open(const PolyseedSeed(raven), restored: true);
      expect(b.contactList, isEmpty);

      // ...then the user chooses another folder, where the file is whole.
      place.folders[folder] = {name: bytes};
      await b.service.locationChanged('elsewhere');
      await b.service.idle();
      expect(b.contactList.map((c) => c.name), ['Alice']);
      expect(b.service.failedFiles, isEmpty);
      await a.service.close();
      await b.service.close();
    });
  });

  // A change from the backup that this device could not store must not count
  // as stored: it would then read as deleted or edited here, and travel back.
  group('when the address book cannot be written', () {
    test('a contact added elsewhere arrives later, and is not deleted', () async {
      final a = device('a');
      a.setContacts([
        const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
      ]);
      await a.open(const PolyseedSeed(raven));
      final b = device('b');
      await b.open(const PolyseedSeed(raven), restored: true);

      final bob = Contact(id: newContactId(), name: 'Bob', addresses: const {'XMR': recipient});
      a.setContacts([...a.contactList, bob]);
      a.service.contactsChanged();
      await a.service.sync();

      b.contactWritesFail = true;
      await b.service.sync();
      expect(b.contactList.map((c) => c.name), ['Alice']);

      b.contactWritesFail = false;
      await b.service.sync();
      expect(b.contactList.map((c) => c.name), ['Alice', 'Bob']);
      await a.service.sync();
      expect(a.contactList.map((c) => c.name), ['Alice', 'Bob']);

      await a.service.close();
      await b.service.close();
    });

    test('a contact edited elsewhere arrives later, and is not undone', () async {
      final a = device('a');
      a.setContacts([
        const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
      ]);
      await a.open(const PolyseedSeed(raven));
      final b = device('b');
      await b.open(const PolyseedSeed(raven), restored: true);

      a.setContacts([a.contactList.single.copyWith(name: 'Alice A')]);
      a.service.contactsChanged();
      await a.service.sync();

      b.contactWritesFail = true;
      await b.service.sync();
      expect(b.contactList.single.name, 'Alice');

      b.contactWritesFail = false;
      await b.service.sync();
      expect(b.contactList.single.name, 'Alice A');
      await a.service.sync();
      expect(a.contactList.single.name, 'Alice A');

      await a.service.close();
      await b.service.close();
    });

    test('a restore that could not write the address book deletes nothing', () async {
      final a = device('a');
      a.setContacts([
        const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
      ]);
      await a.open(const PolyseedSeed(raven));

      final b = device('b')..contactWritesFail = true;
      await b.open(const PolyseedSeed(raven), restored: true);
      expect(b.contactList, isEmpty);
      expect(b.service.lastRestoreReport!.contactsRestored, 0);

      b.contactWritesFail = false;
      await b.service.sync();
      expect(b.contactList.map((c) => c.name), ['Alice']);
      await a.service.sync();
      expect(a.contactList.map((c) => c.name), ['Alice']);

      await a.service.close();
      await b.service.close();
    });
  });

  // Only changes made while syncing travel: a device that was off (or is
  // restored) takes the backup's version of every contact the backup knows and
  // adds only the ones it has never seen.
  test('a device that was off rejoins: synced changes win, its new contacts are added', () async {
    Set<String> names(Device d) => {for (final c in d.contactList) c.name};
    final a = device('a');
    a.setContacts([
      const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
      const Contact(id: 'bob', name: 'Bob', addresses: {'XMR': recipient}),
      const Contact(id: 'carol', name: 'Carol', addresses: {'XMR': recipient}),
    ]);
    await a.open(const PolyseedSeed(raven));
    final b = device('b');
    await b.open(const PolyseedSeed(raven), restored: true);
    expect(names(b), {'Alice', 'Bob', 'Carol'});

    // B turns the backup off. A keeps syncing: deletes Alice, renames Bob.
    await b.service.setEnabled(false);
    a.setContacts([
      const Contact(id: 'bob', name: 'Bob A', addresses: {'XMR': recipient}),
      const Contact(id: 'carol', name: 'Carol', addresses: {'XMR': recipient}),
    ]);
    await a.service.sync();

    // Meanwhile B, off: deletes Carol, renames Bob its own way, adds Dave.
    b.setContacts([
      const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
      const Contact(id: 'bob', name: 'Bob B', addresses: {'XMR': recipient}),
      const Contact(id: 'dave', name: 'Dave', addresses: {'XMR': recipient}),
    ]);

    await b.service.setEnabled(true, locations: ['icloud']);
    await b.service.idle();
    // A's synced delete and rename win; B's delete and rename made while off
    // do not travel; Dave, which the backup never had, is added.
    expect(names(b), {'Bob A', 'Carol', 'Dave'});
    await a.service.sync();
    expect(names(a), {'Bob A', 'Carol', 'Dave'});

    // A fresh restore sees the same address book.
    final c = device('c');
    await c.open(const PolyseedSeed(raven), restored: true);
    expect(names(c), {'Bob A', 'Carol', 'Dave'});

    await a.service.close();
    await b.service.close();
    await c.service.close();
  });

  test('a location turned off and on again joins: changes made meanwhile do not travel', () async {
    Set<String> names(Device d) => {for (final c in d.contactList) c.name};
    final a = device('a');
    a.setContacts([
      const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
      const Contact(id: 'bob', name: 'Bob', addresses: {'XMR': recipient}),
      const Contact(id: 'carol', name: 'Carol', addresses: {'XMR': recipient}),
    ]);
    await a.open(const PolyseedSeed(raven));
    final b = device('b');
    await b.open(const PolyseedSeed(raven), restored: true);
    expect(names(b), {'Alice', 'Bob', 'Carol'});

    // B turns its only location off; the backup itself stays on, for files.
    await b.service.setLocationEnabled('icloud', false);
    expect(b.service.enabled, isTrue);

    // A keeps syncing: deletes Alice, renames Bob.
    a.setContacts([
      const Contact(id: 'bob', name: 'Bob A', addresses: {'XMR': recipient}),
      const Contact(id: 'carol', name: 'Carol', addresses: {'XMR': recipient}),
    ]);
    await a.service.sync();

    // B meanwhile: renames Carol, deletes Bob, adds Dave.
    b.setContacts([
      const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
      const Contact(id: 'carol', name: 'Carol B', addresses: {'XMR': recipient}),
      const Contact(id: 'dave', name: 'Dave', addresses: {'XMR': recipient}),
    ]);
    b.service.contactsChanged();
    await b.service.idle();

    await b.service.setLocationEnabled('icloud', true);
    await b.service.idle();
    expect(names(b), {'Bob A', 'Carol', 'Dave'});
    await a.service.sync();
    expect(names(a), {'Bob A', 'Carol', 'Dave'});

    await a.service.close();
    await b.service.close();
  });

  test('with no location on, contacts are not recorded here; a saved file carries them', () async {
    Set<String> names(Device d) => {for (final c in d.contactList) c.name};
    // Neither device has a location turned on: the backup is on, for files.
    final a = Device(Directory('${tmp.path}/a'), MemoryLocation('unused-a'));
    a.setContacts([
      const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
    ]);
    await a.open(const PolyseedSeed(raven));
    expect(a.service.fileCount, 0);
    expect(a.service.contactCount, 1);

    final b = Device(Directory('${tmp.path}/b'), MemoryLocation('unused-b'));
    await b.open(const PolyseedSeed(raven), restored: true);
    expect((await b.service.importBundle(await a.service.exportBundle())).added, 1);
    expect(names(b), {'Alice'});
    expect(a.service.fileCount, 0, reason: 'the snapshot went into the file only');

    // A newer file wins over the one before it.
    a.setContacts([
      const Contact(id: 'alice', name: 'Alice 2', addresses: {'XMR': recipient}),
    ]);
    await b.service.importBundle(await a.service.exportBundle());
    expect(names(b), {'Alice 2'});

    await a.service.close();
    await b.service.close();
  });

  test('a device joins only once every enabled location has been read', () async {
    Set<String> names(Device d) => {for (final c in d.contactList) c.name};
    final a = device('a');
    a.setContacts([
      const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
      const Contact(id: 'bob', name: 'Bob', addresses: {'XMR': recipient}),
    ]);
    await a.open(const PolyseedSeed(raven));
    a.setContacts([
      const Contact(id: 'bob', name: 'Bob', addresses: {'XMR': recipient}),
    ]);
    await a.service.sync();

    // B is restored with a stale address book while iCloud is unreachable: it
    // must not take its old copy of Alice for new.
    final b = device('b');
    b.setContacts([
      const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
    ]);
    cloud.available = false;
    await b.open(const PolyseedSeed(raven), restored: true);
    expect(names(b), {'Alice'}, reason: 'nothing applied before the join');

    cloud.available = true;
    await b.service.sync();
    expect(names(b), {'Bob'});
    await a.service.sync();
    expect(names(a), {'Bob'});

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

  test('an import leaves every payment with the wallet, synced yet or not', () async {
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
    final bundle = await a.service.exportBundle();

    // A restored wallet that has not synced the payment yet.
    final lone = Device(Directory('${tmp.path}/lone'), MemoryLocation('elsewhere'));
    await lone.open(const PolyseedSeed(raven), restored: true);
    await lone.service.importBundle(bundle);
    await lone.service.carryImportIntoWallets();
    // The copy the import went into goes, as the Backup screens do with no
    // location on: from here only the wallet has the details.
    await lone.service.setEnabled(false);
    expect(lone.wallet.kept[txid]?.txKey, txKey);

    lone.wallet.history = [
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
    await lone.wallet.loadTxHistory();
    expect(lone.wallet.txHistory.single.key, txKey);
    expect(lone.wallet.txHistory.single.recipients.single.address, recipient);

    await a.service.close();
    await lone.service.close();
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

  test('turning a location off only stops adding; its delete is what removes the files', () async {
    final auto = FolderLocation('auto', () async => Directory('${tmp.path}/auto'));
    final a = Device(
      Directory('${tmp.path}/a'),
      cloud,
      extra: [BackupLocationConfig(location: auto, onDevice: true)],
    );
    a.setContacts([const Contact(id: 'c1', name: 'One', addresses: {})]);
    await a.open(const PolyseedSeed(raven));
    final folder = a.service.folderName!;
    expect(await auto.list(folder), hasLength(1));
    expect(cloud.folders[folder], hasLength(1));

    await a.service.setLocationEnabled('auto', false);
    await a.service.setLocationEnabled('icloud', false);
    a.setContacts([
      const Contact(id: 'c1', name: 'One', addresses: {}),
      const Contact(id: 'c2', name: 'Two', addresses: {}),
    ]);
    a.service.contactsChanged();
    await a.service.idle();
    expect(await auto.list(folder), hasLength(1), reason: 'kept, and nothing added');
    expect(cloud.folders[folder], hasLength(1), reason: 'kept, and nothing added');

    await a.service.deleteFromLocation('auto');
    expect(await auto.list(folder), isEmpty);
    expect(cloud.folders[folder], hasLength(1), reason: 'each location has its own delete');
    await a.service.deleteFromLocation('icloud');
    expect(cloud.folders[folder] ?? const {}, isEmpty);
    await a.service.close();
  });

  test('deleting the wallet keeps every location\'s files, even one that was on', () async {
    final auto = FolderLocation('auto', () async => Directory('${tmp.path}/auto'));
    final a = Device(
      Directory('${tmp.path}/a'),
      cloud,
      extra: [BackupLocationConfig(location: auto, onDevice: true)],
    );
    a.setContacts([const Contact(id: 'c1', name: 'One', addresses: {})]);
    await a.open(const PolyseedSeed(raven));
    final folder = a.service.folderName!;
    await a.service.deleteLocal();
    expect(await Directory('${tmp.path}/a/local').exists(), isFalse, reason: 'its own copy goes');
    expect(await auto.list(folder), hasLength(1));
    expect(cloud.folders[folder], hasLength(1));
  });

  group('opt-in', () {
    // The default: no switch saved, so the backup and every location are off.
    setUp(() => SharedPreferencesService.store = MemoryPreferenceStore());

    test('off by default: opening, sending and editing contacts write nothing', () async {
      final a = device('a');
      a.setContacts([const Contact(id: 'c1', name: 'One', addresses: {})]);
      a.wallet.history = [sentTx()];
      await a.wallet.loadTxHistory();
      await a.open(const PolyseedSeed(raven));
      a.service.outgoingPaymentSent(
        a.wallet,
        txid: txid,
        accountIndex: 0,
        fee: BigInt.one,
        recipients: [TxRecipient(recipient, BigInt.two)],
        txKey: txKey,
      );
      a.service.contactsChanged();
      a.service.historyChanged(a.wallet);
      await a.service.sync();
      await a.service.idle();

      expect(a.service.isOpen, isTrue);
      expect(a.service.enabled, isFalse);
      expect(await a.service.isLocationEnabled('icloud'), isFalse);
      expect(a.service.statusOf('icloud').enabled, isFalse);
      expect(a.service.paymentCount, 0);
      // Neither the local copy nor the device state, and no location.
      expect(await Directory('${tmp.path}/a').exists(), isFalse);
      expect(cloud.folders, isEmpty);
      await expectLater(a.service.exportBundle(), throwsStateError);
      await a.service.close();
    });

    test(
      'turning it on records past payments locally; the address book waits for a location',
      () async {
        final a = device('a');
        a.setContacts([const Contact(id: 'c1', name: 'One', addresses: {})]);
        a.wallet.history = [sentTx()];
        await a.wallet.loadTxHistory();
        await a.open(const PolyseedSeed(raven));

        await a.service.setEnabled(true);
        await a.service.idle();
        expect(a.service.enabled, isTrue);
        expect(a.service.paymentCount, 1);
        expect(a.service.fileCount, 1, reason: 'no contact recorded without a location');
        expect(a.service.contactCount, 1, reason: 'what a saved file would carry');
        expect(await Directory('${tmp.path}/a/local/${a.service.folderName}').exists(), isTrue);
        expect(cloud.folders, isEmpty);

        await a.service.setLocationEnabled('icloud', true);
        await a.service.idle();
        expect(
          cloud.folders[a.service.folderName!],
          hasLength(2),
          reason: 'the payment and the join',
        );
        expect(a.service.contactCount, 1);
        await a.service.close();
      },
    );

    test(
      'deleting the copy on this device turns every location off and leaves their files',
      () async {
        final auto = FolderLocation('auto', () async => Directory('${tmp.path}/auto'));
        final a = Device(
          Directory('${tmp.path}/a'),
          cloud,
          extra: [BackupLocationConfig(location: auto, onDevice: true)],
        );
        a.setContacts([const Contact(id: 'c1', name: 'One', addresses: {})]);
        await a.open(const PolyseedSeed(raven));
        await a.service.setEnabled(true, locations: ['icloud', 'auto']);
        await a.service.idle();
        final folder = a.service.folderName!;
        expect(await auto.list(folder), hasLength(1));
        expect(cloud.folders[folder], hasLength(1));

        await a.service.setEnabled(false);
        expect(a.service.enabled, isFalse);
        expect(await a.service.isEnabled(), isFalse);
        expect(await a.service.isLocationEnabled('icloud'), isFalse);
        expect(await a.service.isLocationEnabled('auto'), isFalse);
        expect(await Directory('${tmp.path}/a/local/$folder').exists(), isFalse);
        expect(await File('${tmp.path}/a/local/$folder.state').exists(), isFalse);
        // Both locations keep their copies until the user deletes them there.
        expect(await auto.list(folder), hasLength(1));
        expect(cloud.folders[folder], hasLength(1));

        // Nothing more is written while it is off.
        a.setContacts([
          const Contact(id: 'c1', name: 'One', addresses: {}),
          const Contact(id: 'c2', name: 'Two', addresses: {}),
        ]);
        a.service.contactsChanged();
        await a.service.idle();
        expect(cloud.folders[folder], hasLength(1));
        expect(await Directory('${tmp.path}/a/local/$folder').exists(), isFalse);
        await a.service.close();
      },
    );

    test('a restore with the backup off reads nothing until it is turned on', () async {
      final a = device('a');
      a.setContacts([const Contact(id: 'c1', name: 'One', addresses: {})]);
      await a.open(const PolyseedSeed(raven));
      await a.service.setEnabled(true, locations: ['icloud']);
      a.service.outgoingPaymentSent(
        a.wallet,
        txid: txid,
        accountIndex: 0,
        fee: BigInt.one,
        recipients: [TxRecipient(recipient, BigInt.two)],
        txKey: txKey,
      );
      await a.service.idle();
      final aDevice = a.service.deviceIdHex;
      await a.service.close();

      // A new phone: no switch carried over.
      SharedPreferencesService.store = MemoryPreferenceStore();
      final b = device('b');
      await b.open(const PolyseedSeed(raven), restored: true);
      expect(await b.service.restoreResult(), isNull);
      expect(b.service.outgoingPayment(b.wallet, txid), isNull);
      expect(b.contactList, isEmpty);
      expect(await Directory('${tmp.path}/b').exists(), isFalse);

      // What the restore prompt does when the user says yes.
      await b.service.setEnabled(true, locations: ['icloud'], reportRestore: true);
      expect(b.service.lastRestoreReport!.payments, 1);
      expect(b.service.outgoingPayment(b.wallet, txid)!.txKey, txKey);
      expect(b.contactList.map((c) => c.name), ['One']);
      expect(b.service.deviceIdHex, isNot(aDevice));
      await b.service.close();
    });

    test(
      'a copy Android put back survives the backup going on and off, and the wallet\'s deletion',
      () async {
        final auto = FolderLocation('auto', () async => Directory('${tmp.path}/auto'));
        final a = Device(
          Directory('${tmp.path}/a'),
          cloud,
          extra: [BackupLocationConfig(location: auto, onDevice: true)],
        );
        await a.open(const PolyseedSeed(raven), restored: true);
        final restored = File('${tmp.path}/auto/${a.service.folderName}/restored');
        await restored.create(recursive: true);
        await restored.writeAsBytes([1]);

        // A save the user cancelled: the local copy started, then stopped.
        await a.service.setEnabled(true);
        await a.service.idle();
        await a.service.setEnabled(false);
        expect(await restored.exists(), isTrue);

        // Deleting the copy on this device.
        await a.service.setEnabled(true);
        await a.service.setEnabled(false);
        expect(await restored.exists(), isTrue);

        await a.service.deleteLocal();
        expect(await restored.exists(), isTrue);
      },
    );

    test(
      'a copy Android put back is not read while its location is off; turning it on reads it',
      () async {
        Directory autoDir(String name) => Directory('${tmp.path}/$name/auto');
        Device phone(String name) => Device(
          Directory('${tmp.path}/$name'),
          cloud,
          extra: [
            BackupLocationConfig(
              location: FolderLocation('auto', () async => autoDir(name)),
              onDevice: true,
            ),
          ],
        );
        final a = phone('a');
        a.setContacts([
          const Contact(id: 'alice', name: 'Alice', addresses: {'XMR': recipient}),
        ]);
        a.wallet.history = [sentTx()];
        await a.wallet.loadTxHistory();
        await a.open(const PolyseedSeed(raven));
        await a.service.setEnabled(true, locations: ['auto']);
        await a.service.idle();
        final folder = a.service.folderName!;
        final backedUp = Directory('${autoDir('a').path}/$folder').listSync().length;
        expect(backedUp, greaterThan(0));
        await a.service.close();

        // A new phone: Android puts the folder back, but not the app's settings.
        SharedPreferencesService.store = MemoryPreferenceStore();
        await Directory('${autoDir('b').path}/$folder').create(recursive: true);
        for (final f in Directory('${autoDir('a').path}/$folder').listSync().whereType<File>()) {
          await f.copy('${autoDir('b').path}/$folder/${f.uri.pathSegments.last}');
        }
        final b = phone('b');
        await b.open(const PolyseedSeed(raven), restored: true);
        await b.service.idle();
        // Skipped: nothing read, nothing deleted.
        expect(b.contactList, isEmpty);
        expect(b.service.paymentCount, 0);
        expect(await b.service.filesIn('auto'), backedUp);

        await b.service.setEnabled(true, locations: ['auto']);
        await b.service.idle();
        expect(b.contactList.single.name, 'Alice');
        expect(b.service.paymentCount, 1);
        expect(
          await b.service.filesIn('auto'),
          greaterThanOrEqualTo(backedUp),
          reason: 'read, not wiped',
        );
        await b.service.close();
      },
    );

    test('findBackups looks in every location without writing or turning anything on', () async {
      final a = device('a');
      a.setContacts([const Contact(id: 'c1', name: 'One', addresses: {})]);
      await a.open(const PolyseedSeed(raven));
      await a.service.setEnabled(true, locations: ['icloud']);
      await a.service.idle();
      await a.service.close();

      // A new phone: the switches are off; one more location is empty, and one
      // cannot be reached.
      SharedPreferencesService.store = MemoryPreferenceStore();
      final empty = MemoryLocation('elsewhere');
      final offline = MemoryLocation('x')..available = false;
      final b = Device(
        Directory('${tmp.path}/b'),
        cloud,
        extra: [
          BackupLocationConfig(location: empty),
          BackupLocationConfig(location: offline),
        ],
      );
      await b.open(const PolyseedSeed(raven), restored: true);
      final probes = {for (final p in await b.service.findBackups()) p.id: p};
      expect(probes['icloud']!.found, isTrue);
      expect(probes['icloud']!.files, 1);
      expect(probes['elsewhere']!.found, isFalse);
      expect(probes['elsewhere']!.available, isTrue);
      expect(probes['x']!.available, isFalse);

      expect(b.service.enabled, isFalse);
      expect(await b.service.isLocationEnabled('icloud'), isFalse);
      expect(await Directory('${tmp.path}/b').exists(), isFalse);
      expect(empty.folders, isEmpty);
      await b.service.close();
    });

    test('deleting the wallet forgets the switches', () async {
      final a = device('a');
      await a.open(const PolyseedSeed(raven));
      await a.service.setEnabled(true, locations: ['icloud']);
      await a.service.deleteLocal();
      expect(a.service.enabled, isFalse);
      expect(await a.service.isEnabled(), isFalse);
      expect(await a.service.isLocationEnabled('icloud'), isFalse);
    });
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
