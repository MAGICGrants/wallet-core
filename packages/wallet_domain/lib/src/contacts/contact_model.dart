import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:wallet_infra/wallet_infra.dart';

import '../metadata_backup.dart';
import 'contact.dart';
import 'contacts_store.dart';

/// A new contact id: 16 random bytes, as 32 hex characters.
///
/// Random rather than the creation time, because the metadata backup merges
/// address books from several devices by id, and two devices adding a contact
/// in the same millisecond would otherwise become one contact.
String newContactId() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// The address book, as both apps present it.
class ContactModel with ChangeNotifier {
  ContactModel({Future<List<String>?> Function()? read, Future<void> Function(List<String>)? write})
    : _read = read ?? readEncodedContacts,
      _write = write ?? writeEncodedContacts {
    ContactsSync.attach(_applyRemote);
    load();
  }

  @override
  void dispose() {
    ContactsSync.detach(_applyRemote);
    super.dispose();
  }

  final Future<List<String>?> Function() _read;
  final Future<void> Function(List<String>) _write;

  List<Contact> _contacts = [];

  /// Whether the stored address book has been read successfully.
  ///
  /// Saving is gated on this, which is what stops an empty in-memory list being
  /// written over real data. It covers the read failing, the stored value not
  /// decoding, **and** the gap before the first read finishes — the constructor
  /// cannot await, so a mutation that arrives first would otherwise persist a
  /// list that was never loaded.
  bool _loaded = false;

  /// True when a read actually failed, as opposed to not having happened yet.
  /// What is in memory is not the whole address book and edits are not being
  /// saved, which is worth telling the user.
  bool _unreadable = false;

  bool get isUnreadable => _unreadable;

  List<Contact> get contacts => List.unmodifiable(_contacts);

  @visibleForTesting
  Future<void> load() async {
    try {
      final stored = await _read();
      if (stored == null) {
        _unreadable = true;
        unawaited(log(LogLevel.error, 'Address book could not be read; not saving over it.'));
        return;
      }

      _contacts = stored
          .map((entry) => Contact.fromJson(json.decode(entry) as Map<String, dynamic>))
          .toList();
      _unreadable = false;
      _loaded = true;
      notifyListeners();
    } catch (e) {
      // An entry that does not decode is still "we do not know what is stored".
      _unreadable = true;
      unawaited(log(LogLevel.error, 'Error loading contacts: $e'));
    }
  }

  Future<void> _saveContacts() async {
    if (!_loaded) {
      unawaited(
        log(LogLevel.error, 'Refusing to save contacts over an address book that was not read.'),
      );
      return;
    }

    try {
      await _write(_contacts.map((contact) => json.encode(contact.toJson())).toList());
    } catch (e) {
      unawaited(log(LogLevel.error, 'Error saving contacts: $e'));
      return;
    }
    MetadataBackup.instance?.contactsChanged();
  }

  /// Changes merged in from a metadata backup; see [ContactsSync].
  Future<void> _applyRemote(Map<String, Contact?> changes) async {
    if (!_loaded) {
      // Nothing in memory to keep in step yet: change storage, then read it.
      final stored = await _read();
      if (stored == null) return;
      await _write(applyContactChanges(stored, changes));
      await load();
      return;
    }
    final remaining = Map.of(changes);
    final updated = <Contact>[];
    for (final contact in _contacts) {
      if (!remaining.containsKey(contact.id)) {
        updated.add(contact);
        continue;
      }
      final replacement = remaining.remove(contact.id);
      if (replacement != null) updated.add(replacement);
    }
    updated.addAll(remaining.values.whereType<Contact>());
    _contacts = updated;
    notifyListeners();
    await _saveContacts();
  }

  Future<void> addContact(String name, Map<String, String> addresses) async {
    final contact = Contact(
      id: newContactId(),
      name: name.trim(),
      addresses: _normalizeAddresses(addresses),
    );

    _contacts.add(contact);
    await _saveContacts();
    notifyListeners();
  }

  Future<void> updateContact(String id, String name, Map<String, String> addresses) async {
    final index = _contacts.indexWhere((contact) => contact.id == id);
    if (index == -1) return;

    _contacts[index] = _contacts[index].copyWith(
      name: name.trim(),
      addresses: _normalizeAddresses(addresses),
    );
    await _saveContacts();
    notifyListeners();
  }

  Future<void> deleteContact(String id) async {
    _contacts.removeWhere((contact) => contact.id == id);
    await _saveContacts();
    notifyListeners();
  }

  Contact? getContactById(String id) {
    for (final contact in _contacts) {
      if (contact.id == id) return contact;
    }
    return null;
  }

  /// Contacts matching [query] by name or by any address they hold, by name.
  ///
  /// [coinSymbol] keeps only contacts holding an address on that chain, which is
  /// what a send screen wants; an app with one chain has no use for it.
  ///
  /// Always sorted. Skylight used to show the order contacts were added, which
  /// was preserved through the move to shared code and then unified here
  /// deliberately, so both address books read the same way.
  List<Contact> searchContacts(String query, {String? coinSymbol}) {
    var results = _contacts.toList();

    if (coinSymbol != null) {
      final symbol = coinSymbol.toUpperCase();
      results = results.where((c) => c.addressFor(symbol) != null).toList();
    }

    if (query.isNotEmpty) {
      final lowercaseQuery = query.toLowerCase();
      results = results.where((contact) {
        if (contact.name.toLowerCase().contains(lowercaseQuery)) return true;
        return contact.addresses.values.any((a) => a.toLowerCase().contains(lowercaseQuery));
      }).toList();
    }

    results.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return results;
  }

  Map<String, String> _normalizeAddresses(Map<String, String> addresses) => {
    for (final entry in addresses.entries)
      if (entry.value.trim().isNotEmpty) entry.key.toUpperCase(): entry.value.trim(),
  };
}
