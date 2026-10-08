import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fhse/wallet_fhse.dart';

import 'support/host_library.dart';

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  final skip = useHostLibrary();

  // FHSE's own unit-test vector (tests/unit/fhse.test.cpp on the
  // implement-fhse-concept branch): the same root from this build of the
  // library as from the reference CMake build with system libsodium.
  test('root for a known seed matches the FHSE test vector', () {
    expect(
      FhseSecret.rootZ85ForSeed(bytes('dummy seed 1 for fhse unit tests')),
      'YLf%t+F+#OOO+/UoEq+@gd7{+jwB+d=JnBWA8>&&',
    );
  }, skip: skip);

  test('create, add keys, store, open and unlock with either key', () {
    final seed = WalletKeyTree.random(32);
    final password = bytes('outer password');
    final key1 = WalletKeyTree.random(32);
    final key2 = WalletKeyTree.random(32);

    final created = FhseSecret.create(password: password, seed: seed);
    final root = created.rootZ85;
    expect(root, hasLength(40));
    expect(root, FhseSecret.rootZ85ForSeed(seed));
    expect(created.fidoUserId, hasLength(64));
    expect(created.fidoSalt, hasLength(32));

    created.addKey(credentialId: bytes('cred one'), hmacSecret: key1);
    created.addKey(credentialId: bytes('cred two'), hmacSecret: key2);
    expect(
      () => created.addKey(credentialId: bytes('cred three'), hmacSecret: key1),
      throwsA(isA<FhseException>().having((e) => e.code, 'code', FhseException.duplicateKey)),
    );
    final blob = created.store();
    final salt = created.fidoSalt;
    created.dispose();
    created.dispose(); // idempotent

    final opened = FhseSecret.open(blob, password: password);
    expect(opened.fidoSalt, salt);
    expect(opened.credentialIds.map(utf8.decode), unorderedEquals(['cred one', 'cred two']));
    expect(() => opened.rootZ85, throwsA(isA<FhseException>()));
    expect(
      () => opened.unlock(WalletKeyTree.random(32)),
      throwsA(isA<FhseException>().having((e) => e.code, 'code', FhseException.keyUnavailable)),
    );
    opened.unlock(key2);
    expect(opened.rootZ85, root);
    opened.dispose();
  }, skip: skip);

  test('the wrong outer password fails cleanly', () {
    final secret = FhseSecret.create(password: bytes('right'), seed: WalletKeyTree.random(32));
    secret.addKey(credentialId: bytes('cred'), hmacSecret: WalletKeyTree.random(32));
    final blob = secret.store();
    secret.dispose();
    expect(
      () => FhseSecret.open(blob, password: bytes('wrong')),
      throwsA(isA<FhseException>().having((e) => e.code, 'code', FhseException.decryptionFailure)),
    );
  }, skip: skip);

  test('inputs of the wrong length are refused', () {
    expect(
      () => FhseSecret.create(password: bytes('p'), seed: Uint8List(31)),
      throwsA(isA<FhseException>()),
    );
    final secret = FhseSecret.create(password: bytes('p'));
    expect(
      () => secret.addKey(credentialId: bytes('cred'), hmacSecret: Uint8List(16)),
      throwsA(isA<FhseException>().having((e) => e.code, 'code', FhseException.badArgument)),
    );
    // FHSE stores no file without a key.
    expect(() => secret.store(), throwsA(isA<FhseException>()));
    secret.dispose();
  }, skip: skip);

  test('no seed gives a random root', () {
    final a = FhseSecret.create(password: bytes('p'));
    final b = FhseSecret.create(password: bytes('p'));
    expect(a.rootZ85, isNot(b.rootZ85));
    a.dispose();
    b.dispose();
  }, skip: skip);
}
