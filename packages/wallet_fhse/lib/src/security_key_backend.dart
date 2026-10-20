import 'dart:async';
import 'dart:typed_data';

import 'fhse_vault.dart' show KeyVerification;
import 'key_reply.dart';
import 'security_key_service.dart'
    show SecurityKeyException, SecurityKeyFailure, SecurityKeyInfo, SecurityKeyStatus;

/// One way this process reaches a FIDO2 key. [SecurityKeyService] picks one
/// per platform:
///
/// - Android, iOS, macOS: a platform channel to Yubico's SDKs.
/// - Linux: the system's libfido2 (`LinuxLibFido2Backend`), which the app
///   drives step by step, PIN included, as on Android.
/// - Windows: Windows' own WebAuthn API (`WindowsWebAuthnBackend`), whose
///   Windows Security dialog asks for the PIN or fingerprint and the touch
///   itself ([systemPrompts]).
///
/// Every call verifies the user. [enroll] creates a non-discoverable credential
/// for `rpId` with the hmac-secret extension and credProtect level 3, and
/// reads its hmac-secret over the salt, taken with user verification;
/// [getHmacSecret] reads the same secret later. Both return what the key sent
/// as a [KeyReply], which `SecurityKeyService` checks the same way for every
/// backend ([checkEnrollment], [checkAssertion]). Every failure is a
/// [SecurityKeyException] carrying one of [SecurityKeyFailure]'s codes.
abstract class SecurityKeyBackend {
  /// What the key is waiting for while an operation runs.
  Stream<SecurityKeyStatus> get status;

  /// The operating system draws the security-key prompts (PIN, touch) and the
  /// app does not: Windows. The app then skips its own steps and passes
  /// [KeyVerification.system].
  bool get systemPrompts;

  Future<({bool nfc, bool usb})> capabilities();

  /// Waits for a key and reads what it supports. With [touch], a plugged-in
  /// key is also asked for a touch, so the user picks the key they mean.
  /// [prompt] is the iOS NFC sheet's text; other backends ignore it.
  Future<SecurityKeyInfo> inspect({required bool touch, required String prompt});

  /// Sets the PIN of a key that has none. With [expectSerial], a different key
  /// is refused before anything is sent to it.
  Future<void> setPin(String newPin, {int? expectSerial, required String prompt});

  /// Creates the credential and reads its hmac-secret over [salt], with both
  /// authenticator data. Fails with [SecurityKeyFailure.credentialExcluded]
  /// when the key already holds one of [excludeCredentialIds].
  Future<KeyReply> enroll({
    required String rpId,
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
    int? expectSerial,
    required String prompt,
  });

  /// The hmac-secret over [salt] from whichever of [credentialIds] the key
  /// holds, with the assertion's authenticator data. Fails with
  /// [SecurityKeyFailure.noCredentials] when it holds none.
  Future<KeyReply> getHmacSecret({
    required String rpId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
    int? expectSerial,
    required String prompt,
  });

  /// Stops the operation under way, which then fails with
  /// [SecurityKeyFailure.cancelled]. Does nothing when none is.
  Future<void> cancel();
}
