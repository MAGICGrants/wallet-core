import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fhse/src/key_reply.dart';
import 'package:wallet_fhse/wallet_fhse.dart';

/// The checks every platform's reply goes through, against hand-built CTAP2
/// authenticator data.
const _up = 0x01;
const _uv = 0x04;
const _at = 0x40;
const _ed = 0x80;

/// An ES256 COSE public key: {1: 2, 3: -7, -1: 1, -2: x, -3: y}.
final _coseKey = [
  0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, //
  0x21, 0x58, 0x20, ...List.filled(32, 0x0a),
  0x22, 0x58, 0x20, ...List.filled(32, 0x0b),
];

List<int> _text(String s) => [0x60 | s.length, ...utf8.encode(s)];

/// The extension outputs of a makeCredential: credProtect and hmac-secret.
List<int> _extensions({int credProtect = 3, bool hmacSecret = true}) => [
  0xa2,
  ..._text('credProtect'),
  credProtect,
  ..._text('hmac-secret'),
  hmacSecret ? 0xf5 : 0xf4,
];

Uint8List _authData({required int flags, Uint8List? credentialId, List<int>? extensions}) {
  final b = BytesBuilder()
    ..add(List.filled(32, 0x11)) // rpIdHash
    ..addByte(flags)
    ..add([0, 0, 0, 1]); // signCount
  if (credentialId != null) {
    b
      ..add(List.filled(16, 0)) // aaguid
      ..add([credentialId.length >> 8, credentialId.length & 0xff])
      ..add(credentialId)
      ..add(_coseKey);
  }
  if (extensions != null) b.add(extensions);
  return b.toBytes();
}

final _id = Uint8List.fromList(List.generate(48, (i) => i));
final _otherId = Uint8List.fromList(List.generate(48, (i) => 99 - i));
final _secret = Uint8List.fromList(List.filled(32, 0x5a));

Uint8List _created({int flags = _up | _uv | _at | _ed, int credProtect = 3, bool hmac = true}) =>
    _authData(
      flags: flags,
      credentialId: _id,
      extensions: _extensions(credProtect: credProtect, hmacSecret: hmac),
    );

KeyReply _reply({
  Uint8List? creation,
  int assertionFlags = _up | _uv,
  Uint8List? credentialId,
  Uint8List? secret,
}) => KeyReply(
  credentialId: credentialId ?? _id,
  // Its own copy: checking a reply wipes the reply's secret.
  hmacSecret: Uint8List.fromList(secret ?? _secret),
  authenticatorData: _authData(flags: assertionFlags),
  creationAuthenticatorData: creation,
);

Matcher _fails(SecurityKeyFailure failure) =>
    throwsA(isA<SecurityKeyException>().having((e) => e.failure, 'failure', failure));

void main() {
  group('authenticator data', () {
    test('reads the flags, the new credential and the extension outputs', () {
      final parsed = AuthenticatorData.parse(_created());
      expect(parsed.flags, _up | _uv | _at | _ed);
      expect(parsed.userVerified, isTrue);
      expect(parsed.attestedCredentialId, _id);
      expect(parsed.extensions, {'credProtect': 3, 'hmac-secret': true});
    });

    test('has no extensions without the ED flag', () {
      final parsed = AuthenticatorData.parse(_authData(flags: _up | _uv));
      expect(parsed.extensions, isEmpty);
      expect(parsed.attestedCredentialId, isNull);
    });

    test('rejects truncated or padded data, and a flag with nothing behind it', () {
      final good = _created();
      expect(
        () => AuthenticatorData.parse(Uint8List.sublistView(good, 0, 100)),
        throwsFormatException,
      );
      expect(
        () => AuthenticatorData.parse(Uint8List.fromList([...good, 0])),
        throwsFormatException,
      );
      expect(() => AuthenticatorData.parse(_authData(flags: _uv | _ed)), throwsFormatException);
      expect(() => AuthenticatorData.parse(Uint8List(10)), throwsFormatException);
    });
  });

  group('enrollment', () {
    test('a new credential with UV, credProtect 3 and hmac-secret passes', () {
      final assertion = checkEnrollment(_reply(creation: _created()));
      expect(assertion.credentialId, _id);
      expect(assertion.hmacSecret, _secret);
      expect(identical(assertion.hmacSecret, _secret), isFalse, reason: 'a copy to wipe');
    });

    test('refuses a creation the platform did not report', () {
      expect(() => checkEnrollment(_reply()), _fails(SecurityKeyFailure.unsupported));
    });

    test('refuses a creation without user verification', () {
      expect(
        () => checkEnrollment(_reply(creation: _created(flags: _up | _at | _ed))),
        _fails(SecurityKeyFailure.unsupported),
      );
    });

    test('refuses credProtect below 3: the credential would open with a touch alone', () {
      expect(
        () => checkEnrollment(_reply(creation: _created(credProtect: 2))),
        _fails(SecurityKeyFailure.unsupported),
      );
    });

    test('refuses a credential without hmac-secret', () {
      expect(
        () => checkEnrollment(_reply(creation: _created(hmac: false))),
        _fails(SecurityKeyFailure.unsupported),
      );
      expect(
        () => checkEnrollment(
          _reply(
            creation: _authData(flags: _up | _uv | _at, credentialId: _id),
          ),
        ),
        _fails(SecurityKeyFailure.unsupported),
        reason: 'no extensions at all',
      );
    });

    test('refuses a secret that came from another credential', () {
      expect(
        () => checkEnrollment(_reply(creation: _created(), credentialId: _otherId)),
        _fails(SecurityKeyFailure.unknown),
      );
    });

    test('refuses malformed creation data', () {
      final short = Uint8List.sublistView(_created(), 0, 60);
      expect(
        () => checkEnrollment(_reply(creation: short)),
        _fails(SecurityKeyFailure.unsupported),
      );
    });
  });

  group('assertion', () {
    test('a verified answer from an asked-for credential passes', () {
      final assertion = checkAssertion(_reply(), allowed: [_otherId, _id]);
      expect(assertion.credentialId, _id);
      expect(assertion.hmacSecret, _secret);
    });

    test('refuses an answer without user verification: it is the non-UV secret', () {
      expect(
        () => checkAssertion(_reply(assertionFlags: _up), allowed: [_id]),
        _fails(SecurityKeyFailure.unsupported),
      );
    });

    test('refuses an answer from a credential that was not asked for', () {
      expect(
        () => checkAssertion(_reply(credentialId: _otherId), allowed: [_id]),
        _fails(SecurityKeyFailure.unknown),
      );
    });

    test("wipes the reply's own copy of the secret, passed or refused", () {
      final passed = _reply();
      final assertion = checkAssertion(passed, allowed: [_id]);
      expect(assertion.hmacSecret, _secret);
      expect(passed.hmacSecret.every((b) => b == 0), isTrue);

      final refused = _reply(credentialId: _otherId);
      expect(() => checkAssertion(refused, allowed: [_id]), _fails(SecurityKeyFailure.unknown));
      expect(refused.hmacSecret.every((b) => b == 0), isTrue);
    });

    test('refuses a secret that is not 32 bytes', () {
      expect(
        () => checkAssertion(_reply(secret: Uint8List(31)), allowed: [_id]),
        _fails(SecurityKeyFailure.unsupported),
      );
      expect(
        () => checkAssertion(_reply(secret: Uint8List(0)), allowed: [_id]),
        _fails(SecurityKeyFailure.unsupported),
      );
    });
  });
}
