import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wallet_infra/wallet_infra.dart';

import '../metadata_backup.dart';
import 'address_label.dart';
import 'address_label_store.dart';

/// The names the user gave their own receive addresses, as both apps present
/// them: on Receive's Labeled tab, in History's address filter and in a
/// received transaction's details.
class AddressLabelModel with ChangeNotifier {
  AddressLabelModel({
    Future<List<AddressLabel>?> Function()? read,
    Future<void> Function(List<AddressLabel>)? write,
  }) : _read = read ?? readAddressLabels,
       _write = write ?? writeAddressLabels {
    AddressLabelsSync.attach(_applyRemote, onCleared: _cleared);
    load();
  }

  @override
  void dispose() {
    AddressLabelsSync.detach(_applyRemote);
    super.dispose();
  }

  final Future<List<AddressLabel>?> Function() _read;
  final Future<void> Function(List<AddressLabel>) _write;

  /// By [AddressLabel.key].
  Map<String, AddressLabel> _labels = {};

  /// Whether the stored labels have been read successfully. Saving is gated on
  /// it, as `ContactModel` gates the address book, so a failed or unfinished
  /// read is never saved over as "no labels".
  bool _loaded = false;

  int get count => _labels.length;

  /// The label of [address] on [coin], or null when it has none.
  String? labelFor(String coin, String address) => _labels[addressLabelKey(coin, address)]?.label;

  /// Every label on [coin].
  List<AddressLabel> labelsFor(String coin) {
    final symbol = coin.toUpperCase();
    return [
      for (final l in _labels.values)
        if (l.coin == symbol) l,
    ];
  }

  @visibleForTesting
  Future<void> load() async {
    try {
      final stored = await _read();
      if (stored == null) {
        unawaited(log(LogLevel.error, 'Address labels could not be read; not saving over them.'));
        return;
      }
      _labels = {for (final l in stored) l.key: l};
      _loaded = true;
      notifyListeners();
    } catch (e) {
      unawaited(log(LogLevel.error, 'Error loading address labels: $e'));
    }
  }

  /// Labels [address] on [coin]. A blank [label] removes the label. Longer
  /// than [maxAddressLabelLength], it is cut to that.
  Future<void> setLabel(String coin, String address, String label) async {
    final trimmed = label.trim();
    final text = trimmed.length > maxAddressLabelLength
        ? trimmed.substring(0, maxAddressLabelLength).trimRight()
        : trimmed;
    final key = addressLabelKey(coin, address);
    if (text.isEmpty) {
      if (_labels.remove(key) == null) return;
    } else {
      final updated = AddressLabel(coin: coin.toUpperCase(), address: address, label: text);
      if (_labels[key] == updated) return;
      _labels[key] = updated;
    }
    notifyListeners();
    try {
      await _store();
    } catch (_) {
      // Logged by _store. The label stays in memory and the next save writes it.
    }
  }

  /// Writes the labels, then lets a metadata backup record the change. Throws
  /// when nothing was written.
  Future<void> _store() async {
    if (!_loaded) {
      unawaited(log(LogLevel.error, 'Refusing to save address labels that were not read.'));
      throw StateError('Refusing to save address labels that were not read');
    }
    try {
      await _write(_labels.values.toList());
    } catch (e) {
      unawaited(log(LogLevel.error, 'Error saving address labels: $e'));
      rethrow;
    }
    MetadataBackup.instance?.addressLabelsChanged();
  }

  /// Changes merged in from a metadata backup; see [AddressLabelsSync]. Throws
  /// when they were not stored, so the backup does not count them as this
  /// device's labels.
  Future<void> _applyRemote(Map<String, AddressLabel?> changes) async {
    if (!_loaded) {
      final stored = await _read();
      if (stored == null) {
        throw StateError('Address labels unreadable; backup changes not applied');
      }
      await _write(applyAddressLabelChanges(stored, changes));
      await load();
      return;
    }
    for (final e in changes.entries) {
      final label = e.value;
      if (label == null) {
        _labels.remove(e.key);
      } else {
        _labels[e.key] = label;
      }
    }
    notifyListeners();
    await _store();
  }

  /// Deletes every label: the user's own "Delete Address Labels". A metadata
  /// backup that syncs to a location records the removals there too
  /// ([MetadataBackup.addressLabelsChanged]).
  ///
  /// Unlike an edit, it may write over labels that could not be read: the user
  /// asked for all of them to go.
  Future<void> deleteAll() async {
    _labels = {};
    _loaded = true;
    notifyListeners();
    try {
      await _store();
    } catch (_) {
      // Logged by _store.
    }
  }

  /// The wallet was deleted ([clearAddressLabels]): what is in memory goes too,
  /// and the next wallet starts from an empty, saveable store.
  void _cleared() {
    _labels = {};
    _loaded = true;
    notifyListeners();
  }
}
