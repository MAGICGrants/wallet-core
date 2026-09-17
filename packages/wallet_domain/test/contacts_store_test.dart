import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/testing.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// The address book holds the user's counterparties, so it belongs in secure
/// storage.
///
/// These drive the real store, unlike `contact_model_test.dart` which injects a
/// fake one: the secure-storage round trip is the part a fake cannot exercise.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('clearContacts removes the address book', () async {
    final model = ContactModel();
    await model.load();
    await model.addContact('Alice', {'XMR': '4Alice'});
    expect(await secureContacts(), hasLength(1));

    await clearContacts();

    expect(await secureContacts(), isNull);
  });

  test('an empty address book reads as empty, not as unreadable', () async {
    await WalletSecrets.store.write('contacts', json.encode(<String>[]));

    final model = ContactModel();
    await model.load();

    expect(model.isUnreadable, isFalse);
    expect(model.contacts, isEmpty);
  });
}
