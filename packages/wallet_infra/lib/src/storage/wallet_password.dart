import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'secure_storage.dart';

/// Key under which the wallet password is stored. Must not change; it is what
/// the shipped apps already wrote.
const walletPasswordStorageKey = 'walletPassword';

/// Keystore-backed secret storage, behind an interface.
///
/// Injected for the same reason as `DirectoryProvider` and `PreferenceStore`:
/// `flutter_secure_storage` is a plugin, so anything calling it directly cannot
/// run under `flutter test`. Everything that opens a wallet reads the password
/// through here, so leaving it unmockable would make the whole manager need a
/// device.
///
/// It is also the seam to change if a platform's keystore turns out to need
/// something stronger; for example deriving from the typed password on Linux
/// rather than trusting an auto-unlocked keyring.
abstract class SecretStore {
  const SecretStore();

  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// Production implementation: the platform keystore.
class KeychainSecretStore extends SecretStore {
  const KeychainSecretStore();

  @override
  Future<void> write(String key, String value) => secureStorage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => secureStorage.read(key: key);

  @override
  Future<void> delete(String key) => secureStorage.delete(key: key);
}

// `MemorySecretStore` lives in `package:wallet_infra/testing.dart`.

/// The installed secret store.
class WalletSecrets {
  WalletSecrets._();

  static SecretStore store = const KeychainSecretStore();

  /// Whether [store] keeps the wallet password on this platform.
  ///
  /// True on Android and iOS, the iOS build on a Mac included: the password is
  /// minted at onboarding, nobody types it, and it lives in the keystore behind
  /// App Lock when that is on. False on Linux, Windows and macOS, where the user
  /// types it at every launch and it is held in memory only. A stored copy there
  /// would make typing it unnecessary: for the app, and on Windows and Linux for
  /// any process running as the same user (see `secureStorage`). The same split
  /// as `WalletFileCrypto.defaultIterations`, and for the same reason.
  static bool holdsWalletPassword = _platformHoldsWalletPassword;

  static void resetForTesting() {
    store = const KeychainSecretStore();
    holdsWalletPassword = _platformHoldsWalletPassword;
  }
}

final bool _platformHoldsWalletPassword = Platform.isAndroid || Platform.isIOS;

/// Mints a random wallet password: 16 bytes from [Random.secure], hex-encoded.
///
/// 128 bits of full entropy, which is why `WalletFileCrypto` uses a lower
/// PBKDF2 count on mobile: there is no brute-force surface to defend here.
String genWalletPassword() {
  final rand = Random.secure();
  final bytes = Uint8List.fromList(List<int>.generate(16, (_) => rand.nextInt(256)));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

Future<void> storeMobileWalletPassword(String password) =>
    WalletSecrets.store.write(walletPasswordStorageKey, password);

Future<String?> getMobileWalletPassword() => WalletSecrets.store.read(walletPasswordStorageKey);

Future<void> deleteMobileWalletPassword() => WalletSecrets.store.delete(walletPasswordStorageKey);
