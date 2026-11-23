import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:wallet_infra/wallet_infra.dart';

import 'address_label.dart';

/// Storage for address labels.
///
/// A label says what one of the wallet's own addresses was given out for
/// ("Rent", "Donations"), so it belongs to the wallet, not to the device. The
/// labels are one file beside the wallet's own, `${appDir}/address_labels`: a
/// JSON array of [AddressLabel] maps, encrypted with the wallet password
/// (AES-256-GCM via [WalletFileCrypto]) like the stored seed. So they can be
/// read only while the wallet is unlocked ([AddressLabelKey]), they go with the
/// app's folder on uninstall and stay out of device backups, and restoring the
/// wallet from its seed brings them back from the metadata backup. The address
/// book, which belongs to no wallet, stays in the keystore.
///
/// Builds before this kept the labels in the keystore under `addressLabels`;
/// the first read with the password moves them into the file.
const _fileName = 'address_labels';
const _legacyStorageKey = 'addressLabels';

Future<File> _file() async => File('${(await getAppDir()).path}/$_fileName');

/// The labels file's path, for the security-key upgrade to copy before it
/// re-keys the wallet's files ([rekeyAddressLabels]).
Future<String> addressLabelsPath() async => (await _file()).path;

/// The key the labels file is under: the wallet password, which
/// `WalletManager` hands over while the wallet is unlocked and takes back when
/// it locks. Null while locked, when the labels cannot be read or written.
abstract final class AddressLabelKey {
  static String? _password;

  static String? get password => _password;

  static set password(String? value) {
    if (value == _password) return;
    final wasAvailable = _password != null;
    _password = value;
    // A new password (the security-key upgrade) changes nothing readable: the
    // file was re-keyed to it first.
    if (wasAvailable != (value != null)) AddressLabelsSync._keyChanged?.call(value != null);
  }

  /// For tests: forgets the password without telling an open model.
  static void resetForTesting() => _password = null;
}

/// Reads every label, or null if they could not be read: the wallet is locked,
/// or the file does not open under [password] (the wallet password when not
/// given).
///
/// **Null is not the same as empty** — the same rule as `readEncodedContacts`:
/// a store that failed to read and is then saved over as empty loses every
/// label for good.
Future<List<AddressLabel>?> readAddressLabels({String? password}) async {
  final key = password ?? AddressLabelKey.password;
  if (key == null) return null;
  final String body;
  try {
    final file = await _file();
    if (!await file.exists()) return await _moveFromKeystore(key);
    final blob = await file.readAsString();
    // Captured out here: static state does not cross into the spawned isolate.
    final kdf = WalletFileCrypto.kdf;
    body = await Isolate.run(() => WalletFileCrypto.decryptFromBase64(blob, key, kdf: kdf));
  } catch (e) {
    // The type only: a decryption or IO error says nothing a label does.
    unawaited(log(LogLevel.error, 'Could not read address labels: ${e.runtimeType}'));
    return null;
  }
  return _decode(body);
}

/// Encrypts [labels] under [password] (the wallet password when not given)
/// and replaces the file. Throws while the wallet is locked.
Future<void> writeAddressLabels(List<AddressLabel> labels, {String? password}) async {
  final key = password ?? AddressLabelKey.password;
  if (key == null) throw StateError('Address labels cannot be saved while the wallet is locked');
  final body = json.encode([for (final l in labels) l.toJson()]);
  final iterations = WalletFileCrypto.walletPasswordIterations;
  final kdf = WalletFileCrypto.kdf;
  final blob = await Isolate.run(
    () => WalletFileCrypto.encryptToBase64(body, key, iterations: iterations, kdf: kdf),
  );
  await writeStringAtomic(await _file(), blob);
}

/// Re-encrypts the labels file from [from] to [to], for the security-key
/// upgrade, which moves every file under the wallet password to a new one.
/// Throws when the file does not open under [from], so the upgrade is put back
/// rather than leave labels nothing can read.
Future<void> rekeyAddressLabels({required String from, required String to}) async {
  if (!await (await _file()).exists()) return;
  final labels = await readAddressLabels(password: from);
  if (labels == null) throw StateError('Address labels do not open under the old password');
  await writeAddressLabels(labels, password: to);
}

/// Deletes every stored label, and empties an open `AddressLabelModel`, which
/// would otherwise write them back with its next save. For a wallet being
/// deleted, and for a new one set up over labels an older build left in the
/// keystore, which outlives an uninstall on iOS.
Future<void> clearAddressLabels() async {
  try {
    final file = await _file();
    if (await file.exists()) await file.delete();
  } catch (e) {
    unawaited(log(LogLevel.error, 'Could not delete the address labels file: ${e.runtimeType}'));
  }
  try {
    await WalletSecrets.store.delete(_legacyStorageKey);
  } catch (e) {
    unawaited(log(LogLevel.error, 'Could not clear address labels: ${e.runtimeType}'));
  }
  AddressLabelsSync._cleared?.call();
}

/// The labels an older build kept in the keystore, moved into the file under
/// [key]. Empty when there were none; null when they could not be read, so
/// nothing is saved over them.
Future<List<AddressLabel>?> _moveFromKeystore(String key) async {
  final String? stored;
  try {
    stored = await WalletSecrets.store.read(_legacyStorageKey);
  } catch (e) {
    unawaited(log(LogLevel.error, 'Could not read address labels: ${e.runtimeType}'));
    return null;
  }
  if (stored == null || stored.isEmpty) return [];
  final labels = _decode(stored);
  if (labels == null) return null;
  await writeAddressLabels(labels, password: key);
  await WalletSecrets.store.delete(_legacyStorageKey);
  return labels;
}

List<AddressLabel>? _decode(String body) {
  try {
    return [
      for (final entry in json.decode(body) as List<dynamic>)
        AddressLabel.fromJson(entry as Map<String, dynamic>),
    ];
  } catch (e) {
    // The type only: a FormatException quotes the text it failed on.
    unawaited(log(LogLevel.error, 'Address labels are unreadable: ${e.runtimeType}'));
    return null;
  }
}

/// Applies label changes merged in from a metadata backup, the way
/// `ContactsSync` does for the address book: through an open
/// `AddressLabelModel` when there is one, so an edit made at the same moment
/// lands on top, else to storage directly.
abstract final class AddressLabelsSync {
  static Future<void> Function(Map<String, AddressLabel?> changes)? _model;
  static void Function()? _cleared;
  static void Function(bool available)? _keyChanged;

  /// Installed by `AddressLabelModel`; the last one constructed wins.
  /// [onKeyChanged] hears the wallet unlock (true) and lock (false).
  static void attach(
    Future<void> Function(Map<String, AddressLabel?> changes) model, {
    required void Function() onCleared,
    void Function(bool available)? onKeyChanged,
  }) {
    _model = model;
    _cleared = onCleared;
    _keyChanged = onKeyChanged;
  }

  static void detach(Future<void> Function(Map<String, AddressLabel?> changes) model) {
    if (_model != model) return;
    _model = null;
    _cleared = null;
    _keyChanged = null;
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
