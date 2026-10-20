import 'dart:async';
import 'dart:convert';

import 'package:wallet_infra/wallet_infra.dart';

import 'contact.dart';

/// Storage for the address book.
///
/// Contacts are names attached to addresses — the user's counterparties — so
/// they live in secure storage rather than the plaintext preferences file.
///
/// Entries are the JSON strings [Contact] encodes, held as one JSON array,
/// because secure storage stores strings and not lists.
///
/// Reached through [WalletSecrets], which is the same platform keystore under
/// the same key — so this reads what earlier builds wrote — and is injectable,
/// so the migration below can be exercised without a plugin mock.
const _storageKey = 'contacts';

/// Reads the address book, or null if it could not be read.
///
/// **Null is not the same as empty, and callers must not treat it as such.** An
/// unreadable store that reads as "no contacts" is overwritten with an empty
/// list by the next save, losing the address book for good. The read can fail
/// for reasons that leave the stored data perfectly intact — a keystore locked
/// or re-keyed by an OS upgrade, a restore onto a new device — so treating the
/// failure as "empty" turns a transient error into permanent loss.
Future<List<String>?> readEncodedContacts() async {
  String? stored;

  try {
    stored = await WalletSecrets.store.read(_storageKey);
  } catch (e) {
    unawaited(log(LogLevel.error, 'Could not read contacts: $e'));
    return null;
  }

  if (stored == null) return _migrateFromPreferences();

  // Present but empty is a real empty address book.
  if (stored.isEmpty) return [];

  try {
    return (json.decode(stored) as List<dynamic>).cast<String>();
  } catch (e) {
    unawaited(log(LogLevel.error, 'Contacts are unreadable: $e'));
    return null;
  }
}

Future<void> writeEncodedContacts(List<String> contacts) async {
  await WalletSecrets.store.write(_storageKey, json.encode(contacts));
}

/// Deletes the stored address book. Part of deleting a wallet: contacts are the
/// user's counterparties, and leaving them behind outlives the wallet they
/// belonged to.
Future<void> clearContacts() async {
  try {
    await WalletSecrets.store.delete(_storageKey);
  } catch (e) {
    unawaited(log(LogLevel.error, 'Could not clear contacts: $e'));
  }

  // Also drop anything a build that predates the move to secure storage left
  // behind, or deleting a wallet would leave a plaintext address book on disk.
  await SharedPreferencesService.remove(SettingsKeys.contacts);
}

/// Moves an address book written by an earlier build out of shared preferences.
///
/// The plaintext copy is deleted only once the secure copy is safely written —
/// if that fails the contacts are still returned and still in preferences, and
/// the next launch tries again.
///
/// An app that never stored contacts in preferences finds nothing and gets an
/// empty address book, which is the correct answer for a first run.
Future<List<String>?> _migrateFromPreferences() async {
  final legacy = await SharedPreferencesService.get<List<String>>(SettingsKeys.contacts);
  if (legacy == null) return [];

  try {
    await writeEncodedContacts(legacy);
  } catch (e) {
    unawaited(log(LogLevel.error, 'Could not move contacts to secure storage: $e'));
    return legacy;
  }

  await SharedPreferencesService.remove(SettingsKeys.contacts);
  unawaited(log(LogLevel.info, 'Moved ${legacy.length} contacts out of shared preferences'));

  return legacy;
}

/// Applies address-book changes merged in from elsewhere: a metadata backup
/// written by another device, or one being restored.
///
/// An open `ContactModel` registers itself here and takes the changes in
/// memory, so an edit the user is making at the same moment is applied on top
/// of them rather than racing a write underneath it. With no model open, the
/// changes are applied to storage directly.
abstract final class ContactsSync {
  static Future<void> Function(Map<String, Contact?> changes)? _model;

  /// Installed by `ContactModel`; the last one constructed wins.
  static void attach(Future<void> Function(Map<String, Contact?> changes) model) => _model = model;

  static void detach(Future<void> Function(Map<String, Contact?> changes) model) {
    if (_model == model) _model = null;
  }

  /// [changes] maps a contact id to its new version, or to null when it was
  /// deleted. Ids not named are left alone.
  static Future<void> applyRemote(Map<String, Contact?> changes) async {
    if (changes.isEmpty) return;
    final model = _model;
    if (model != null) return model(changes);

    final stored = await readEncodedContacts();
    if (stored == null) {
      unawaited(log(LogLevel.warn, 'Address book unreadable; backup changes not applied.'));
      return;
    }
    await writeEncodedContacts(applyContactChanges(stored, changes));
  }
}

/// [stored] (encoded contacts) with [changes] applied: replaced in place,
/// removed, or appended when new.
List<String> applyContactChanges(List<String> stored, Map<String, Contact?> changes) {
  final remaining = Map.of(changes);
  final out = <String>[];
  for (final entry in stored) {
    final contact = Contact.fromJson(json.decode(entry) as Map<String, dynamic>);
    if (!remaining.containsKey(contact.id)) {
      out.add(entry);
      continue;
    }
    final replacement = remaining.remove(contact.id);
    if (replacement != null) out.add(json.encode(replacement.toJson()));
  }
  for (final added in remaining.values) {
    if (added != null) out.add(json.encode(added.toJson()));
  }
  return out;
}
