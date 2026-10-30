import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../logging.dart';

/// Platform keystore access, for the wallet password and nothing else.
///
/// What actually protects these values differs sharply by platform:
///
///  - **Android**: `EncryptedSharedPreferences`, master key in the Android
///    Keystore, hardware-backed on most devices and non-exportable.
///  - **iOS**: Keychain at `AfterFirstUnlockThisDeviceOnly`, so the
///    value never syncs to iCloud Keychain and never moves to another device.
///    Encrypted device backups do carry it, wrapped with this device's
///    hardware key, so a backup restored to the *same* phone brings it back.
///    That is why the files it opens are kept out of device backups on iOS
///    (`getAppDir`, `excludeFromDeviceBackup`): a restored phone has neither,
///    and recovery is seed-only.
///  - **macOS**: the data-protection keychain, at the same accessibility, so
///    the value is held to this Mac's keychain and its app, not iCloud's. Only
///    a build signed by an Apple team with a provisioning profile can use it;
///    see [_Keystore] for debug builds that are not. The files it opens are
///    kept out of Time Machine, as on iOS.
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
const _macOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
  useDataProtectionKeyChain: true,
);

/// The user's login keychain, for [_Keystore]'s debug fallback only.
const _loginKeychainOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
  useDataProtectionKeyChain: false,
);

const FlutterSecureStorage secureStorage = _Keystore();

/// What the data-protection keychain returns to a build with no
/// application identifier, such as an ad-hoc signed one.
const _errSecMissingEntitlement = -34018;

/// Set once a debug build on macOS has been refused the data-protection
/// keychain; from then on every call goes to the login keychain.
bool _loginKeychainInUse = false;

/// Forgets that the fallback was taken.
@visibleForTesting
void resetKeychainFallbackForTesting() => _loginKeychainInUse = false;

/// [FlutterSecureStorage] with one exception, for local testing on a Mac.
///
/// A debug build on macOS that is not team-signed gets
/// `errSecMissingEntitlement` from every data-protection keychain call, and
/// then uses the user's login keychain instead. That keychain is much weaker
/// for an ad-hoc signed app: any process running as the same user reads the
/// item without a prompt, and Time Machine and Migration Assistant copy it.
/// So a release or profile build never falls back; it fails, and onboarding
/// stops before writing any wallet file (`WalletManager.restoreAll`).
class _Keystore extends FlutterSecureStorage {
  const _Keystore()
    : super(aOptions: _androidOptions, iOptions: _appleOptions, mOptions: _macOptions);

  Future<T> _call<T>(
    Future<T> Function(MacOsOptions? mOptions) call,
    MacOsOptions? mOptions,
  ) async {
    if (_loginKeychainInUse) return call(_loginKeychainOptions);
    try {
      return await call(mOptions);
    } on PlatformException catch (e) {
      if (!kDebugMode || !Platform.isMacOS || e.details != _errSecMissingEntitlement) rethrow;
      log(
        LogLevel.warn,
        '[SecureStorage] This debug build is not team-signed; using the login keychain',
      );
      _loginKeychainInUse = true;
      return call(_loginKeychainOptions);
    }
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _call(
    (m) => super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: m,
      wOptions: wOptions,
    ),
    mOptions,
  );

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _call(
    (m) => super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: m,
      wOptions: wOptions,
    ),
    mOptions,
  );

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _call(
    (m) => super.containsKey(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: m,
      wOptions: wOptions,
    ),
    mOptions,
  );

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _call(
    (m) => super.delete(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: m,
      wOptions: wOptions,
    ),
    mOptions,
  );

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _call(
    (m) => super.readAll(
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: m,
      wOptions: wOptions,
    ),
    mOptions,
  );

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _call(
    (m) => super.deleteAll(
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: m,
      wOptions: wOptions,
    ),
    mOptions,
  );
}
