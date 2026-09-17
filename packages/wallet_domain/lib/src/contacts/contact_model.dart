import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'contact.dart';
import 'contacts_store.dart';

/// The address book, as both apps present it.
class ContactModel with ChangeNotifier {
  ContactModel({Future<List<String>?> Function()? read, Future<void> Function(List<String>)? write})
    : _read = read ?? readEncodedContacts,
      _write = write ?? writeEncodedContacts {
    load();
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
    }
  }

  Future<void> addContact(String name, Map<String, String> addresses) async {
    final contact = Contact(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
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
