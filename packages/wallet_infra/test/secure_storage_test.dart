import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// Stands in for the macOS keychain plugin. The data-protection keychain
/// refuses every call with [refusal], as it does a build that is not
/// team-signed; the login keychain works. Records which one each call asked.
class _FakeKeychain {
  _FakeKeychain({this.refusal = -34018});

  final int refusal;
  final asked = <String>[];
  final login = <String, String>{};

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, Object?>();
    final options = (args['options'] as Map).cast<String, String>();
    final dataProtection = options['useDataProtectionKeyChain'] == 'true';
    asked.add(dataProtection ? 'data-protection' : 'login');
    if (dataProtection) {
      throw PlatformException(code: 'Unexpected security result code', details: refusal);
    }
    final key = args['key'] as String?;
    switch (call.method) {
      case 'write':
        login[key!] = args['value'] as String;
        return null;
      case 'read':
        return login[key];
      case 'containsKey':
        return login.containsKey(key);
      case 'delete':
        login.remove(key);
        return null;
      case 'readAll':
        return Map.of(login);
      case 'deleteAll':
        login.clear();
        return null;
    }
    throw MissingPluginException(call.method);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _FakeKeychain install(_FakeKeychain keychain) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      keychain.handle,
    );
    return keychain;
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    );
    resetKeychainFallbackForTesting();
  });

  // Tests run as a debug build. That a release build never falls back rests on
  // the kDebugMode check alone, which a test cannot switch off.
  test(
    'a debug build refused the data-protection keychain moves to the login keychain',
    () async {
      final keychain = install(_FakeKeychain());

      await secureStorage.write(key: 'k', value: 'v');
      expect(await secureStorage.read(key: 'k'), 'v');
      expect(await secureStorage.containsKey(key: 'k'), isTrue);
      await secureStorage.delete(key: 'k');
      expect(await secureStorage.readAll(), isEmpty);

      // Refused once, then every call goes straight to the login keychain.
      expect(keychain.asked, ['data-protection', 'login', 'login', 'login', 'login', 'login']);
    },
    skip: Platform.isMacOS ? false : 'the fallback exists on macOS only',
  );

  test(
    'any other keychain error is thrown, not a reason to fall back',
    () async {
      // errSecInteractionNotAllowed: a locked keychain, not a missing entitlement.
      final keychain = install(_FakeKeychain(refusal: -25308));

      await expectLater(
        secureStorage.write(key: 'k', value: 'v'),
        throwsA(isA<PlatformException>().having((e) => e.details, 'details', -25308)),
      );
      expect(keychain.asked, ['data-protection']);
      expect(keychain.login, isEmpty);
    },
    skip: Platform.isMacOS ? false : 'the fallback exists on macOS only',
  );
}
