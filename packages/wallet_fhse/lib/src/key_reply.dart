import 'dart:convert';
import 'dart:typed_data';

import 'fhse_vault.dart' show KeyAssertion;
import 'security_key_service.dart' show SecurityKeyException, SecurityKeyFailure;

/// What a backend read from the key, before anything in it is believed.
///
/// Every platform reaches the key its own way, but what the key answered is
/// checked once, here, by [checkEnrollment] and [checkAssertion]. So a key, a
/// platform or a future backend cannot pass with some checks and not others.
class KeyReply {
  const KeyReply({
    required this.credentialId,
    required this.hmacSecret,
    required this.authenticatorData,
    this.creationAuthenticatorData,
    this.serial,
  });

  /// The credential the key answered with. A key may leave it out when only
  /// one was asked for; the backend then reports that one.
  final Uint8List credentialId;

  /// The hmac-secret output, decrypted.
  final Uint8List hmacSecret;

  /// The authenticator data of the getAssertion that produced [hmacSecret].
  final Uint8List authenticatorData;

  /// Enrollment only: the authenticator data of the makeCredential.
  final Uint8List? creationAuthenticatorData;

  /// The key's serial number, when the platform can read one (a YubiKey's).
  final int? serial;
}

/// The parts of CTAP2 authenticator data the checks read.
class AuthenticatorData {
  const AuthenticatorData({
    required this.flags,
    required this.extensions,
    this.attestedCredentialId,
  });

  /// rpIdHash (32 bytes), then the flags byte.
  final int flags;

  /// The extension outputs, by name.
  final Map<Object?, Object?> extensions;

  /// The new credential's id, in makeCredential's authenticator data.
  final Uint8List? attestedCredentialId;

  static const flagUserVerified = 0x04;
  static const flagAttestedCredential = 0x40;
  static const flagExtensions = 0x80;

  bool get userVerified => flags & flagUserVerified != 0;

  /// Parses [data]: rpIdHash (32), flags (1), signCount (4), then the
  /// attested credential (aaguid, id length, id, COSE key) when flagged, then
  /// the extensions map when flagged. Throws [FormatException] on anything
  /// short, malformed or with bytes left over.
  static AuthenticatorData parse(Uint8List data) {
    try {
      final flags = data[32];
      final reader = _Cbor(data, 37);
      Uint8List? credentialId;
      if (flags & flagAttestedCredential != 0) {
        // aaguid (16 bytes), credential id length (2), credential id.
        final length = data[53] << 8 | data[54];
        if (55 + length > data.length) throw const FormatException('credential id overrun');
        credentialId = Uint8List.fromList(data.sublist(55, 55 + length));
        reader.pos = 55 + length;
        reader.read(); // The COSE public key.
      }
      var extensions = const <Object?, Object?>{};
      if (flags & flagExtensions != 0) {
        final map = reader.read();
        if (map is! Map<Object?, Object?>) throw const FormatException('extensions not a map');
        extensions = map;
      }
      if (reader.pos != data.length) throw const FormatException('trailing bytes');
      return AuthenticatorData(
        flags: flags,
        extensions: extensions,
        attestedCredentialId: credentialId,
      );
    } on RangeError {
      throw const FormatException('truncated authenticator data');
    }
  }
}

const _hmacSecretLength = 32;
const _credProtectUvRequired = 0x03;

/// Checks a new credential, then the hmac-secret read from it.
///
/// The key must have verified the user, applied credProtect level 3 and
/// enabled hmac-secret, as FHSE asks; and the secret must come from that very
/// credential. Anything else is refused, whatever the platform said.
KeyAssertion checkEnrollment(KeyReply reply) {
  final creation = reply.creationAuthenticatorData;
  if (creation == null) throw _unsupported('The platform returned no data for the new credential');
  final created = _parse(creation);
  if (!created.userVerified) throw _unsupported('The security key did not verify the user');
  if (created.extensions['credProtect'] != _credProtectUvRequired) {
    throw _unsupported('credProtect not applied');
  }
  if (created.extensions['hmac-secret'] != true) {
    throw _unsupported('hmac-secret not enabled for the new credential');
  }
  final id = created.attestedCredentialId;
  if (id == null || id.isEmpty) throw _unknown('The security key returned no credential');
  return checkAssertion(reply, allowed: [id]);
}

/// Checks an hmac-secret read from one of [allowed]: the key verified the user
/// for it (without that, the key answers from its other, non-UV secret), the
/// answer came from a credential that was asked for, and it is 32 bytes.
KeyAssertion checkAssertion(KeyReply reply, {required List<Uint8List> allowed}) {
  final asserted = _parse(reply.authenticatorData);
  if (!asserted.userVerified) {
    throw _unsupported('The security key did not verify the user for this assertion');
  }
  if (reply.hmacSecret.length != _hmacSecretLength) {
    throw _unsupported('The security key returned no 32-byte hmac-secret output');
  }
  if (!allowed.any((id) => _equal(id, reply.credentialId))) {
    throw _unknown('The security key answered with a credential it was not asked for');
  }
  return KeyAssertion(
    credentialId: Uint8List.fromList(reply.credentialId),
    hmacSecret: Uint8List.fromList(reply.hmacSecret),
    serial: reply.serial,
  );
}

AuthenticatorData _parse(Uint8List data) {
  try {
    return AuthenticatorData.parse(data);
  } on FormatException {
    throw _unsupported('The security key returned malformed authenticator data');
  }
}

bool _equal(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

SecurityKeyException _unsupported(String message) =>
    SecurityKeyException(SecurityKeyFailure.unsupported, message: message);

SecurityKeyException _unknown(String message) =>
    SecurityKeyException(SecurityKeyFailure.unknown, message: message);

/// A reader for the CBOR in authenticator data. Definite lengths only, as
/// CTAP2's canonical encoding requires.
final class _Cbor {
  _Cbor(this.bytes, this.pos);

  final Uint8List bytes;
  int pos;

  Object? read([int depth = 0]) {
    if (depth > 16) throw const FormatException('CBOR nested too deeply');
    final initial = bytes[pos++];
    final major = initial >> 5;
    final info = initial & 0x1f;
    var arg = info;
    if (info >= 24) {
      final length = switch (info) {
        24 => 1,
        25 => 2,
        26 => 4,
        27 => 8,
        _ => throw const FormatException('indefinite or reserved CBOR length'),
      };
      arg = 0;
      for (var i = 0; i < length; i++) {
        arg = arg << 8 | bytes[pos++];
      }
    }
    switch (major) {
      case 0:
        return arg;
      case 1:
        return -1 - arg;
      case 2 || 3:
        if (arg < 0 || pos + arg > bytes.length) throw const FormatException('CBOR overrun');
        final data = bytes.sublist(pos, pos + arg);
        pos += arg;
        return major == 3 ? utf8.decode(data) : data;
      case 4:
        return [for (var i = 0; i < arg; i++) read(depth + 1)];
      case 5:
        return {for (var i = 0; i < arg; i++) read(depth + 1): read(depth + 1)};
      case 6:
        return read(depth + 1); // A tag: its content.
      default:
        return switch (info) {
          20 => false,
          21 => true,
          22 || 23 => null,
          _ => arg, // A simple value or the bits of a float.
        };
    }
  }
}
