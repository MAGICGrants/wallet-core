import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// The address book holds the user's counterparties, so it belongs in secure
/// storage — and moving it there must not lose anyone's contacts.
///
/// These drive the real store, unlike `contact_model_test.dart` which injects a
/// fake one: the migration out of shared preferences and the secure-storage
/// round trip are the parts a fake cannot exercise.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The single-address shape older Skylight builds wrote.
  String legacyEncoded(String id, String name, String address) =>
      json.encode({'id': id, 'name': name, 'address': address});

  Future<List<String>?> secureContacts() async {
    final raw = await WalletSecrets.store.read('contacts');
    return raw == null ? null : (json.decode(raw) as List<dynamic>).cast<String>();
  }

  Future<List<String>?> plaintextContacts() =>
      SharedPreferencesService.get<List<String>>(SettingsKeys.contacts);

  setUp(() {
    SharedPreferencesService.store = MemoryPreferenceStore();
    WalletSecrets.store = MemorySecretStore();
  });

  tearDown(() {
    SharedPreferencesService.resetForTesting();
    WalletSecrets.resetForTesting();
  });

  test('a new contact is written to secure storage, not preferences', () async {
    final model = ContactModel();
    await model.load();

    await model.addContact('Alice', {'XMR': '4AliceAddress'});

    expect(await secureContacts(), hasLength(1));
    expect(await plaintextContacts(), isNull, reason: 'nothing about contacts in plaintext');
  });

  test('contacts written by an older build are migrated and the plaintext copy removed', () async {
    await SharedPreferencesService.set<List<String>>(SettingsKeys.contacts, [
      legacyEncoded('1', 'Alice', '4Alice'),
      legacyEncoded('2', 'Bob', '4Bob'),
    ]);

    final model = ContactModel();
    await model.load();

    expect(model.contacts.map((c) => c.name), ['Alice', 'Bob']);
    expect(model.contacts.first.addressFor('XMR'), '4Alice');
    expect(await secureContacts(), hasLength(2));
    expect(await plaintextContacts(), isNull, reason: 'the plaintext copy must be deleted');
  });

  test('migration runs once and the secure copy wins afterwards', () async {
    await SharedPreferencesService.set<List<String>>(SettingsKeys.contacts, [
      legacyEncoded('1', 'Alice', '4Alice'),
    ]);

    await (ContactModel()..load()).load();

    // A stale plaintext entry reappearing must not override secure storage.
    await SharedPreferencesService.set<List<String>>(SettingsKeys.contacts, [
      legacyEncoded('9', 'Impostor', '4Impostor'),
    ]);

    final second = ContactModel();
    await second.load();

    expect(second.contacts.map((c) => c.name), ['Alice']);
  });

  test('an unreadable address book is not overwritten by an empty one', () async {
    await WalletSecrets.store.write('contacts', 'not json');

    final model = ContactModel();
    await model.load();

    expect(model.isUnreadable, isTrue);
    expect(model.contacts, isEmpty);

    // A save in that state would otherwise replace the stored address book with
    // the empty in-memory one.
    await model.addContact('Alice', {'XMR': '4Alice'});

    expect(await WalletSecrets.store.read('contacts'), 'not json');
  });

  test('clearContacts removes both copies', () async {
    await SharedPreferencesService.set<List<String>>(SettingsKeys.contacts, [
      legacyEncoded('1', 'Alice', '4Alice'),
    ]);
    await WalletSecrets.store.write(
      'contacts',
      json.encode([legacyEncoded('1', 'Alice', '4Alice')]),
    );

    await clearContacts();

    expect(await secureContacts(), isNull);
    expect(await plaintextContacts(), isNull);
  });

  test('an empty address book reads as empty, not as unreadable', () async {
    await WalletSecrets.store.write('contacts', json.encode(<String>[]));

    final model = ContactModel();
    await model.load();

    expect(model.isUnreadable, isFalse);
    expect(model.contacts, isEmpty);
  });
}
