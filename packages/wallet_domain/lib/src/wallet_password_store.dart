import 'dart:io';

import 'package:wallet_infra/wallet_infra.dart';

import 'stores/seed_store.dart';
import 'wallet_password_guard.dart';

/// Where the wallet password is kept between sessions, and how the user gets
/// it back. One kind per platform, picked by [current]:
///
/// - [KeystorePasswordStore] (Android, iOS, macOS): nobody types the password.
///   It is generated, or derived from the seed when a [WalletPasswordGuard] is
///   installed, and a copy sits in the keystore behind the device's own lock.
/// - [TypedPasswordStore] (Linux, Windows): the user types a password at every
///   start. A wallet made with a guard has a seed-derived password, whose copy
///   is kept in `wallet.key` encrypted with the typed one. An older wallet's
///   typed password is the wallet password, and nothing is kept.
///
/// A guard that engages removes the copy ([deleteCopy]), so only the guard
/// can release the password; releasing puts it back ([saveCopy]).
abstract class WalletPasswordStore {
  const WalletPasswordStore();

  /// The store for this platform, from [WalletSecrets.holdsWalletPassword].
  static WalletPasswordStore get current => WalletSecrets.holdsWalletPassword
      ? KeystorePasswordStore.instance
      : TypedPasswordStore.instance;

  /// The user types the password here (Linux, Windows).
  bool get typesPassword;

  /// The password the user typed, while it is held for this session. A guard
  /// uses it as its own password on Linux and Windows. Always null where
  /// nobody types one.
  String? get typedPassword => null;

  /// Keeps a copy of [walletPassword] for the next session: in the keystore,
  /// or encrypted with [typed] (default: the typed password held for this
  /// session). Called before any wallet file is written, so a refused copy
  /// leaves nothing encrypted under a password no one holds.
  Future<void> saveCopy(String walletPassword, {String? typed});

  /// The kept copy, where it can be read without the user (the keystore). Null
  /// when there is none, and always on Linux and Windows.
  Future<String?> readCopy();

  /// Removes the copy: a guard took over, the wallet is being deleted, or a
  /// copy was left behind.
  Future<void> deleteCopy();

  /// Opens the wallet with a password the user typed. With [guard] engaged it
  /// only checks the password, and the guard releases the wallet password
  /// later. Without a kept copy, the typed password is the wallet password,
  /// checked against the stored seed when there is one.
  Future<TypedUnlock> unlockTyped(String typed, {WalletPasswordGuard? guard}) async {
    if (await SeedStore.exists() && !await _opensSeed(typed)) {
      return const TypedUnlock.wrongPassword();
    }
    return TypedUnlock.unlocked(typed, walletPasswordIsTyped: true);
  }

  /// Forgets what is held for this session (the typed password): part of a
  /// full lock.
  void endSession() {}

  static Future<bool> _opensSeed(String password) async {
    try {
      return await SeedStore.load(password) != null;
    } catch (_) {
      return false;
    }
  }
}

/// Android, iOS and macOS: the copy is the keystore's.
class KeystorePasswordStore extends WalletPasswordStore {
  const KeystorePasswordStore._();

  static const instance = KeystorePasswordStore._();

  @override
  bool get typesPassword => false;

  @override
  Future<void> saveCopy(String walletPassword, {String? typed}) =>
      storeKeystoreWalletPassword(walletPassword);

  @override
  Future<String?> readCopy() => readKeystoreWalletPassword();

  @override
  Future<void> deleteCopy() => deleteKeystoreWalletPassword();
}

/// Linux and Windows: the user types a password, and no keystore is trusted
/// with a copy (on Linux it is readable by any process of the same user).
class TypedPasswordStore extends WalletPasswordStore {
  TypedPasswordStore._();

  static final instance = TypedPasswordStore._();

  static const wrapFileName = 'wallet.key';

  String? _typed;

  @override
  bool get typesPassword => true;

  @override
  String? get typedPassword => _typed;

  /// `wallet.key`, beside the wallet's files.
  static Future<File> wrapFile() async => File('${(await getAppDir()).path}/$wrapFileName');

  /// Writes `wallet.key` when the wallet password is not the typed one. When
  /// it is (a wallet made without a guard), nothing is kept: the user types it.
  @override
  Future<void> saveCopy(String walletPassword, {String? typed}) async {
    final key = typed ?? _typed;
    if (key == null) throw StateError('The typed password is not in memory');
    _typed = key;
    if (walletPassword == key) return;
    final blob = await WalletFileCrypto.encryptToBase64(
      walletPassword,
      key,
      iterations: WalletFileCrypto.typedPasswordIterations,
    );
    await writeStringAtomic(await wrapFile(), blob);
  }

  @override
  Future<String?> readCopy() async => null;

  @override
  Future<void> deleteCopy() async {
    final wrap = await wrapFile();
    if (await wrap.exists()) await wrap.delete();
  }

  @override
  Future<TypedUnlock> unlockTyped(String typed, {WalletPasswordGuard? guard}) async {
    // Keys on: the guard checks the typed password, then wants its own unlock.
    if (guard != null && await guard.isEngaged()) {
      if (!await guard.acceptsTypedPassword(typed)) return const TypedUnlock.wrongPassword();
      _typed = typed;
      return const TypedUnlock.engaged();
    }
    final wrap = await wrapFile();
    if (await wrap.exists()) {
      final String walletPassword;
      try {
        walletPassword = await WalletFileCrypto.decryptFromBase64(await wrap.readAsString(), typed);
      } on FormatException {
        return const TypedUnlock.wrongPassword();
      }
      _typed = typed;
      return TypedUnlock.unlocked(walletPassword);
    }
    final opened = await super.unlockTyped(typed);
    if (opened.kind != TypedUnlockKind.unlocked) return opened;
    _typed = typed;
    // Earlier builds also wrote the typed password to the keystore, which
    // Linux and Windows never read back.
    try {
      await deleteKeystoreWalletPassword();
    } catch (e) {
      log(LogLevel.error, '[WalletPasswordStore] Failed to delete stored password: $e');
    }
    return opened;
  }

  @override
  void endSession() => _typed = null;

  /// Test helper.
  void resetForTesting() => _typed = null;
}

/// What a typed password opened ([WalletPasswordStore.unlockTyped]).
class TypedUnlock {
  /// The typed password is not this wallet's.
  const TypedUnlock.wrongPassword()
    : kind = TypedUnlockKind.wrongPassword,
      walletPassword = null,
      walletPasswordIsTyped = false;

  /// The typed password opened [walletPassword]: the copy in `wallet.key`, or
  /// the typed password itself for an older wallet ([walletPasswordIsTyped]).
  const TypedUnlock.unlocked(String this.walletPassword, {this.walletPasswordIsTyped = false})
    : kind = TypedUnlockKind.unlocked;

  /// The typed password is right, and a guard is engaged: it releases the
  /// wallet password only once it is also unlocked its own way (for
  /// `wallet_fhse`, a security key and its PIN).
  const TypedUnlock.engaged()
    : kind = TypedUnlockKind.engaged,
      walletPassword = null,
      walletPasswordIsTyped = false;

  final TypedUnlockKind kind;
  final String? walletPassword;

  /// The wallet password is the one the user typed, so files under it need
  /// the typed-password cost.
  final bool walletPasswordIsTyped;
}

enum TypedUnlockKind { wrongPassword, unlocked, engaged }
