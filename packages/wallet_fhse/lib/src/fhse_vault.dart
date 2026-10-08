import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'fhse_native.dart';
import 'fhse_secret.dart';
import 'wallet_key_tree.dart';

/// What a FIDO2 key answered: the credential it used and its 32-byte
/// hmac-secret over FHSE's salt.
class KeyAssertion {
  const KeyAssertion({required this.credentialId, required this.hmacSecret, this.serial});

  final Uint8List credentialId;
  final Uint8List hmacSecret;

  /// The key's serial number, when it has one the app can read (a YubiKey's).
  final int? serial;

  /// Overwrites the secret once FHSE has used it.
  void wipe() => hmacSecret.fillRange(0, hmacSecret.length, 0);
}

/// How the key verifies its owner for one call: the key's PIN, or the key's own
/// fingerprint reader (a YubiKey Bio). Either sets CTAP's user-verified flag,
/// so either gives the same hmac-secret: a key enrolled with its PIN opens with
/// its fingerprint, and the other way round.
class KeyVerification {
  const KeyVerification.pin(String this.pin);
  const KeyVerification.builtIn() : pin = null;

  /// Null for [KeyVerification.builtIn].
  final String? pin;

  bool get isBuiltIn => pin == null;

  @override
  String toString() => isBuiltIn ? 'KeyVerification.builtIn' : 'KeyVerification.pin';
}

/// The app's way to a FIDO2 key. Skylight implements it with a platform
/// channel to Yubico's SDKs.
///
/// Both calls must verify the user ([KeyVerification]): enrollment creates a
/// credential with credProtect level 3 (user verification required) and the
/// hmac-secret is always taken with user verification, so the verified secret
/// is the one both sides use.
abstract class SecurityKeyAuthenticator {
  /// Creates a non-discoverable hmac-secret credential for [userId] and returns
  /// its hmac-secret over [salt]. Fails if the key already holds one of
  /// [excludeCredentialIds].
  Future<KeyAssertion> enroll({
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
  });

  /// The hmac-secret over [salt] from whichever of [credentialIds] the key
  /// holds.
  Future<KeyAssertion> getHmacSecret({
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
  });
}

/// An enrolled key as the settings screen lists it. FHSE stores only
/// credential ids; the names are this app's, kept in the keystore.
class SecurityKeyRecord {
  const SecurityKeyRecord({
    required this.id,
    required this.name,
    required this.addedAt,
    this.serial,
  });

  /// A digest of the credential id, so the label store holds no credential.
  final String id;
  final String name;
  final DateTime addedAt;

  /// The key's serial number (a YubiKey's is printed on it). Lets the app tell
  /// which key is connected before its PIN is asked for, which FIDO itself
  /// cannot: credProtect level 3 hides the credential until the PIN is in.
  final int? serial;

  SecurityKeyRecord withName(String name) =>
      SecurityKeyRecord(id: id, name: name, addedAt: addedAt, serial: serial);

  SecurityKeyRecord withSerial(int? serial) =>
      SecurityKeyRecord(id: id, name: name, addedAt: addedAt, serial: serial);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'addedAt': addedAt.toIso8601String(),
    if (serial != null) 'serial': serial,
  };

  static SecurityKeyRecord fromJson(Map<String, dynamic> json) => SecurityKeyRecord(
    id: json['id'] as String,
    name: json['name'] as String,
    addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
    serial: json['serial'] as int?,
  );
}

/// The vault failed for a reason the user can act on.
class FhseVaultException implements Exception {
  const FhseVaultException(this.reason);

  final FhseVaultFailure reason;

  @override
  String toString() => 'FhseVaultException(${reason.name})';
}

enum FhseVaultFailure {
  /// The wallet predates this build, so it has no FHSE seed and its password
  /// is not FHSE's root.
  notAvailable,

  /// The key answered, but it is not one of this wallet's keys.
  keyNotEnrolled,

  /// The key is already one of the keys being set up.
  keyAlreadyAdded,

  /// The recovery phrase is not this wallet's.
  wrongRecoveryPhrase,

  /// This wallet's FHSE seed is random (a 25-word seed), so the recovery
  /// phrase cannot rebuild its password.
  recoveryNotPossible,

  /// The files on disk are damaged or out of step.
  corrupt,
}

/// FHSE guarding the wallet password, for one wallet.
///
/// **Before any key is enrolled** (the state onboarding leaves): the wallet
/// password is FHSE's root, `k_p`, derived from the seed by [WalletKeyTree],
/// and it sits in the keystore as the random password used to. The FHSE seed
/// `s_f` is kept on disk encrypted under it, so security keys can be set up at
/// any later point without the recovery phrase.
///
/// **Once keys are enrolled** ([isEngaged]): the FHSE file holds the root
/// wrapped once per key, under an outer password that is a random secret in
/// the keystore. The keystore holds no wallet password; opening the wallet
/// needs a key and its PIN or fingerprint ([unlock]).
///
/// Files, beside the wallet's in the app directory:
///  - `wallet.fhse`: the FHSE file. Kept on this device; nothing it protects
///    needs it for recovery, which is the seed's job.
///  - `fhse_seed`: `s_f`, encrypted with the wallet password.
class FhseVault {
  FhseVault._();

  static const _blobName = 'wallet.fhse';
  static const _seedName = 'fhse_seed';
  static const outerPasswordKey = 'fhseOuterPassword';
  static const keyLabelsKey = 'fhseKeyLabels';

  /// The unlocked file, for adding keys during this session. Dropped by
  /// [endSession] on a full lock.
  static FhseSecret? _session;

  /// `s_f` between [passwordForNewWallet] and [walletCreated].
  static Uint8List? _pendingSeed;

  static Future<File> _file(String name) async => File('${(await getAppDir()).path}/$name');

  // ----- Onboarding (through FhseWalletGuard) -----

  /// The password for a new wallet: FHSE's root for the wallet's FHSE seed.
  static Future<String> passwordForNewWallet(SeedSource seed) async {
    final sf = await WalletKeyTree.fhseSeedFor(seed);
    _pendingSeed?.fillRange(0, _pendingSeed!.length, 0);
    _pendingSeed = sf;
    return FhseSecret.rootZ85ForSeed(sf);
  }

  /// Persists the FHSE seed under the wallet's [password].
  static Future<void> walletCreated(String password) async {
    final sf = _pendingSeed;
    if (sf == null) throw StateError('walletCreated without passwordForNewWallet');
    try {
      await _writeSeed(sf, password);
    } finally {
      sf.fillRange(0, sf.length, 0);
      _pendingSeed = null;
    }
  }

  static Future<void> _writeSeed(Uint8List sf, String password) async {
    final blob = await WalletFileCrypto.encryptToBase64(base64.encode(sf), password);
    await _writeAtomic(await _file(_seedName), utf8.encode(blob));
  }

  static Future<Uint8List> _readSeed(String password) async {
    final file = await _file(_seedName);
    if (!await file.exists()) throw const FhseVaultException(FhseVaultFailure.notAvailable);
    final plain = await WalletFileCrypto.decryptFromBase64(await file.readAsString(), password);
    return Uint8List.fromList(base64.decode(plain));
  }

  // ----- State -----

  /// Whether security keys can be set up: the wallet was created on a build
  /// whose password is FHSE's root.
  static Future<bool> isAvailable() async => (await _file(_seedName)).exists();

  /// Whether keys are enrolled and the keystore no longer holds the password.
  static Future<bool> isEngaged() async => (await _file(_blobName)).exists();

  /// The enrolled keys, in enrollment order.
  static Future<List<SecurityKeyRecord>> keys() async {
    final blob = await _readBlob();
    if (blob == null) return const [];
    final secret = FhseSecret.open(blob, password: await _outerPassword());
    try {
      // FHSE reverses its key list on every load, so the file's order means
      // nothing; list in enrollment order, from the labels.
      final labels = await _labels();
      final order = {for (final (i, r) in labels.indexed) r.id: i};
      final byId = {for (final r in labels) r.id: r};
      final ids = [for (final id in secret.credentialIds) labelId(id)]
        ..sort((a, b) => (order[a] ?? labels.length).compareTo(order[b] ?? labels.length));
      return [
        for (var i = 0; i < ids.length; i++)
          byId[ids[i]] ??
              SecurityKeyRecord(id: ids[i], name: 'Security key ${i + 1}', addedAt: DateTime(0)),
      ];
    } finally {
      secret.dispose();
    }
  }

  // ----- Unlock -----

  /// Opens the FHSE file with a key, verified by [verification], and returns
  /// the wallet password. The unlocked file is kept for this session so more keys can be
  /// added without tapping an existing one again.
  static Future<String> unlock({
    required SecurityKeyAuthenticator authenticator,
    required KeyVerification verification,
  }) async {
    final blob = await _readBlob();
    if (blob == null) throw const FhseVaultException(FhseVaultFailure.notAvailable);
    final secret = FhseSecret.open(blob, password: await _outerPassword());
    try {
      final assertion = await authenticator.getHmacSecret(
        salt: secret.fidoSalt,
        verification: verification,
        credentialIds: secret.credentialIds,
      );
      try {
        secret.unlock(assertion.hmacSecret);
      } on FhseException catch (e) {
        if (e.code == FhseException.keyUnavailable) {
          throw const FhseVaultException(FhseVaultFailure.keyNotEnrolled);
        }
        rethrow;
      } finally {
        assertion.wipe();
      }
      final password = secret.rootZ85;
      _replaceSession(secret);
      await _rememberSerial(labelId(assertion.credentialId), assertion.serial);
      return password;
    } catch (_) {
      if (!identical(_session, secret)) secret.dispose();
      rethrow;
    }
  }

  /// The wallet password rebuilt from the recovery phrase, for when every key
  /// is lost. Works only where the FHSE seed comes from the seed
  /// ([WalletKeyTree.isSeedDerived]), and is checked against the stored FHSE
  /// seed so a different wallet's phrase is refused.
  static Future<String> recoverWithSeed(SeedSource seed) async {
    if (!WalletKeyTree.isSeedDerived(seed)) {
      throw const FhseVaultException(FhseVaultFailure.recoveryNotPossible);
    }
    final sf = await WalletKeyTree.fhseSeedFor(seed);
    try {
      final password = FhseSecret.rootZ85ForSeed(sf);
      final stored = await _readSeed(password).catchError(
        (Object _) => throw const FhseVaultException(FhseVaultFailure.wrongRecoveryPhrase),
      );
      stored.fillRange(0, stored.length, 0);
      return password;
    } finally {
      sf.fillRange(0, sf.length, 0);
    }
  }

  /// Whether this session holds the unlocked file, so [addKey] can work. False
  /// after an unlock with the recovery phrase: keys are then set up again.
  static bool get hasSession => _session != null;

  /// Drops the unlocked file: part of a full lock.
  static void endSession() {
    _session?.dispose();
    _session = null;
  }

  static void _replaceSession(FhseSecret secret) {
    if (identical(_session, secret)) return;
    _session?.dispose();
    _session = secret;
  }

  // ----- Setting keys up -----

  /// Starts setting keys up from nothing: the first time, and also to remove a
  /// key, by setting up again with only the keys to keep. Builds a new FHSE
  /// file from the same seed (so the same wallet password) with a new FIDO2
  /// user id and salt, so no credential from the old file opens it. Nothing
  /// on disk changes until [FhseSetup.commit].
  static Future<FhseSetup> beginSetup({required String walletPassword}) async {
    final Uint8List sf;
    try {
      sf = await _readSeed(walletPassword);
    } on FhseVaultException {
      rethrow;
    } catch (_) {
      throw const FhseVaultException(FhseVaultFailure.corrupt);
    }
    try {
      final secret = FhseSecret.create(password: await _outerPassword(create: true), seed: sf);
      if (secret.rootZ85 != walletPassword) {
        secret.dispose();
        throw const FhseVaultException(FhseVaultFailure.corrupt);
      }
      return FhseSetup._(secret);
    } finally {
      sf.fillRange(0, sf.length, 0);
    }
  }

  /// Enrolls one more key into the engaged file, using this session's
  /// unlocked copy.
  static Future<SecurityKeyRecord> addKey({
    required SecurityKeyAuthenticator authenticator,
    required KeyVerification verification,
    required String name,
  }) async {
    final secret = _session;
    if (secret == null) throw StateError('No unlocked FHSE file in this session');
    final record = await _enrollInto(
      secret,
      authenticator: authenticator,
      verification: verification,
      name: name,
    );
    await _writeAtomic(await _file(_blobName), secret.store());
    await _saveLabels([...await _labels(), record]);
    return record;
  }

  /// Keeps the serial of a key that has just proven itself, when its label has
  /// none yet (a key whose serial could not be read when it was added).
  static Future<void> _rememberSerial(String id, int? serial) async {
    if (serial == null) return;
    try {
      final labels = await _labels();
      final index = labels.indexWhere((r) => r.id == id);
      if (index < 0 || labels[index].serial != null) return;
      labels[index] = labels[index].withSerial(serial);
      await _saveLabels(labels);
    } catch (_) {
      // A label is a convenience; the unlock has already succeeded.
    }
  }

  /// Renames an enrolled key. Names are this app's, in the keystore; FHSE's
  /// file does not change.
  static Future<void> renameKey(String id, String name) async {
    final labels = await _labels();
    final index = labels.indexWhere((r) => r.id == id);
    if (index < 0) {
      // Labels lost (or never written): name it from now on.
      final known = (await keys()).where((r) => r.id == id);
      if (known.isEmpty) throw ArgumentError.value(id, 'id', 'not an enrolled key');
      labels.add(SecurityKeyRecord(id: id, name: name, addedAt: known.single.addedAt));
    } else {
      labels[index] = labels[index].withName(name);
    }
    await _saveLabels(labels);
  }

  static Future<SecurityKeyRecord> _enrollInto(
    FhseSecret secret, {
    required SecurityKeyAuthenticator authenticator,
    required KeyVerification verification,
    required String name,
  }) async {
    final assertion = await authenticator.enroll(
      userId: secret.fidoUserId,
      salt: secret.fidoSalt,
      verification: verification,
      excludeCredentialIds: secret.credentialIds,
    );
    try {
      secret.addKey(credentialId: assertion.credentialId, hmacSecret: assertion.hmacSecret);
    } on FhseException catch (e) {
      if (e.code == FhseException.duplicateKey) {
        throw const FhseVaultException(FhseVaultFailure.keyAlreadyAdded);
      }
      rethrow;
    } finally {
      assertion.wipe();
    }
    return SecurityKeyRecord(
      id: labelId(assertion.credentialId),
      name: name,
      addedAt: DateTime.now(),
      serial: assertion.serial,
    );
  }

  // ----- Turning keys off -----

  /// Removes the FHSE file and everything kept for it. The caller puts the
  /// wallet password back in the keystore first ([FhseWalletGuard.release]).
  static Future<void> deleteEngagement() async {
    endSession();
    final blob = await _file(_blobName);
    if (await blob.exists()) await blob.delete();
    await WalletSecrets.store.delete(keyLabelsKey);
  }

  /// Forgets everything, for a deleted wallet.
  static Future<void> deleteAll() async {
    await deleteEngagement();
    final seed = await _file(_seedName);
    if (await seed.exists()) await seed.delete();
    await WalletSecrets.store.delete(outerPasswordKey);
    _pendingSeed?.fillRange(0, _pendingSeed!.length, 0);
    _pendingSeed = null;
  }

  // ----- Storage helpers -----

  static Future<Uint8List?> _readBlob() async {
    final file = await _file(_blobName);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// The outer password: a random secret in this device's keystore, which
  /// keeps the FHSE file useless off this device. FHSE's outer layer uses
  /// libsodium's minimum Argon2id cost, which is fine for 256 random bits and
  /// would not be for a typed password. Kept across set-ups; each new file
  /// still gets a new FIDO2 salt.
  static Future<Uint8List> _outerPassword({bool create = false}) async {
    final stored = await WalletSecrets.store.read(outerPasswordKey);
    if (stored != null && stored.isNotEmpty) return Uint8List.fromList(utf8.encode(stored));
    if (!create) throw const FhseVaultException(FhseVaultFailure.corrupt);
    final fresh = base64.encode(WalletKeyTree.random(32));
    await WalletSecrets.store.write(outerPasswordKey, fresh);
    return Uint8List.fromList(utf8.encode(fresh));
  }

  static Future<List<SecurityKeyRecord>> _labels() async {
    final stored = await WalletSecrets.store.read(keyLabelsKey);
    if (stored == null || stored.isEmpty) return [];
    try {
      return [
        for (final e in jsonDecode(stored) as List<dynamic>)
          SecurityKeyRecord.fromJson(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveLabels(List<SecurityKeyRecord> records) =>
      WalletSecrets.store.write(keyLabelsKey, jsonEncode([for (final r in records) r.toJson()]));

  /// A label id for [credentialId]: a domain-separated digest, so the label
  /// store holds no credential.
  static String labelId(Uint8List credentialId) {
    final digest = WalletKeyTree.hashPersonal(credentialId, 'SKYPOC-KEYLABEL1');
    return digest.sublist(0, 16).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<void> _writeAtomic(File file, List<int> bytes) async {
    final tmp = File('${file.path}.new');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
  }
}

/// Keys being set up, from nothing: in memory until [commit].
class FhseSetup {
  FhseSetup._(this._secret);

  final FhseSecret _secret;
  final List<SecurityKeyRecord> _records = [];
  bool _done = false;

  List<SecurityKeyRecord> get keys => List.unmodifiable(_records);

  Future<SecurityKeyRecord> addKey({
    required SecurityKeyAuthenticator authenticator,
    required KeyVerification verification,
    required String name,
  }) async {
    if (_done) throw StateError('Setup already finished');
    final record = await FhseVault._enrollInto(
      _secret,
      authenticator: authenticator,
      verification: verification,
      name: name,
    );
    _records.add(record);
    return record;
  }

  /// Renames a key added in this setup. The name is asked for after the key
  /// has been touched, so it is set after [addKey].
  void rename(String id, String name) {
    final index = _records.indexWhere((r) => r.id == id);
    if (index < 0) throw ArgumentError.value(id, 'id', 'not a key in this setup');
    _records[index] = _records[index].withName(name);
  }

  /// Writes the new file over any old one, atomically, and keeps it unlocked
  /// for this session. Needs at least one key; FHSE stores no file without.
  Future<void> commit() async {
    if (_done) throw StateError('Setup already finished');
    if (_records.isEmpty) throw StateError('Add at least one key first');
    await FhseVault._writeAtomic(await FhseVault._file(FhseVault._blobName), _secret.store());
    await FhseVault._saveLabels(_records);
    _done = true;
    FhseVault._replaceSession(_secret);
  }

  void cancel() {
    if (_done) return;
    _done = true;
    _secret.dispose();
  }
}

/// [FhseVault] as wallet_domain's [WalletPasswordGuard], plus the two
/// transitions that move the password between the keystore and the keys.
class FhseWalletGuard extends WalletPasswordGuard {
  const FhseWalletGuard();

  @override
  Future<String> passwordForNewWallet(SeedSource seed) => FhseVault.passwordForNewWallet(seed);

  @override
  Future<void> walletCreated(String password) => FhseVault.walletCreated(password);

  @override
  Future<bool> isEngaged() => FhseVault.isEngaged();

  @override
  Future<void> walletDeleted() => FhseVault.deleteAll();

  /// Commits [setup] and, if keys were not already on, takes the password out
  /// of the keystore. Before that, every wallet keeps what an unattended run
  /// needs to check in without it (the background view-key path).
  static Future<void> engage(FhseSetup setup, WalletManager manager) async {
    final wasEngaged = await FhseVault.isEngaged();
    await setup.commit();
    if (wasEngaged) return;
    await manager.prepareViewOnlyAll();
    await deleteMobileWalletPassword();
  }

  /// Turns security keys off: the password goes back into the keystore before
  /// anything else is removed, so no step leaves the wallet unopenable.
  static Future<void> release(WalletManager manager) async {
    final password = manager.passwordForGuard;
    if (password == null) throw StateError('The wallet must be unlocked to turn security keys off');
    await storeMobileWalletPassword(password);
    await FhseVault.deleteEngagement();
    await manager.forgetViewOnlyAll();
  }
}
