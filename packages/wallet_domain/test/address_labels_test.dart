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

    test('deleting the wallet empties the store and the open model', () async {
      WalletSecrets.store = MemorySecretStore();
      final m = AddressLabelModel();
      await m.load();
      await m.setLabel('XMR', '8a', 'Donations');
      expect(await readAddressLabels(), hasLength(1));

      await clearAddressLabels();
      expect(m.count, 0);
      expect(await readAddressLabels(), isEmpty);
      // The next wallet's labels save normally.
      await m.setLabel('XMR', '8b', 'Next');
      expect((await readAddressLabels())!.single.label, 'Next');
      m.dispose();
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
