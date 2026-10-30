import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../fhse_vault.dart' show KeyVerification, SecurityKeyAuthenticator;
import '../security_key_service.dart' show SecurityKeyService;

/// A check, on real keys, that every backend gets the same hmac-secret from a
/// credential: Yubico's SDKs on Android, iOS and macOS, libfido2 on Linux,
/// `webauthn.dll` on Windows, and libfido2's own tools (`tool/hmac_parity.sh`).
///
/// A key's hmac-secret depends only on the credential, the salt and whether
/// the user was verified (CTAP 2.1 §12.5). FHSE always verifies the user, so
/// one credential and one salt must give the same 32 bytes on every platform;
/// a backend that hashed or re-encoded the salt on the way would show up here.
///
/// The salt is a fixed, published value ([salt]), never a wallet's: a wallet's
/// FIDO2 salt is random and secret inside `wallet.fhse`. An hmac-secret over
/// this salt says nothing about one over any other, so the output can be
/// shown and compared even for a credential a wallet also uses. Debug builds
/// only (Settings > Advanced Security); see test/README.md.
class HmacParity {
  HmacParity(this._authenticator);

  final SecurityKeyAuthenticator _authenticator;

  /// What [salt] is the SHA-256 of. Bump the version to change the salt.
  static const saltLabel = 'FHSE hmac-secret parity test v1';

  /// SHA-256([saltLabel]), as `tool/hmac_parity.sh` has it too.
  static const saltBase64 = 'gTFyG6+HfGxYT7lGePmQn/fqYUkoYcGNzfxWPW3nLkk=';

  static Uint8List get salt => base64Decode(saltBase64);

  /// Creates a throwaway credential, as FHSE enrolls one (non-discoverable,
  /// hmac-secret, credProtect 3, user verified), and reads its hmac-secret
  /// over [salt].
  Future<HmacParityResult> enroll(KeyVerification verification) async {
    final assertion = await _authenticator.enroll(
      userId: _randomUserId(),
      salt: salt,
      verification: verification,
      excludeCredentialIds: const [],
    );
    return HmacParityResult(credentialId: assertion.credentialId, hmacSecret: assertion.hmacSecret);
  }

  /// Reads the hmac-secret over [salt] from [credentialId], made here, on
  /// another device, or by `tool/hmac_parity.sh`.
  Future<HmacParityResult> assertCredential(
    Uint8List credentialId,
    KeyVerification verification,
  ) async {
    final assertion = await _authenticator.getHmacSecret(
      salt: salt,
      verification: verification,
      credentialIds: [credentialId],
    );
    return HmacParityResult(credentialId: assertion.credentialId, hmacSecret: assertion.hmacSecret);
  }

  /// A throwaway FIDO2 user id, the length FHSE's are (64 bytes). It plays no
  /// part in the hmac-secret.
  static Uint8List _randomUserId() {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(64, (_) => random.nextInt(256)));
  }

  /// A credential id as pasted: base64 (standard or URL-safe, padded or not)
  /// or hex. Null when it is neither.
  static Uint8List? parseCredentialId(String text) {
    final compact = text.replaceAll(RegExp(r'\s'), '');
    if (compact.isEmpty) return null;
    if (compact.length.isEven && RegExp(r'^[0-9a-fA-F]+$').hasMatch(compact)) {
      return Uint8List.fromList([
        for (var i = 0; i < compact.length; i += 2)
          int.parse(compact.substring(i, i + 2), radix: 16),
      ]);
    }
    try {
      final standard = compact.replaceAll('-', '+').replaceAll('_', '/');
      return base64Decode(base64.normalize(standard));
    } on FormatException {
      return null;
    }
  }

  /// Which backend this platform's [SecurityKeyService] uses, for the report.
  static String get platformBackend {
    if (Platform.isAndroid) return 'android (yubikit-android)';
    if (Platform.isIOS) return 'ios (YubiKit Swift)';
    if (Platform.isMacOS) return 'macos (YubiKit Swift)';
    if (Platform.isLinux) return 'linux (libfido2)';
    if (Platform.isWindows) return 'windows (webauthn.dll)';
    return Platform.operatingSystem;
  }
}

/// One parity reading, in the line format `tool/hmac_parity.sh` prints, so
/// the two can be compared line by line.
class HmacParityResult {
  const HmacParityResult({required this.credentialId, required this.hmacSecret});

  final Uint8List credentialId;
  final Uint8List hmacSecret;

  String report({String? backend}) => [
    'backend: ${backend ?? HmacParity.platformBackend}',
    'rp: ${SecurityKeyService.rpId}',
    'salt: ${HmacParity.saltBase64}',
    'credential: ${base64Encode(credentialId)}',
    'hmac-secret: ${base64Encode(hmacSecret)}',
  ].join('\n');

  /// The same reading from libfido2, for this credential.
  String get libfido2Command => "sh tool/hmac_parity.sh assert '${base64Encode(credentialId)}'";
}
