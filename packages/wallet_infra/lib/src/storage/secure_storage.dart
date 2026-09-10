import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Platform keystore access, for the wallet password and nothing else.
///
/// What actually protects these values differs sharply by platform:
///
///  - **Android**: `EncryptedSharedPreferences`, master key in the Android
///    Keystore, hardware-backed on most devices and non-exportable.
///  - **iOS / macOS**: Keychain at `AfterFirstUnlockThisDeviceOnly`, so the
///    value is excluded from iCloud Keychain and device backups. A restored
///    backup has the wallet file but not its key; recovery is seed-only.
///  - **Windows**: values are AES-GCM files on disk; only a 16-byte key lives
///    in Credential Manager. Readable by any process running as that user.
///  - **Linux**: libsecret's default login keyring, which is normally unlocked
///    automatically at session login; worth roughly file permissions against
///    a same-user attacker. Every key shares one JSON blob, so writes are
///    read-modify-write and race.
///
/// `LinuxOptions` and `WindowsOptions` stay at their defaults; neither exposes
/// anything worth setting. The Linux weakness is inherent to Secret Service, not
/// a missing option.
const _androidOptions = AndroidOptions(encryptedSharedPreferences: true);
const _appleOptions = IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device);
const _macOptions = MacOsOptions(accessibility: KeychainAccessibility.first_unlock_this_device);

const secureStorage = FlutterSecureStorage(
  aOptions: _androidOptions,
  iOptions: _appleOptions,
  mOptions: _macOptions,
);
