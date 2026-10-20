import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fhse/src/backends/linux_libfido2.dart';
import 'package:wallet_fhse/wallet_fhse.dart';

/// The libfido2 under test: LIBFIDO2_PATH (Homebrew's on a Mac), or the
/// system's on Linux. Null when none loads.
String? _libfido2() {
  final fromEnv = Platform.environment['LIBFIDO2_PATH'];
  final names = fromEnv != null
      ? [fromEnv]
      : [
          if (Platform.isLinux) ...['libfido2.so.1', 'libfido2.so'],
        ];
  for (final name in names) {
    try {
      DynamicLibrary.open(name);
      return name;
    } on ArgumentError {
      continue;
    }
  }
  return null;
}

/// fido/err.h's codes, the names fido_strerr gives them, and the failure each
/// maps to (with a PIN, on a key that has one). The names check the numbers
/// against the library itself.
const _codes = <int, (String, SecurityKeyFailure)>{
  0x31: ('FIDO_ERR_PIN_INVALID', SecurityKeyFailure.pinInvalid),
  0x32: ('FIDO_ERR_PIN_BLOCKED', SecurityKeyFailure.pinBlocked),
  0x34: ('FIDO_ERR_PIN_AUTH_BLOCKED', SecurityKeyFailure.pinAuthBlocked),
  0x35: ('FIDO_ERR_PIN_NOT_SET', SecurityKeyFailure.pinNotSet),
  0x36: ('FIDO_ERR_PIN_REQUIRED', SecurityKeyFailure.pinInvalid),
  0x37: ('FIDO_ERR_PIN_POLICY_VIOLATION', SecurityKeyFailure.pinPolicy),
  0x3f: ('FIDO_ERR_UV_INVALID', SecurityKeyFailure.uvInvalid),
  0x3c: ('FIDO_ERR_UV_BLOCKED', SecurityKeyFailure.uvBlocked),
  0x19: ('FIDO_ERR_CREDENTIAL_EXCLUDED', SecurityKeyFailure.credentialExcluded),
  0x2e: ('FIDO_ERR_NO_CREDENTIALS', SecurityKeyFailure.noCredentials),
  0x2d: ('FIDO_ERR_KEEPALIVE_CANCEL', SecurityKeyFailure.cancelled),
  0x27: ('FIDO_ERR_OPERATION_DENIED', SecurityKeyFailure.cancelled),
  0x3a: ('FIDO_ERR_ACTION_TIMEOUT', SecurityKeyFailure.timeout),
  0x2f: ('FIDO_ERR_USER_ACTION_TIMEOUT', SecurityKeyFailure.timeout),
  0x2b: ('FIDO_ERR_UNSUPPORTED_OPTION', SecurityKeyFailure.unsupported),
  0x16: ('FIDO_ERR_UNSUPPORTED_EXTENSION', SecurityKeyFailure.unsupported),
  0x26: ('FIDO_ERR_UNSUPPORTED_ALGORITHM', SecurityKeyFailure.unsupported),
  0x01: ('FIDO_ERR_INVALID_COMMAND', SecurityKeyFailure.unsupported),
  0x15: ('FIDO_ERR_LIMIT_EXCEEDED', SecurityKeyFailure.unsupported),
  0x39: ('FIDO_ERR_REQUEST_TOO_LARGE', SecurityKeyFailure.unsupported),
  -1: ('FIDO_ERR_TX', SecurityKeyFailure.transport),
  -2: ('FIDO_ERR_RX', SecurityKeyFailure.transport),
  -3: ('FIDO_ERR_RX_NOT_CBOR', SecurityKeyFailure.transport),
  -4: ('FIDO_ERR_RX_INVALID_CBOR', SecurityKeyFailure.transport),
  -9: ('FIDO_ERR_INTERNAL', SecurityKeyFailure.transport),
  0x05: ('FIDO_ERR_TIMEOUT', SecurityKeyFailure.transport),
  0x06: ('FIDO_ERR_CHANNEL_BUSY', SecurityKeyFailure.transport),
  0x33: ('FIDO_ERR_PIN_AUTH_INVALID', SecurityKeyFailure.unknown),
  0x30: ('FIDO_ERR_NOT_ALLOWED', SecurityKeyFailure.unknown),
  0x7f: ('FIDO_ERR_ERR_OTHER', SecurityKeyFailure.unknown),
  -7: ('FIDO_ERR_INVALID_ARGUMENT', SecurityKeyFailure.unknown),
};

Matcher _fails(SecurityKeyFailure failure) =>
    throwsA(isA<SecurityKeyException>().having((e) => e.failure, 'failure', failure));

void main() {
  group('FIDO_ERR to SecurityKeyFailure', () {
    test('maps every code the contract names', () {
      for (final MapEntry(key: code, value: (name, failure)) in _codes.entries) {
        expect(LinuxLibFido2Backend.failureFor(code), failure, reason: name);
      }
    });

    test('PIN_REQUIRED and NOT_ALLOWED depend on how the user is verified', () {
      expect(LinuxLibFido2Backend.failureFor(0x36, pinSet: false), SecurityKeyFailure.pinNotSet);
      expect(LinuxLibFido2Backend.failureFor(0x36, builtInUv: true), SecurityKeyFailure.uvBlocked);
      expect(
        LinuxLibFido2Backend.failureFor(0x30, builtInUv: true),
        SecurityKeyFailure.uvNotConfigured,
      );
    });
  });

  group("an assertion's authenticator data inside CBOR", () {
    final authData = Uint8List.fromList(List.generate(37, (i) => i));

    test('unwraps a byte string of any length libfido2 returns', () {
      expect(
        LinuxLibFido2Backend.unwrapCborBytes(Uint8List.fromList([0x58, 37, ...authData])),
        authData,
      );
      final long = Uint8List.fromList(List.generate(300, (i) => i & 0xff));
      expect(
        LinuxLibFido2Backend.unwrapCborBytes(Uint8List.fromList([0x59, 0x01, 0x2c, ...long])),
        long,
      );
      expect(LinuxLibFido2Backend.unwrapCborBytes(Uint8List.fromList([0x43, 1, 2, 3])), [1, 2, 3]);
    });

    test('rejects anything but exactly one byte string', () {
      expect(
        () => LinuxLibFido2Backend.unwrapCborBytes(Uint8List.fromList([0x78, 37, ...authData])),
        throwsFormatException,
        reason: 'a text string',
      );
      expect(
        () => LinuxLibFido2Backend.unwrapCborBytes(Uint8List.fromList([0x58, 38, ...authData])),
        throwsFormatException,
        reason: 'shorter than it says',
      );
      expect(
        () => LinuxLibFido2Backend.unwrapCborBytes(Uint8List.fromList([0x58, 36, ...authData])),
        throwsFormatException,
        reason: 'bytes left over',
      );
      expect(() => LinuxLibFido2Backend.unwrapCborBytes(Uint8List(0)), throwsFormatException);
    });
  });

  test('tells a FIDO report descriptor from a keyboard', () {
    // A YubiKey's FIDO interface: Usage Page (0xF1D0), Usage (CTAPHID), ...
    final fido = Uint8List.fromList([
      0x06, 0xd0, 0xf1, 0x09, 0x01, 0xa1, 0x01, 0x09, 0x20, 0x15, 0x00, 0x26, 0xff, 0x00, //
      0x75, 0x08, 0x95, 0x40, 0x81, 0x02, 0xc0,
    ]);
    final keyboard = Uint8List.fromList([0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0xc0]);
    expect(LinuxLibFido2Backend.isFidoReportDescriptor(fido), isTrue);
    expect(LinuxLibFido2Backend.isFidoReportDescriptor(keyboard), isFalse);
    expect(LinuxLibFido2Backend.isFidoReportDescriptor(Uint8List.fromList([0x06, 0xd0])), isFalse);
  });

  group('which key an operation may use (no PIN to a key the user did not choose)', () {
    const a = '/dev/hidraw3';
    const b = '/dev/hidraw4';
    // The kernel's name for each plugging-in: a swapped key gets a new one.
    final ids = {a: '0003:1050:0407.000C', b: '0003:1050:0407.000D'};
    String? keyFor(
      List<String> paths, {
      bool touch = false,
      bool canTouch = true,
      ({String path, String id})? chosen,
    }) => LinuxLibFido2Backend.keyFor(
      paths: paths,
      touch: touch,
      canTouch: canTouch,
      chosen: chosen,
      connectionId: (path) => ids[path],
    );

    test('the only key plugged in', () {
      expect(keyFor([a]), a);
      expect(keyFor([a], canTouch: false), a);
    });

    test('a touch, when asked for one and libfido2 can ask', () {
      expect(keyFor([a], touch: true), isNull);
      expect(keyFor([a], touch: true, canTouch: false), a);
    });

    test('of several, the one the user touches; never the first one found', () {
      expect(keyFor([a, b]), isNull);
      expect(keyFor([a, b], touch: true), isNull);
    });

    test('of several, none when libfido2 cannot ask for a touch', () {
      expect(() => keyFor([a, b], canTouch: false), _fails(SecurityKeyFailure.multipleKeys));
      expect(
        () => keyFor([a, b], touch: true, canTouch: false),
        _fails(SecurityKeyFailure.multipleKeys),
      );
    });

    test('the key chosen earlier, while that plugging-in of it is there', () {
      final chosen = (path: b, id: ids[b]!);
      expect(keyFor([a, b], chosen: chosen), b);
      expect(keyFor([b], chosen: chosen), b);
      expect(keyFor([a, b], canTouch: false, chosen: chosen), b);
    });

    test('a different key once the chosen one is gone, even at the same path', () {
      final swapped = (path: a, id: '0003:1050:0407.0009');
      expect(() => keyFor([a, b], chosen: swapped), _fails(SecurityKeyFailure.differentKey));
      expect(() => keyFor([a], chosen: swapped), _fails(SecurityKeyFailure.differentKey));
      final unplugged = (path: '/dev/hidraw7', id: '0003:1050:0407.0001');
      expect(() => keyFor([a], chosen: unplugged), _fails(SecurityKeyFailure.differentKey));
    });

    test('a touch to choose again ignores the earlier choice', () {
      final chosen = (path: '/dev/hidraw7', id: '0003:1050:0407.0001');
      expect(keyFor([a, b], touch: true, chosen: chosen), isNull);
      expect(keyFor([a], touch: true, canTouch: false, chosen: chosen), a);
    });

    test('a connection id only for a hidraw node that is there', () {
      expect(LinuxLibFido2Backend.connectionId('IOService:/AppleACPIPlatformExpert'), isNull);
      expect(LinuxLibFido2Backend.connectionId('/dev/hidraw999'), isNull);
    });
  });

  test('refuses what it cannot do before looking for a key', () async {
    final backend = LinuxLibFido2Backend();
    await expectLater(
      backend.getHmacSecret(
        rpId: SecurityKeyService.rpId,
        salt: Uint8List(32),
        verification: const KeyVerification.system(),
        credentialIds: [Uint8List(16)],
        prompt: '',
      ),
      _fails(SecurityKeyFailure.unsupported),
    );
    await expectLater(
      backend.enroll(
        rpId: SecurityKeyService.rpId,
        userId: Uint8List(32),
        salt: Uint8List(31),
        verification: const KeyVerification.pin('123456'),
        excludeCredentialIds: const [],
        prompt: '',
      ),
      _fails(SecurityKeyFailure.unknown),
    );
    expect(await backend.capabilities(), (nfc: false, usb: true));
    expect(backend.systemPrompts, isFalse);
  });

  final library = _libfido2();
  group(
    'with libfido2',
    skip: library == null
        ? 'libfido2 did not load: set LIBFIDO2_PATH (on a Mac, Homebrew\'s '
              'opt/libfido2/lib/libfido2.1.dylib) or install libfido2'
        : null,
    () {
      late DynamicLibrary lib;
      setUpAll(() {
        LinuxLibFido2Backend.libraryPathOverride = library;
        lib = DynamicLibrary.open(library!);
      });

      test('has every required symbol', () {
        final missing = LinuxLibFido2Backend.requiredSymbols.where((s) => !lib.providesSymbol(s));
        expect(missing, isEmpty);
        // Optional ones may be missing in old builds; looking them up must not throw.
        for (final symbol in LinuxLibFido2Backend.optionalSymbols) {
          lib.providesSymbol(symbol);
        }
      });

      test('agrees with fido/err.h on every code', () {
        final strerr = lib
            .lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>(
              'fido_strerr',
            );
        for (final MapEntry(key: code, value: (name, _)) in _codes.entries) {
          expect(strerr(code).toDartString(), name, reason: 'code $code');
        }
      });

      // Assumes no security key is plugged in.
      test('inspect waits for a key, refuses a second call, and stops on cancel', () async {
        final backend = LinuxLibFido2Backend();
        final waiting = backend.status
            .firstWhere((s) => s == SecurityKeyStatus.waitingForKey)
            .timeout(const Duration(seconds: 5));
        final inspecting = backend.inspect(touch: true, prompt: '');
        // Keeps the failure from surfacing as unhandled before it is awaited.
        unawaited(inspecting.then((_) {}, onError: (Object _) {}));
        await waiting;

        await expectLater(
          backend.getHmacSecret(
            rpId: SecurityKeyService.rpId,
            salt: Uint8List(32),
            verification: const KeyVerification.pin('123456'),
            credentialIds: [Uint8List(16)],
            prompt: '',
          ),
          _fails(SecurityKeyFailure.busy),
        );

        final clock = Stopwatch()..start();
        await backend.cancel();
        await expectLater(
          inspecting.timeout(const Duration(seconds: 2)),
          _fails(SecurityKeyFailure.cancelled),
        );
        expect(clock.elapsed, lessThan(const Duration(seconds: 2)));

        // The backend is free again: the next call waits too.
        final again = backend.inspect(touch: false, prompt: '');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await backend.cancel();
        await expectLater(
          again.timeout(const Duration(seconds: 2)),
          _fails(SecurityKeyFailure.cancelled),
        );
      });
    },
  );
}
