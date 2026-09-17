import 'dart:async';
import 'dart:convert';

import 'package:wallet_infra/wallet_infra.dart';

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
