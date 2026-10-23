import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fhse/security_keys_ui.dart';
import 'package:wallet_fhse/src/key_reply.dart';
import 'package:wallet_fhse/src/security_key_backend.dart';
import 'package:wallet_fhse/wallet_fhse.dart';

/// The key-first flow against a simulated native side: what `inspect` reports
/// decides the steps, and the status events the key sends while it waits
/// decide the prompts.
const _channel = MethodChannel(SecurityKeyService.channelName);

Map<String, Object?> _key({
  bool pinSet = true,
  int pinRetries = 8,
  bool fingerprint = false,
  int minPinLength = 4,
  int? serial,
}) => {
  'serial': serial,
  'pinSet': pinSet,
  'pinRetries': pinSet ? pinRetries : null,
  'hmacSecret': true,
  'credProtect': true,
  'transport': 'usb',
  'uv': fingerprint,
  'uvSupported': fingerprint,
  'uvRetries': fingerprint ? 3 : null,
  'pinUvAuthToken': true,
  'minPinLength': minPinLength,
  'forcePinChange': false,
  'touched': true,
};

/// Windows' backend as the flow sees it: the operating system draws the
/// prompts, and nothing about the key can be read first.
class _SystemPrompts implements SecurityKeyBackend {
  bool inspected = false;

  @override
  bool get systemPrompts => true;

  @override
  Stream<SecurityKeyStatus> get status => const Stream.empty();

  @override
  Future<({bool nfc, bool usb})> capabilities() async => (nfc: false, usb: true);

  @override
  Future<SecurityKeyInfo> inspect({required bool touch, required String prompt}) async {
    inspected = true;
    throw StateError('not reachable on Windows');
  }

  @override
  Future<void> setPin(String newPin, {int? expectSerial, required String prompt}) =>
      throw StateError('not reachable on Windows');

  @override
  Future<KeyReply> enroll({
    required String rpId,
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
    int? expectSerial,
    required String prompt,
  }) => throw StateError('the test supplies useKey');

  @override
  Future<KeyReply> getHmacSecret({
    required String rpId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
    int? expectSerial,
    required String prompt,
  }) => throw StateError('the test supplies useKey');

  @override
  Future<void> cancel() async {}
}

void main() {
  late List<MethodCall> calls;
  late Map<String, Object?> inspectResult;

  setUp(() {
    SecurityKeysUi.install(
      SecurityKeysUiConfig(
        appName: 'Test Wallet',
        walletManagerOf: (_) => throw UnimplementedError('the flow never needs the manager'),
        homeRoute: '/home',
        logo: (_) => const SizedBox.shrink(),
      ),
    );
    calls = [];
    inspectResult = _key();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      (call) async {
        calls.add(call);
        return switch (call.method) {
          'inspect' => inspectResult,
          'getHmacSecret' => {
            'credentialId': Uint8List(16),
            'hmacSecret': Uint8List(32),
            'serial': inspectResult['serial'],
            // rpIdHash, flags (user present and verified), signCount.
            'authenticatorData': Uint8List.fromList([...List.filled(32, 0), 0x05, 0, 0, 0, 1]),
          },
          _ => null,
        };
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _channel,
      null,
    );
  });

  Future<void> pumpFlow(
    WidgetTester tester, {
    required bool enrolling,
    required Future<SecurityKeyRecord?> Function(KeyVerification, SecurityKeyAuthenticator) useKey,
    Future<void> Function(SecurityKeyRecord, String)? rename,
    List<SecurityKeyRecord> registered = const [],
    VoidCallback? onDone,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: FhseLocalizations.localizationsDelegates,
        supportedLocales: FhseLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: SecurityKeyFlow(
              enrolling: enrolling,
              autoStart: false,
              defaultName: 'YubiKey 1',
              useKey: useKey,
              registeredKeys: () async => registered,
              rename: rename,
              onDone: onDone ?? () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // The touch ring and spinners never settle, so pump a fixed time instead.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> tap(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await settle(tester);
  }

  Future<void> status(WidgetTester tester, String state) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(MethodCall('status', {'state': state, 'transport': 'usb'})),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('adding a key: touch, PIN, two touches, then a name', (tester) async {
    final result = Completer<SecurityKeyRecord?>();
    KeyVerification? used;
    String? renamed;
    var done = false;
    await pumpFlow(
      tester,
      enrolling: true,
      useKey: (v, _) {
        used = v;
        return result.future;
      },
      rename: (record, name) async => renamed = name,
      onDone: () => done = true,
    );

    expect(find.text('Connect your security key'), findsOneWidget);
    await tap(tester, 'Connect key');
    expect(calls.single.method, 'inspect');
    expect(calls.single.arguments['touch'], isTrue, reason: 'insert and touch comes first');
    expect(find.text("Enter your key's PIN"), findsOneWidget);

    await tester.enterText(find.byType(TextField), '123456');
    await tap(tester, 'Continue');
    expect(used?.pin, '123456');
    expect(find.text('Checking your PIN…'), findsOneWidget);

    await status(tester, 'touchNeeded');
    expect(find.text('Touch your key to confirm'), findsOneWidget);
    expect(find.text('Touch 1 of 2'), findsOneWidget);
    await status(tester, 'processing');
    await status(tester, 'touchNeeded');
    expect(find.text('Touch your key once more'), findsOneWidget);
    expect(find.text('Touch 2 of 2'), findsOneWidget);

    result.complete(SecurityKeyRecord(id: 'k1', name: 'YubiKey 1', addedAt: DateTime(2026)));
    await settle(tester);
    expect(find.text('Key added'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Blue');
    await tap(tester, 'Save');
    expect(renamed, 'Blue');
    expect(done, isTrue);
  });

  testWidgets('a wrong PIN goes back to the PIN with the attempts left', (tester) async {
    await pumpFlow(
      tester,
      enrolling: false,
      useKey: (_, _) async =>
          throw const SecurityKeyException(SecurityKeyFailure.pinInvalid, retries: 2),
    );
    await tap(tester, 'Connect key');
    await tester.enterText(find.byType(TextField), '0000');
    await tap(tester, 'Continue');

    expect(find.text("Enter your key's PIN"), findsOneWidget);
    expect(find.text('Incorrect PIN. 2 attempts left before the key locks.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  });

  testWidgets('a YubiKey Bio skips the PIN and asks for its sensor', (tester) async {
    inspectResult = _key(fingerprint: true);
    final attempts = <KeyVerification>[];
    var fail = true;
    final result = Completer<SecurityKeyRecord?>();
    await pumpFlow(
      tester,
      enrolling: true,
      useKey: (v, _) {
        attempts.add(v);
        if (fail) {
          fail = false;
          return Future.error(const SecurityKeyException(SecurityKeyFailure.uvInvalid, retries: 2));
        }
        return result.future;
      },
    );
    await tap(tester, 'Connect key');

    // The first attempt went straight to the sensor and missed.
    expect(attempts.single.isBuiltIn, isTrue);
    expect(find.text('Fingerprint not recognized. 2 tries left.'), findsOneWidget);
    expect(find.text('Use PIN instead'), findsOneWidget);

    await tap(tester, 'Try again');
    expect(attempts.last.isBuiltIn, isTrue);
    expect(find.text('Touch the fingerprint sensor'), findsOneWidget);
    await status(tester, 'fingerprintNeeded');
    await status(tester, 'processing');
    await status(tester, 'fingerprintNeeded');
    expect(find.text('Touch the sensor once more'), findsOneWidget);
  });

  testWidgets('a Bio whose sensor is locked falls back to its PIN', (tester) async {
    inspectResult = _key(fingerprint: true);
    await pumpFlow(
      tester,
      enrolling: false,
      useKey: (_, _) async => throw const SecurityKeyException(SecurityKeyFailure.uvBlocked),
    );
    await tap(tester, 'Connect key');
    expect(find.text("Enter your key's PIN"), findsOneWidget);
    expect(find.text('Fingerprint is locked on this key. Enter its PIN instead.'), findsOneWidget);
  });

  testWidgets('a Bio without a PIN gets one, then is enrolled with the PIN', (tester) async {
    inspectResult = _key(pinSet: false, fingerprint: true);
    KeyVerification? used;
    await pumpFlow(
      tester,
      enrolling: true,
      useKey: (v, _) {
        used = v;
        return Completer<SecurityKeyRecord?>().future;
      },
    );
    await tap(tester, 'Connect key');
    expect(used, isNull);
    expect(find.text('Create a PIN for this key'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), '123456');
    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tap(tester, 'Set PIN');
    expect(calls.last.method, 'setPin');
    expect(used?.isBuiltIn, isFalse);
    expect(used?.pin, '123456');
  });

  testWidgets('a fingerprint refused for want of a PIN leads to a new PIN', (tester) async {
    inspectResult = _key(fingerprint: true);
    final attempts = <KeyVerification>[];
    await pumpFlow(
      tester,
      enrolling: true,
      useKey: (v, _) {
        attempts.add(v);
        // What each platform answers when the fingerprint is asked of a key
        // with no PIN.
        return Future.error(const SecurityKeyException(SecurityKeyFailure.pinNotSet));
      },
    );
    await tap(tester, 'Connect key');
    expect(attempts.single.isBuiltIn, isTrue);
    expect(find.text('Create a PIN for this key'), findsOneWidget);
  });

  testWidgets('unlocking with a Bio that has no PIN uses neither', (tester) async {
    inspectResult = _key(pinSet: false, fingerprint: true);
    var used = false;
    await pumpFlow(
      tester,
      enrolling: false,
      useKey: (_, _) async {
        used = true;
        return null;
      },
    );
    await tap(tester, 'Connect key');
    expect(find.text("This key isn't set up for this wallet."), findsOneWidget);
    expect(used, isFalse);
  });

  testWidgets('unlocking with a key that has no PIN stops before any PIN', (tester) async {
    inspectResult = _key(pinSet: false);
    var used = false;
    await pumpFlow(
      tester,
      enrolling: false,
      useKey: (_, _) async {
        used = true;
        return null;
      },
    );
    await tap(tester, 'Connect key');
    expect(find.text("This key isn't set up for this wallet."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(used, isFalse);
  });

  testWidgets('a key with no PIN gets one, then is enrolled with it', (tester) async {
    inspectResult = _key(pinSet: false, minPinLength: 6);
    KeyVerification? used;
    await pumpFlow(
      tester,
      enrolling: true,
      useKey: (v, _) {
        used = v;
        return Completer<SecurityKeyRecord?>().future;
      },
    );
    await tap(tester, 'Connect key');
    expect(find.text('Create a PIN for this key'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), '123');
    await tester.enterText(find.byType(TextField).at(1), '123');
    await tap(tester, 'Set PIN');
    expect(find.text('Use at least 6 characters.'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), '123456');
    await tester.enterText(find.byType(TextField).at(1), '123456');
    await tap(tester, 'Set PIN');
    expect(calls.last.method, 'setPin');
    expect(calls.last.arguments['newPin'], '123456');
    expect(used?.pin, '123456');
  });

  testWidgets('cancelling while the key waits returns to connecting', (tester) async {
    final result = Completer<SecurityKeyRecord?>();
    await pumpFlow(tester, enrolling: false, useKey: (_, _) => result.future);
    await tap(tester, 'Connect key');
    await tester.enterText(find.byType(TextField), '123456');
    await tap(tester, 'Continue');
    await status(tester, 'touchNeeded');
    expect(find.text('Touch your key to unlock'), findsOneWidget);

    await tap(tester, 'Cancel');
    expect(calls.last.method, 'cancel');
    result.completeError(const SecurityKeyException(SecurityKeyFailure.cancelled));
    await settle(tester);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Unlock with your security key'), findsOneWidget);
  });

  group('serial numbers', () {
    SecurityKeyRecord record(String name, int? serial) =>
        SecurityKeyRecord(id: name, name: name, addedAt: DateTime(2026), serial: serial);

    testWidgets('unlocking names the touched key and holds the call to it', (tester) async {
      inspectResult = _key(serial: 111);
      await pumpFlow(
        tester,
        enrolling: false,
        registered: [record('Blue', 111), record('Spare', 222)],
        useKey: (v, key) async {
          await key.getHmacSecret(
            salt: Uint8List(32),
            verification: v,
            credentialIds: [Uint8List(16)],
          );
          return null;
        },
      );
      await tap(tester, 'Connect key');
      expect(find.text('Enter the PIN for Blue'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '123456');
      await tap(tester, 'Continue');
      final call = calls.singleWhere((c) => c.method == 'getHmacSecret');
      expect(call.arguments['expectSerial'], 111, reason: 'a different key is refused natively');
    });

    testWidgets('an unregistered key is refused before any PIN', (tester) async {
      inspectResult = _key(serial: 999);
      await pumpFlow(
        tester,
        enrolling: false,
        registered: [record('Blue', 111), record('Spare', 222)],
        useKey: (_, _) async => null,
      );
      await tap(tester, 'Connect key');
      expect(find.text("This key isn't set up for this wallet."), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('without every serial on file, an unknown key still gets its PIN', (tester) async {
      inspectResult = _key(serial: 999);
      await pumpFlow(
        tester,
        enrolling: false,
        registered: [record('Blue', 111), record('Old key', null)],
        useKey: (_, _) async => null,
      );
      await tap(tester, 'Connect key');
      expect(find.text("Enter your key's PIN"), findsOneWidget);
    });

    testWidgets('adding a key that is already registered stops at the first step', (tester) async {
      inspectResult = _key(serial: 111);
      await pumpFlow(
        tester,
        enrolling: true,
        registered: [record('Blue', 111)],
        useKey: (_, _) async => null,
      );
      await tap(tester, 'Connect key');
      expect(find.text('This key is already set up for this wallet.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('a key swapped after the touch goes back to the start', (tester) async {
      inspectResult = _key(serial: 111);
      await pumpFlow(
        tester,
        enrolling: false,
        registered: [record('Blue', 111)],
        useKey: (_, _) async => throw const SecurityKeyException(SecurityKeyFailure.differentKey),
      );
      await tap(tester, 'Connect key');
      await tester.enterText(find.byType(TextField), '123456');
      await tap(tester, 'Continue');
      expect(
        find.text("This isn't the key you touched. Start again with the key you want to use."),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('several keys no touch could tell apart stop before any PIN', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        _channel,
        (call) async {
          calls.add(call);
          throw PlatformException(code: 'multipleKeys', message: 'More than one key');
        },
      );
      await pumpFlow(tester, enrolling: false, useKey: (_, _) async => null);
      await tap(tester, 'Connect key');
      expect(
        find.text('More than one security key is plugged in. Unplug the others, then try again.'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(calls.map((c) => c.method), ['inspect']);
    });
  });

  group('when Windows draws the prompts', () {
    late _SystemPrompts backend;

    setUp(() => SecurityKeyService.instance.backendForTesting = backend = _SystemPrompts());
    tearDown(() => SecurityKeyService.instance.backendForTesting = null);

    testWidgets('adding a key: one tap, Windows asks for the rest, then a name', (tester) async {
      final result = Completer<SecurityKeyRecord?>();
      KeyVerification? used;
      await pumpFlow(
        tester,
        enrolling: true,
        useKey: (v, _) {
          used = v;
          return result.future;
        },
      );

      // Windows' dialog says the passkey is saved to the key; the flow says
      // it isn't, before the dialog and while it is up.
      final storageNote = find.textContaining('does not take up any storage slots');
      expect(find.text('Use security key'), findsOneWidget);
      expect(storageNote, findsOneWidget);
      await tap(tester, 'Use security key');
      expect(used?.isSystem, isTrue);
      expect(backend.inspected, isFalse, reason: 'nothing is read from the key first');
      expect(find.text("Enter your key's PIN"), findsNothing);
      expect(find.text('Continue in Windows Security'), findsOneWidget);
      expect(find.text('Waiting for Windows Security…'), findsOneWidget);
      expect(storageNote, findsOneWidget);

      result.complete(SecurityKeyRecord(id: 'k1', name: 'YubiKey 1', addedAt: DateTime(2026)));
      await settle(tester);
      expect(find.text('Key added'), findsOneWidget);
    });

    testWidgets('closing the Windows dialog goes back to the start', (tester) async {
      await pumpFlow(
        tester,
        enrolling: false,
        useKey: (_, _) async => throw const SecurityKeyException(SecurityKeyFailure.cancelled),
      );
      expect(find.textContaining('storage slots'), findsNothing, reason: 'unlocking saves nothing');
      await tap(tester, 'Use security key');
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Unlock with your security key'), findsOneWidget);
    });
  });
}
