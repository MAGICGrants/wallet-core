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
/// Reached through [WalletSecrets], the platform keystore, under [_storageKey].
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

  if (stored == null) return [];

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
}
