import 'dart:async';
import 'dart:convert';

import 'package:wallet_infra/wallet_infra.dart';

import 'address_label.dart';

/// Storage for address labels.
///
/// A label says what an address was given out for ("Rent", "Donations"), which
/// is as private as the address book, so labels live in secure storage beside
/// it: one JSON array of [AddressLabel] maps, under one key for every coin.
///
/// Unlike the address book, labels belong to the wallet's own addresses, so
/// deleting the wallet deletes them ([clearAddressLabels]); restoring it from
/// its seed brings them back from the metadata backup.
const _storageKey = 'addressLabels';

/// Reads every label, or null if they could not be read.
///
/// **Null is not the same as empty** — the same rule as `readEncodedContacts`:
/// a store that failed to read and is then saved over as empty loses every
/// label for good.
Future<List<AddressLabel>?> readAddressLabels() async {
  String? stored;
  try {
    stored = await WalletSecrets.store.read(_storageKey);
  } catch (e) {
    unawaited(log(LogLevel.error, 'Could not read address labels: $e'));
    return null;
  }
  if (stored == null || stored.isEmpty) return [];
  try {
    return [
      for (final entry in json.decode(stored) as List<dynamic>)
        AddressLabel.fromJson(entry as Map<String, dynamic>),
    ];
  } catch (e) {
    unawaited(log(LogLevel.error, 'Address labels are unreadable: $e'));
    return null;
  }
}

Future<void> writeAddressLabels(List<AddressLabel> labels) async {
  await WalletSecrets.store.write(_storageKey, json.encode([for (final l in labels) l.toJson()]));
}

/// Deletes every stored label, and empties an open `AddressLabelModel`, which
/// would otherwise write them back with its next save. The wallet is being
/// deleted.
Future<void> clearAddressLabels() async {
  try {
    await WalletSecrets.store.delete(_storageKey);
  } catch (e) {
    unawaited(log(LogLevel.error, 'Could not clear address labels: $e'));
  }
  AddressLabelsSync._cleared?.call();
}

/// Applies label changes merged in from a metadata backup, the way
/// `ContactsSync` does for the address book: through an open
/// `AddressLabelModel` when there is one, so an edit made at the same moment
/// lands on top, else to storage directly.
abstract final class AddressLabelsSync {
  static Future<void> Function(Map<String, AddressLabel?> changes)? _model;
  static void Function()? _cleared;

  /// Installed by `AddressLabelModel`; the last one constructed wins.
  static void attach(
    Future<void> Function(Map<String, AddressLabel?> changes) model, {
    required void Function() onCleared,
  }) {
    _model = model;
    _cleared = onCleared;
  }

  static void detach(Future<void> Function(Map<String, AddressLabel?> changes) model) {
    if (_model != model) return;
    _model = null;
    _cleared = null;
  }

  /// [changes] maps an [AddressLabel.key] to its new label, or to null when it
  /// was removed. Keys not named are left alone.
  ///
  /// Throws when the changes were not stored, so the caller does not take them
  /// as stored.
  static Future<void> applyRemote(Map<String, AddressLabel?> changes) async {
    if (changes.isEmpty) return;
    final model = _model;
    if (model != null) return model(changes);

    final stored = await readAddressLabels();
    if (stored == null) {
      throw StateError('Address labels unreadable; backup changes not applied');
    }
    await writeAddressLabels(applyAddressLabelChanges(stored, changes));
  }
}

/// [stored] with [changes] applied: replaced in place, removed, or appended
/// when new.
List<AddressLabel> applyAddressLabelChanges(
  List<AddressLabel> stored,
  Map<String, AddressLabel?> changes,
) {
  final remaining = Map.of(changes);
  final out = <AddressLabel>[];
  for (final label in stored) {
    if (!remaining.containsKey(label.key)) {
      out.add(label);
      continue;
    }
    final replacement = remaining.remove(label.key);
    if (replacement != null) out.add(replacement);
  }
  out.addAll(remaining.values.whereType<AddressLabel>());
  return out;
}
