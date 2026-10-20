import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:wallet_infra/wallet_infra.dart' show HostPlatform, LogLevel, log;

import 'backends/linux_libfido2.dart';
import 'backends/windows_webauthn.dart';
import 'fhse_vault.dart' show KeyAssertion, KeyVerification, SecurityKeyAuthenticator;
import 'key_reply.dart';
import 'security_key_backend.dart';

/// Why a security-key operation failed, as the native side reports it.
///
/// The codes are the channel contract's; the native halves are this plugin's
/// android/src/main/kotlin/.../SecurityKeyOperations.kt and, on iOS and macOS,
/// apple/SecurityKeyOperations.swift (see README.md). The
/// Linux and Windows backends (lib/src/backends) report the same codes.
enum SecurityKeyFailure {
  cancelled,
  timeout,
  busy,
  pinNotSet,
  pinAlreadySet,
  pinInvalid,
  pinBlocked,
  pinAuthBlocked,
  pinPolicy,
  pinChangeRequired,
  uvInvalid,
  uvBlocked,
  uvNotConfigured,
  differentKey,

  /// Several security keys are plugged in and none could be chosen by touch
  /// (none can be asked, or one cannot be opened), so no PIN is sent to any.
  multipleKeys,
  noCredentials,
  credentialExcluded,
  unsupported,
  transport,
  unknown;

  static SecurityKeyFailure fromCode(String code) =>
      values.firstWhere((v) => v.name == code, orElse: () => unknown);
}

class SecurityKeyException implements Exception {
  const SecurityKeyException(this.failure, {this.message, this.retries});

  final SecurityKeyFailure failure;
  final String? message;

  /// Attempts left: PIN attempts with [SecurityKeyFailure.pinInvalid],
  /// fingerprint attempts with [SecurityKeyFailure.uvInvalid].
  final int? retries;

  @override
  String toString() =>
      'SecurityKeyException(${failure.name}${message == null ? '' : ': $message'})';
}

/// How a key is attached.
enum SecurityKeyTransport {
  usb,
  lightning,
  nfc;

  static SecurityKeyTransport? fromCode(Object? code) =>
      values.where((v) => v.name == code).firstOrNull;

  /// Plugged in, so it is touched rather than held to the phone.
  bool get isWired => this != nfc;
}

/// What the key is waiting for while an operation runs, as the native side
/// reports it. Drives the "touch your key" prompts.
enum SecurityKeyStatus {
  waitingForKey,
  keyConnected,
  processing,
  touchNeeded,
  fingerprintNeeded;

  static SecurityKeyStatus? fromCode(Object? code) =>
      values.where((v) => v.name == code).firstOrNull;
}

/// What the key reports about itself, before anything is enrolled.
class SecurityKeyInfo {
  const SecurityKeyInfo({
    required this.pinSet,
    required this.pinRetries,
    required this.supportsHmacSecret,
    required this.supportsCredProtect,
    required this.transport,
    this.serial,
    this.fingerprintReady = false,
    this.fingerprintRetries,
    this.minPinLength = 4,
    this.forcePinChange = false,
    this.touched = false,
  });

  final bool pinSet;
  final int? pinRetries;
  final bool supportsHmacSecret;
  final bool supportsCredProtect;
  final SecurityKeyTransport? transport;

  /// The YubiKey's serial number, which tells registered keys apart before
  /// any PIN. Null for other keys, or a YubiKey that hides it.
  final int? serial;

  /// A YubiKey Bio with a fingerprint enrolled, able to verify without the
  /// PIN (CTAP 2.1 built-in user verification).
  final bool fingerprintReady;
  final int? fingerprintRetries;
  final int minPinLength;

  /// The key wants its PIN changed before it will use it.
  final bool forcePinChange;

  /// The key was touched to select it (wired keys that support it).
  final bool touched;

  /// Whether the next step can skip the PIN.
  bool get canUseFingerprint => fingerprintReady && (fingerprintRetries ?? 1) > 0;
}

/// The FIDO2 key, through whatever reaches it on this platform
/// ([SecurityKeyBackend]): Yubico's SDKs on Android, iOS and macOS, the
/// system's libfido2 on Linux, and Windows' WebAuthn API on Windows.
///
/// FHSE needs raw CTAP2: a non-discoverable credential under the relying party
/// "fhse:encryption" with the hmac-secret extension, and later its output for
/// a 32-byte salt. Passkey APIs built for websites cannot do that (they insist
/// on a web domain and hash the salt), so the mobile platforms and Linux talk
/// CTAP2 to the key themselves, and the app draws the steps the system would
/// otherwise: connect, PIN, touch. Windows' own API passes the salt through
/// unhashed when asked to, so there the Windows Security dialog draws them
/// ([systemPrompts]). Every credential is created with credProtect level 3 and
/// every call verifies the user, with the key's PIN or a YubiKey Bio's
/// fingerprint, so a key found by someone else opens nothing.
class SecurityKeyService implements SecurityKeyAuthenticator {
  SecurityKeyService._(this._platformBackend) : _backend = _platformBackend;

  static final instance = SecurityKeyService._(_backendForThisPlatform());

  static SecurityKeyBackend _backendForThisPlatform() {
    if (Platform.isLinux) return LinuxLibFido2Backend();
    if (Platform.isWindows) {
      // Which enrollment path Windows took is still unknown on real keys, so
      // keep it in the app's log. Nothing secret is in these messages.
      WindowsWebAuthnBackend.debugLog ??= (message) => log(LogLevel.info, '[WebAuthn] $message');
      return WindowsWebAuthnBackend();
    }
    return _ChannelBackend();
  }

  final SecurityKeyBackend _platformBackend;
  SecurityKeyBackend _backend;

  /// Replaces the platform's backend, so a test can play Windows (or any
  /// other platform) on the host it runs on. Null restores it.
  @visibleForTesting
  set backendForTesting(SecurityKeyBackend? backend) => _backend = backend ?? _platformBackend;

  static const rpId = 'fhse:encryption';

  /// The channel the mobile and macOS halves answer on. On iOS and macOS the
  /// app's Swift registers it under this same name.
  static const channelName = 'org.magicgrants.wallet_fhse/security_key';

  /// What the key is waiting for, while an operation runs: a touch, a
  /// fingerprint, or to be connected again.
  Stream<SecurityKeyStatus> get status => _backend.status;

  /// The operating system asks for the PIN and the touch itself (Windows), so
  /// the app skips its own steps and verifies with [KeyVerification.system].
  bool get systemPrompts => _backend.systemPrompts;

  /// Shown in the iOS NFC sheet; nothing else has a system sheet for it.
  String nfcPrompt = 'Hold your security key near the top of your iPhone.';

  /// Security keys on this platform: phones, and the desktop OSes. Not the
  /// iPhone app running on a Mac, which has neither NFC nor the USB path.
  static bool get isSupportedPlatform =>
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isLinux ||
          Platform.isWindows) &&
      !HostPlatform.isIosAppOnMac;

  Future<({bool nfc, bool usb})> capabilities() => _backend.capabilities();

  /// Waits for a key and reads what it supports. With [touch], a plugged-in
  /// key is also asked for a touch, so the user picks the key they mean.
  Future<SecurityKeyInfo> inspect({bool touch = false}) =>
      _backend.inspect(touch: touch, prompt: nfcPrompt);

  /// Sets the PIN of a key that has none. With [expectSerial], a different
  /// key is refused before anything is sent to it.
  Future<void> setPin(String newPin, {int? expectSerial}) =>
      _backend.setPin(newPin, expectSerial: expectSerial, prompt: nfcPrompt);

  Future<void> cancel() => _backend.cancel();

  /// This service held to the key with [serial], the one the user touched in
  /// [inspect]: a different key is refused before any PIN reaches it, so a
  /// PIN meant for one key never costs another an attempt.
  SecurityKeyAuthenticator expecting(int? serial) =>
      serial == null ? this : _ExpectedKey(this, serial);

  @override
  Future<KeyAssertion> enroll({
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
  }) => _enroll(
    userId: userId,
    salt: salt,
    verification: verification,
    excludeCredentialIds: excludeCredentialIds,
  );

  @override
  Future<KeyAssertion> getHmacSecret({
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
  }) => _getHmacSecret(salt: salt, verification: verification, credentialIds: credentialIds);

  Future<KeyAssertion> _enroll({
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
    int? expectSerial,
  }) async => checkEnrollment(
    await _backend.enroll(
      rpId: rpId,
      userId: userId,
      salt: salt,
      verification: verification,
      excludeCredentialIds: excludeCredentialIds,
      expectSerial: expectSerial,
      prompt: nfcPrompt,
    ),
  );

  Future<KeyAssertion> _getHmacSecret({
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
    int? expectSerial,
  }) async => checkAssertion(
    await _backend.getHmacSecret(
      rpId: rpId,
      salt: salt,
      verification: verification,
      credentialIds: credentialIds,
      expectSerial: expectSerial,
      prompt: nfcPrompt,
    ),
    allowed: credentialIds,
  );
}

/// The platform channel to Yubico's SDKs: this plugin's Kotlin on Android, and
/// the app's own Swift on iOS and macOS (see README.md).
class _ChannelBackend implements SecurityKeyBackend {
  _ChannelBackend() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channel = MethodChannel(SecurityKeyService.channelName);

  final _status = StreamController<SecurityKeyStatus>.broadcast();

  @override
  Stream<SecurityKeyStatus> get status => _status.stream;

  @override
  bool get systemPrompts => false;

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'status') return;
    final args = call.arguments;
    final status = args is Map ? SecurityKeyStatus.fromCode(args['state']) : null;
    if (status != null) _status.add(status);
  }

  Future<T> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args) as T;
    } on PlatformException catch (e) {
      throw SecurityKeyException(
        SecurityKeyFailure.fromCode(e.code),
        message: e.message,
        retries: e.details is int ? e.details as int : null,
      );
    }
  }

  @override
  Future<({bool nfc, bool usb})> capabilities() async {
    final result = await _call<Map<Object?, Object?>>('capabilities');
    return (nfc: result['nfc'] == true, usb: result['usb'] == true);
  }

  @override
  Future<SecurityKeyInfo> inspect({required bool touch, required String prompt}) async {
    final result = await _call<Map<Object?, Object?>>('inspect', {
      'prompt': prompt,
      'touch': touch,
    });
    return SecurityKeyInfo(
      pinSet: result['pinSet'] == true,
      pinRetries: result['pinRetries'] as int?,
      supportsHmacSecret: result['hmacSecret'] == true,
      supportsCredProtect: result['credProtect'] == true,
      transport: SecurityKeyTransport.fromCode(result['transport']),
      serial: result['serial'] as int?,
      fingerprintReady: result['uv'] == true && result['pinUvAuthToken'] == true,
      fingerprintRetries: result['uvRetries'] as int?,
      minPinLength: result['minPinLength'] as int? ?? 4,
      forcePinChange: result['forcePinChange'] == true,
      touched: result['touched'] == true,
    );
  }

  @override
  Future<void> setPin(String newPin, {int? expectSerial, required String prompt}) =>
      _call<void>('setPin', {'newPin': newPin, 'expectSerial': expectSerial, 'prompt': prompt});

  @override
  Future<void> cancel() => _call<void>('cancel');

  @override
  Future<KeyReply> enroll({
    required String rpId,
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
    int? expectSerial,
    required String prompt,
  }) async {
    final result = await _call<Map<Object?, Object?>>('enroll', {
      'rpId': rpId,
      'userId': userId,
      'salt': salt,
      ..._verification(verification),
      'excludeCredentialIds': excludeCredentialIds,
      'expectSerial': expectSerial,
      'prompt': prompt,
    });
    return _reply(result);
  }

  @override
  Future<KeyReply> getHmacSecret({
    required String rpId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
    int? expectSerial,
    required String prompt,
  }) async {
    final result = await _call<Map<Object?, Object?>>('getHmacSecret', {
      'rpId': rpId,
      'salt': salt,
      ..._verification(verification),
      'credentialIds': credentialIds,
      'expectSerial': expectSerial,
      'prompt': prompt,
    });
    return _reply(result);
  }

  static Map<String, Object?> _verification(KeyVerification verification) {
    if (verification.isSystem) {
      throw const SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: 'no system security-key prompt on this platform',
      );
    }
    return verification.isBuiltIn
        ? {'verification': 'uv'}
        : {'verification': 'pin', 'pin': verification.pin};
  }

  static KeyReply _reply(Map<Object?, Object?> result) {
    final credentialId = result['credentialId'];
    final hmacSecret = result['hmacSecret'];
    final authenticatorData = result['authenticatorData'];
    final creation = result['creationAuthenticatorData'];
    if (credentialId is! Uint8List ||
        hmacSecret is! Uint8List ||
        authenticatorData is! Uint8List ||
        (creation != null && creation is! Uint8List)) {
      throw const SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: 'malformed key response',
      );
    }
    // Copies: the engine hands channel replies over as unmodifiable views, and
    // KeyAssertion.wipe() overwrites hmacSecret in place. (The reply buffer
    // itself cannot be overwritten; it is freed with the message.)
    return KeyReply(
      credentialId: Uint8List.fromList(credentialId),
      hmacSecret: Uint8List.fromList(hmacSecret),
      authenticatorData: Uint8List.fromList(authenticatorData),
      creationAuthenticatorData: creation == null
          ? null
          : Uint8List.fromList(creation as Uint8List),
      serial: result['serial'] as int?,
    );
  }
}

/// [SecurityKeyService.expecting]: the same key calls, refusing any key but
/// the one with [serial].
class _ExpectedKey implements SecurityKeyAuthenticator {
  const _ExpectedKey(this._service, this.serial);

  final SecurityKeyService _service;
  final int serial;

  @override
  Future<KeyAssertion> enroll({
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
  }) => _service._enroll(
    userId: userId,
    salt: salt,
    verification: verification,
    excludeCredentialIds: excludeCredentialIds,
    expectSerial: serial,
  );

  @override
  Future<KeyAssertion> getHmacSecret({
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
  }) => _service._getHmacSecret(
    salt: salt,
    verification: verification,
    credentialIds: credentialIds,
    expectSerial: serial,
  );
}
