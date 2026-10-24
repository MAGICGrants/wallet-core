import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_infra/wallet_infra.dart';

/// App Lock is always on: the gates in front of the seed and secret keys always
/// ask the device who is holding it. The one exception is a device with no lock
/// at all, which has nothing to ask.
///
/// Under `flutter test` local_auth talks over its default method channel, which
/// stands in for the device here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/local_auth');

  late List<String> asked;

  void device({Object? authenticate, bool hasLock = true}) {
    asked = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async {
        asked.add(call.method);
        switch (call.method) {
          case 'authenticate':
            if (authenticate is Exception) throw authenticate;
            return authenticate;
          case 'isDeviceSupported':
            return hasLock;
        }
        return null;
      },
    );
  }

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  group('confirmOwner', () {
    test('asks, and passes when the owner confirms', () async {
      device(authenticate: true);
      expect(
        await BiometricAuth.confirmOwner(reason: 'reveal the seed'),
        BiometricAuthResult.authenticated,
      );
      expect(asked, ['authenticate']);
    });

    test('a declined prompt fails', () async {
      device(authenticate: false);
      expect(
        await BiometricAuth.confirmOwner(reason: 'reveal the seed'),
        BiometricAuthResult.failed,
      );
    });

    test('a device with a lock it cannot use right now (a lockout) is not let in', () async {
      device(authenticate: PlatformException(code: 'LockedOut'));
      expect(
        await BiometricAuth.confirmOwner(reason: 'reveal the seed'),
        BiometricAuthResult.error,
      );
      expect(asked, ['authenticate', 'isDeviceSupported']);
    });

    test('a device with no lock at all has nothing to ask: it passes', () async {
      device(authenticate: PlatformException(code: 'NotAvailable'), hasLock: false);
      expect(
        await BiometricAuth.confirmOwner(reason: 'reveal the seed'),
        BiometricAuthResult.authenticated,
      );
    });

    test('when the device cannot say whether it has a lock, it is not let in', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'broken'),
      );
      // A failed check is never read as "no lock": that would be a way in.
      expect(
        await BiometricAuth.confirmOwner(reason: 'reveal the seed'),
        BiometricAuthResult.error,
      );
      expect(await BiometricAuth.isAvailable(), isTrue);
    });
  });
}
