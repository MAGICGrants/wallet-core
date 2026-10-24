import 'dart:typed_data';

import 'package:wallet_fhse/wallet_fhse.dart';

/// A stand-in for one FIDO2 key holding non-discoverable hmac-secret
/// credentials: each has a random id and a random secret, and its output for a
/// salt is a keyed hash of the salt. Not CTAP2; just the property FHSE uses.
class FakeSecurityKey implements SecurityKeyAuthenticator {
  FakeSecurityKey({this.pin = '123456', this.fingerprint = false, this.serial});

  final String pin;

  /// What the key reports as its serial number, if anything.
  int? serial;

  /// A YubiKey Bio with a fingerprint enrolled: built-in verification works.
  final bool fingerprint;
  final Map<String, Uint8List> _credentials = {};
  int enrollCalls = 0;
  int assertionCalls = 0;

  static String _hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  Uint8List _output(Uint8List secret, Uint8List salt) =>
      WalletKeyTree.hashPersonal(Uint8List.fromList([...secret, ...salt]), 'FAKE-HMACSECRET1');

  /// Either way the key verifies its owner, so the output is the same.
  void _verify(KeyVerification verification) {
    if (verification.isBuiltIn) {
      if (!fingerprint) throw StateError('uvNotConfigured');
    } else if (verification.pin != pin) {
      throw StateError('wrong PIN');
    }
  }

  @override
  Future<KeyAssertion> enroll({
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
  }) async {
    enrollCalls++;
    _verify(verification);
    if (excludeCredentialIds.any((id) => _credentials.containsKey(_hex(id)))) {
      throw StateError('credentialExcluded');
    }
    final id = WalletKeyTree.random(64);
    final secret = WalletKeyTree.random(32);
    _credentials[_hex(id)] = secret;
    return KeyAssertion(credentialId: id, hmacSecret: _output(secret, salt), serial: serial);
  }

  @override
  Future<KeyAssertion> getHmacSecret({
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
  }) async {
    assertionCalls++;
    _verify(verification);
    for (final id in credentialIds) {
      final secret = _credentials[_hex(id)];
      if (secret != null) {
        return KeyAssertion(credentialId: id, hmacSecret: _output(secret, salt), serial: serial);
      }
    }
    throw StateError('noCredentials');
  }
}
