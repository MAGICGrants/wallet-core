import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

AddressReceipt receipt(String address, int index, int amount, String tx, int at) => (
  address: address,
  index: index,
  amountBaseUnits: BigInt.from(amount),
  txHash: tx,
  timestamp: at,
);

void main() {
  group('summarizeReceipts', () {
    test('sums per address, counts each transaction once, newest first', () {
      final used = summarizeReceipts([
        receipt('8a', 1, 5, 'tx1', 100),
        receipt('8b', 2, 7, 'tx2', 300),
        // wallet2 lists a transaction once per subaddress it paid: tx3 twice
        // here, at two addresses.
        receipt('8a', 1, 3, 'tx3', 200),
        receipt('8c', 3, 1, 'tx3', 200),
      ]);
      // 8a and 8c tie on time: the higher index first.
      expect(used.map((u) => u.address), ['8b', '8c', '8a']);
      final a = used[2];
      expect((a.index, a.receivedBaseUnits, a.txCount, a.lastUsed), (1, BigInt.from(8), 2, 200));
    });

    test('a tie on time puts the higher index first; no time yet counts as now', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);
      final used = summarizeReceipts([
        receipt('8low', 1, 1, 'a', 500),
        receipt('8high', 4, 1, 'b', 500),
        receipt('8pending', 2, 1, 'c', 0),
      ], now: now);
      expect(used.map((u) => u.address), ['8pending', '8high', '8low']);
      expect(used.first.lastUsed, 1000);
    });
  });

  group('AddressLabelModel', () {
    late List<AddressLabel> stored;
    late int writes;

    setUp(() {
      SharedPreferencesService.store = MemoryPreferenceStore();
      stored = [];
      writes = 0;
    });

    AddressLabelModel model({bool unreadable = false}) => AddressLabelModel(
      read: () async => unreadable ? null : List.of(stored),
      write: (labels) async {
        writes++;
        stored = List.of(labels);
      },
    );

    test('labels, renames and removes by coin and address', () async {
      final m = model();
      await m.load();
      await m.setLabel('xmr', '8a', '  Donations ');
      expect(m.labelFor('XMR', '8a'), 'Donations');
      expect(stored.single.coin, 'XMR');

      await m.setLabel('XMR', '8a', 'Tips');
      expect(m.labelFor('XMR', '8a'), 'Tips');
      expect(m.labelFor('BTC', '8a'), isNull, reason: 'labels are per coin');

      await m.setLabel('XMR', '8a', '   ');
      expect(m.labelFor('XMR', '8a'), isNull);
      expect(stored, isEmpty);
      m.dispose();
    });

    test(
      'a label is cut to the longest the app saves, and an unchanged one is not saved',
      () async {
        final m = model();
        await m.load();
        await m.setLabel('BTC', 'bc1q', 'x' * (maxAddressLabelLength + 10));
        expect(m.labelFor('BTC', 'bc1q'), hasLength(maxAddressLabelLength));
        final before = writes;
        await m.setLabel('BTC', 'bc1q', 'x' * maxAddressLabelLength);
        expect(writes, before);
        m.dispose();
      },
    );

    test('labels that could not be read are never saved over', () async {
      stored = [const AddressLabel(coin: 'XMR', address: '8a', label: 'Kept')];
      final m = model(unreadable: true);
      await m.load();
      await m.setLabel('XMR', '8b', 'New');
      expect(writes, 0);
      expect(stored.single.label, 'Kept');
      m.dispose();
    });

    test('Delete Address Labels removes every one, even labels that could not be read', () async {
      stored = [const AddressLabel(coin: 'XMR', address: '8a', label: 'Old')];
      final m = model(unreadable: true);
      await m.load();
      await m.deleteAll();
      expect(m.count, 0);
      expect(stored, isEmpty);
      m.dispose();
    });

    test('changes from a backup land in the open model', () async {
      final m = model();
      await m.load();
      await m.setLabel('XMR', '8a', 'Mine');
      await AddressLabelsSync.applyRemote({
        'XMR:8a': null,
        'BTC:bc1q': const AddressLabel(coin: 'BTC', address: 'bc1q', label: 'Rent'),
      });
      expect(m.labelFor('XMR', '8a'), isNull);
      expect(m.labelFor('BTC', 'bc1q'), 'Rent');
      expect(stored.map((l) => l.key), ['BTC:bc1q']);
      m.dispose();
    });
  });

  group('the labels file', () {
    late Directory tmp;

    setUpAll(() => WalletFileCrypto.kdf = const FastTestPbkdf2());
    tearDownAll(() => WalletFileCrypto.kdf = const WebCryptoPbkdf2());

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('address_labels');
      WalletAppConfig.install(WalletAppConfig.spice, directories: FixedDirectories(tmp));
      WalletSecrets.store = MemorySecretStore();
      AddressLabelKey.password = 'wallet password';
    });

    tearDown(() {
      AddressLabelKey.resetForTesting();
      WalletSecrets.resetForTesting();
      WalletAppConfig.resetForTesting();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    File file() => File('${tmp.path}/address_labels');

    /// Waits for [done]: decryption runs in another isolate, past the
    /// microtask queue.
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(done(), isTrue, reason: 'timed out');
    }

    test('is encrypted with the wallet password, beside the wallet files', () async {
      await writeAddressLabels([
        const AddressLabel(coin: 'XMR', address: '8a', label: 'Donations'),
      ]);

      expect(file().existsSync(), isTrue);
      final blob = file().readAsStringSync();
      expect(blob, isNot(contains('Donations')));
      expect(utf8.decode(base64.decode(blob), allowMalformed: true), isNot(contains('Donations')));
      expect((await readAddressLabels())!.single.label, 'Donations');
      expect(await readAddressLabels(password: 'another password'), isNull);
    });

    test('cannot be read or written while the wallet is locked', () async {
      await writeAddressLabels([const AddressLabel(coin: 'XMR', address: '8a', label: 'Rent')]);
      AddressLabelKey.password = null;

      expect(await readAddressLabels(), isNull);
      expect(() => writeAddressLabels(const []), throwsStateError);
    });

    test('the model reads them at unlock and lets go of them at lock', () async {
      await writeAddressLabels([const AddressLabel(coin: 'XMR', address: '8a', label: 'Rent')]);
      AddressLabelKey.password = null;
      final m = AddressLabelModel();
      addTearDown(m.dispose);
      await pumpEventQueue();
      expect(m.count, 0, reason: 'locked');

      // Saving while locked writes nothing: the file still has only Rent.
      await m.setLabel('XMR', '8b', 'Ignored');
      AddressLabelKey.password = 'wallet password';
      await until(() => m.labelFor('XMR', '8a') != null);
      expect(m.labelFor('XMR', '8a'), 'Rent');
      expect(m.labelFor('XMR', '8b'), isNull);

      AddressLabelKey.password = null;
      expect(m.count, 0, reason: 'the lock empties memory');
      expect(file().existsSync(), isTrue, reason: 'and leaves the file alone');
    });

    test('labels an older build kept in the keystore move into the file', () async {
      await WalletSecrets.store.write(
        'addressLabels',
        json.encode([const AddressLabel(coin: 'BTC', address: 'bc1q', label: 'Savings').toJson()]),
      );

      expect((await readAddressLabels())!.single.label, 'Savings');
      expect(await WalletSecrets.store.read('addressLabels'), isNull);
      expect(file().existsSync(), isTrue);
      expect((await readAddressLabels())!.single.label, 'Savings');
    });

    test('re-keying moves them to the new password', () async {
      await writeAddressLabels([const AddressLabel(coin: 'XMR', address: '8a', label: 'Tips')]);

      await rekeyAddressLabels(from: 'wallet password', to: 'guarded password');

      expect(await readAddressLabels(password: 'wallet password'), isNull);
      expect((await readAddressLabels(password: 'guarded password'))!.single.label, 'Tips');
    });

    test('re-keying refuses a file the old password does not open', () async {
      await writeAddressLabels(const [], password: 'some other password');
      expect(rekeyAddressLabels(from: 'wallet password', to: 'guarded password'), throwsStateError);
    });

    test('deleting the wallet removes the file, any keystore copy and the open model', () async {
      final m = AddressLabelModel();
      addTearDown(m.dispose);
      await pumpEventQueue();
      await m.setLabel('XMR', '8a', 'Donations');
      await WalletSecrets.store.write('addressLabels', '[]');
      expect(file().existsSync(), isTrue);

      await clearAddressLabels();
      expect(m.count, 0);
      expect(file().existsSync(), isFalse);
      expect(await WalletSecrets.store.read('addressLabels'), isNull);
      // The next wallet's labels save normally.
      await m.setLabel('XMR', '8b', 'Next');
      expect((await readAddressLabels())!.single.label, 'Next');
    });
  });

  test('applyAddressLabelChanges replaces in place, removes and appends', () {
    const a = AddressLabel(coin: 'XMR', address: '8a', label: 'A');
    const b = AddressLabel(coin: 'XMR', address: '8b', label: 'B');
    final out = applyAddressLabelChanges(
      [a, b],
      {
        a.key: null,
        b.key: const AddressLabel(coin: 'XMR', address: '8b', label: 'B2'),
        'BTC:bc1q': const AddressLabel(coin: 'BTC', address: 'bc1q', label: 'C'),
      },
    );
    expect(out.map((l) => l.label), ['B2', 'C']);
  });
}
