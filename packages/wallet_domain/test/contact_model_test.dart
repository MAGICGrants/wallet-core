import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';

/// The address book must never be saved over data that was not read.
///
/// The failure this exists for is silent and permanent: a read that throws left
/// the in-memory list empty, and the very next add, edit or delete wrote that
/// empty list back over a perfectly intact address book. The read can fail for
/// reasons that leave the stored data fine — a keystore re-keyed by an OS
/// upgrade, a restore onto a new device — so "could not read" must never be
/// allowed to present as "there is nothing here".
void main() {
  String encoded(String id, String name, String address) => json.encode({
    'id': id,
    'name': name,
    'addresses': {'XMR': address},
  });

  /// A model whose store is scripted, with every write recorded.
  ({ContactModel model, List<List<String>> writes}) modelWith({
    required Future<List<String>?> Function() read,
  }) {
    final writes = <List<String>>[];
    final model = ContactModel(read: read, write: (c) async => writes.add(c));
    return (model: model, writes: writes);
  }

  final stored = [encoded('1', 'Alice', '4alice'), encoded('2', 'Bob', '4bob')];

  group('a store that was read', () {
    test('loads, and edits are saved', () async {
      final h = modelWith(read: () async => stored);
      await h.model.load();

      expect(h.model.contacts, hasLength(2));
      expect(h.model.isUnreadable, isFalse);

      await h.model.addContact('Carol', {'XMR': '4carol'});
      expect(h.writes.single, hasLength(3));
    });

    test('nothing saved yet is a real empty address book, not a failure', () async {
      // The store returns [] for an absent key; that is a first run, and the
      // user must be able to add their first contact.
      final h = modelWith(read: () async => []);
      await h.model.load();

      expect(h.model.isUnreadable, isFalse);
      await h.model.addContact('Alice', {'XMR': '4alice'});
      expect(h.writes.single, hasLength(1));
    });

    test('deleting the address book empties it, saves that, and tells the backup', () async {
      final backup = _CountingBackup();
      MetadataBackup.instance = backup;
      addTearDown(() => MetadataBackup.instance = null);
      final h = modelWith(read: () async => stored);
      await h.model.load();

      await h.model.deleteAll();
      expect(h.model.contacts, isEmpty);
      expect(h.writes.single, isEmpty);
      expect(backup.contactsChanges, 1, reason: 'a syncing backup records the deletions');
    });
  });

  group('a store that could not be read', () {
    test('deleting the address book writes over it: the user asked for all of it to go', () async {
      final h = modelWith(read: () async => null);
      await h.model.load();
      expect(h.model.isUnreadable, isTrue);

      await h.model.deleteAll();
      expect(h.model.isUnreadable, isFalse);
      expect(h.writes.single, isEmpty);
    });

    test('does not present as an empty address book', () async {
      final h = modelWith(read: () async => null);
      await h.model.load();

      expect(h.model.contacts, isEmpty);
      expect(h.model.isUnreadable, isTrue, reason: 'empty and unreadable are different states');
    });

    test('an add does not write the missing contacts away', () async {
      final h = modelWith(read: () async => null);
      await h.model.load();

      await h.model.addContact('Carol', {'XMR': '4carol'});

      expect(h.writes, isEmpty, reason: 'the stored address book must be left alone');
    });

    test('a delete does not write either', () async {
      // The worst shape of the bug: removing from an empty list changes nothing,
      // then persists that nothing over two real contacts.
      final h = modelWith(read: () async => null);
      await h.model.load();

      await h.model.deleteContact('1');

      expect(h.writes, isEmpty);
    });

    test('a throwing read is unreadable, not empty', () async {
      final h = modelWith(read: () async => throw Exception('keystore unavailable'));
      await h.model.load();

      expect(h.model.isUnreadable, isTrue);
      await h.model.addContact('Carol', {'XMR': '4carol'});
      expect(h.writes, isEmpty);
    });

    test('an entry that does not decode is unreadable, not empty', () async {
      final h = modelWith(read: () async => ['not json']);
      await h.model.load();

      expect(h.model.isUnreadable, isTrue);
      await h.model.addContact('Carol', {'XMR': '4carol'});
      expect(h.writes, isEmpty);
    });

    test('a later successful read recovers, and saving resumes', () async {
      var fail = true;
      final h = modelWith(read: () async => fail ? null : stored);
      await h.model.load();
      expect(h.model.isUnreadable, isTrue);

      fail = false;
      await h.model.load();

      expect(h.model.isUnreadable, isFalse);
      expect(h.model.contacts, hasLength(2));
      await h.model.addContact('Carol', {'XMR': '4carol'});
      expect(h.writes.single, hasLength(3));
    });
  });

  // ContactsSync.applyRemote reaches the open model. The backup counts the
  // changes as this device's address book only if they were stored, so a
  // failure must reach it; the user's own edits still stay in memory quietly.
  group('changes from the backup', () {
    const carol = Contact(id: '3', name: 'Carol', addresses: {'XMR': '4carol'});

    test('are applied and written', () async {
      final h = modelWith(read: () async => stored);
      addTearDown(h.model.dispose);
      await h.model.load();
      await ContactsSync.applyRemote({'2': null, '3': carol});
      expect(h.model.contacts.map((c) => c.name), ['Alice', 'Carol']);
      expect(h.writes.last, hasLength(2));
    });

    test('a write that fails is reported, and they stay in memory', () async {
      final model = ContactModel(
        read: () async => stored,
        write: (_) async => throw Exception('keystore unavailable'),
      );
      addTearDown(model.dispose);
      await model.load();
      await expectLater(ContactsSync.applyRemote({'3': carol}), throwsException);
      expect(model.contacts.map((c) => c.name), ['Alice', 'Bob', 'Carol']);
    });

    test('an address book that could not be read refuses them', () async {
      final h = modelWith(read: () async => null);
      addTearDown(h.model.dispose);
      await h.model.load();
      await expectLater(ContactsSync.applyRemote({'3': carol}), throwsStateError);
      expect(h.writes, isEmpty);
    });

    test("the user's own edit that fails to save does not throw", () async {
      final model = ContactModel(
        read: () async => stored,
        write: (_) async => throw Exception('keystore unavailable'),
      );
      addTearDown(model.dispose);
      await model.load();
      await model.addContact('Dan', {'XMR': '4dan'});
      expect(model.contacts.map((c) => c.name), contains('Dan'));
    });
  });

  group('the stored format both apps share', () {
    test('a legacy single-address entry reads as a Monero contact', () async {
      // What earlier Skylight builds wrote. It predates any other chain being
      // storable, so the address is Monero's by definition.
      final h = modelWith(
        read: () async => [
          json.encode({'id': '1', 'name': 'Alice', 'address': '4alice'}),
        ],
      );
      await h.model.load();

      expect(h.model.contacts.single.addressFor('XMR'), '4alice');
      expect(h.model.contacts.single.addressFor('BTC'), isNull);
    });

    test('a legacy entry is rewritten in the multi-address form', () async {
      final h = modelWith(
        read: () async => [
          json.encode({'id': '1', 'name': 'Alice', 'address': '4alice'}),
        ],
      );
      await h.model.load();
      await h.model.addContact('Bob', {'XMR': '4bob'});

      for (final entry in h.writes.single) {
        expect(json.decode(entry), containsPair('addresses', isA<Map<String, dynamic>>()));
      }
    });

    test('symbols are upper-cased and blank addresses dropped', () async {
      final h = modelWith(read: () async => []);
      await h.model.load();
      await h.model.addContact('  Alice  ', {'xmr': ' 4alice ', 'btc': '   '});

      final saved = h.model.contacts.single;
      expect(saved.name, 'Alice');
      expect(saved.addresses, {'XMR': '4alice'});
    });
  });

  group('search', () {
    // Both apps show the same order now. The one thing that still differs is the
    // coin filter, which a single-chain app has no use for.
    Future<ContactModel> withThree() async {
      final h = modelWith(
        read: () async => [
          encoded('1', 'Carol', '4carol'),
          encoded('2', 'Alice', '4alice'),
          encoded('3', 'Bob', '4bob'),
        ],
      );
      await h.model.load();
      return h.model;
    }

    test('orders by name, whatever order contacts were added in', () async {
      // Both address books read the same way. Skylight used to list contacts in
      // the order they were added; unified on Spice's alphabetical order.
      final model = await withThree();
      expect(model.searchContacts('').map((c) => c.name), ['Alice', 'Bob', 'Carol']);
    });

    test('a searched or filtered list is sorted too', () async {
      final model = await withThree();
      expect(model.searchContacts('o').map((c) => c.name), ['Bob', 'Carol']);
      expect(model.searchContacts('', coinSymbol: 'XMR').map((c) => c.name), [
        'Alice',
        'Bob',
        'Carol',
      ]);
    });

    test('a coin filter keeps only contacts holding that chain', () async {
      final h = modelWith(
        read: () async => [
          encoded('1', 'Alice', '4alice'),
          json.encode({
            'id': '2',
            'name': 'Bob',
            'addresses': {'BTC': 'bc1bob'},
          }),
        ],
      );
      await h.model.load();

      expect(h.model.searchContacts('', coinSymbol: 'XMR').map((c) => c.name), ['Alice']);
      expect(h.model.searchContacts('', coinSymbol: 'btc').map((c) => c.name), ['Bob']);
    });

    test('a query matches a name or any address the contact holds', () async {
      final model = await withThree();
      expect(model.searchContacts('ali').map((c) => c.name), ['Alice']);
      expect(model.searchContacts('4bob').map((c) => c.name), ['Bob']);
    });
  });

  test('an edit before the first read finishes does not save', () async {
    // The constructor cannot await its own load, so there is a window where the
    // list is empty because nothing has been read yet. Reaching the address book
    // and adding a contact inside it used to persist that empty list.
    final gate = Completer<List<String>?>();
    final h = modelWith(read: () => gate.future);

    await h.model.addContact('Carol', {'XMR': '4carol'});
    expect(h.writes, isEmpty, reason: 'nothing has been read yet');

    gate.complete(stored);
    await h.model.load();

    expect(h.model.contacts, hasLength(2), reason: 'the real address book still loads');
  });
}

/// Counts the address-book changes reported to the metadata backup.
class _CountingBackup implements MetadataBackup {
  int contactsChanges = 0;

  @override
  void contactsChanged() => contactsChanges++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
