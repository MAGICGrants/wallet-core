// The Windows WebAuthn bindings cannot run here, so this checks what can go
// wrong silently: each Dart struct's size and field offsets against clang's
// layout of webauthn.h for Windows x64 and arm64, dumped into
// test/fixtures/webauthn_layout/ (layouts.c says how). It also checks the
// HRESULT mapping. Passing on a 64-bit host shows that Dart's natural layout of
// these explicit-width fields equals the Windows one.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_fhse/src/backends/webauthn_bindings.dart';
import 'package:wallet_fhse/src/backends/windows_webauthn.dart';
import 'package:wallet_fhse/src/security_key_service.dart';

typedef _Field = ({String name, String type, int offset});
typedef _Layout = ({int size, List<_Field> fields});

const _fixtures = 'test/fixtures/webauthn_layout';

/// Each struct clang dumped, with its top-level fields. Fields of an embedded
/// struct are indented further and belong to that struct's own entry.
Map<String, _Layout> _parse(String dump) => {
  for (final block in dump.split('*** Dumping AST Record Layout').skip(1))
    RegExp(r'\| struct (\w+)\n').firstMatch(block)![1]!: (
      size: int.parse(RegExp(r'\[sizeof=(\d+),').firstMatch(block)![1]!),
      fields: [
        for (final m in RegExp(r'^ *(\d+) \|   (\S.*) (\w+)$', multiLine: true).allMatches(block))
          (name: m[3]!, type: m[2]!, offset: int.parse(m[1]!)),
      ],
    ),
};

/// The field's width on Windows, from its C type. Null for an embedded struct.
int? _width(String type) {
  if (type.startsWith('struct ')) return null;
  if (type.contains('*') || type.startsWith('P') || type.startsWith('LP')) return 8;
  return switch (type) {
    'DWORD' || 'LONG' || 'BOOL' || 'unsigned long' => 4,
    'unsigned short' => 2,
    'unsigned char[8]' => 8,
    _ => throw ArgumentError('no width for $type'),
  };
}

// Sentinels with every byte non-zero. An integer field keeps as many bytes of -1
// as it is wide, so the written span shows its offset and its true width.
const _int = -1;
final _ptr = Pointer<Never>.fromAddress(0x5A5A5A5A5A5A5A5A);

/// Writes each field into zeroed memory through its Dart setter and finds the
/// bytes it changed. [writers] is keyed by the C field name; an embedded
/// struct's writer sets its first field.
void _expectLayout<T extends Struct>(
  _Layout c,
  int dartSize,
  T Function(Pointer<Uint8>) view,
  Map<String, void Function(T)> writers,
) {
  expect(dartSize, c.size, reason: 'sizeof');
  expect(writers.keys, orderedEquals(c.fields.map((f) => f.name)), reason: 'fields');
  for (final field in c.fields) {
    final memory = calloc<Uint8>(dartSize);
    try {
      writers[field.name]!(view(memory));
      final bytes = memory.asTypedList(dartSize);
      final first = bytes.indexWhere((b) => b != 0);
      expect(first, field.offset, reason: '${field.name} offset');
      final width = _width(field.type);
      if (width != null) {
        expect(bytes.lastIndexWhere((b) => b != 0) - first + 1, width, reason: field.name);
      }
    } finally {
      calloc.free(memory);
    }
  }
}

void main() {
  final x64 = File('$_fixtures/x86_64-pc-windows-msvc.txt').readAsStringSync();
  final arm64 = File('$_fixtures/aarch64-pc-windows-msvc.txt').readAsStringSync();
  final layouts = _parse(x64);

  test('x64 and arm64 Windows lay the structs out the same', () {
    expect(arm64, x64);
    expect(layouts, hasLength(19));
  });

  test('the host is 64-bit, like Windows x64 and arm64', () {
    expect(sizeOf<Pointer<Void>>(), 8);
  });

  group('struct layout matches webauthn.h on Windows', () {
    test('GUID', () {
      _expectLayout<Guid>(layouts['_GUID']!, sizeOf<Guid>(), (p) => p.cast<Guid>().ref, {
        'Data1': (s) => s.data1 = _int,
        'Data2': (s) => s.data2 = _int,
        'Data3': (s) => s.data3 = _int,
        'Data4': (s) {
          for (var i = 0; i < 8; i++) {
            s.data4[i] = _int;
          }
        },
      });
    });

    test('WEBAUTHN_RP_ENTITY_INFORMATION', () {
      _expectLayout<WebAuthnRpEntityInformation>(
        layouts['_WEBAUTHN_RP_ENTITY_INFORMATION']!,
        sizeOf<WebAuthnRpEntityInformation>(),
        (p) => p.cast<WebAuthnRpEntityInformation>().ref,
        {
          'dwVersion': (s) => s.dwVersion = _int,
          'pwszId': (s) => s.pwszId = _ptr,
          'pwszName': (s) => s.pwszName = _ptr,
          'pwszIcon': (s) => s.pwszIcon = _ptr,
        },
      );
    });

    test('WEBAUTHN_USER_ENTITY_INFORMATION', () {
      _expectLayout<WebAuthnUserEntityInformation>(
        layouts['_WEBAUTHN_USER_ENTITY_INFORMATION']!,
        sizeOf<WebAuthnUserEntityInformation>(),
        (p) => p.cast<WebAuthnUserEntityInformation>().ref,
        {
          'dwVersion': (s) => s.dwVersion = _int,
          'cbId': (s) => s.cbId = _int,
          'pbId': (s) => s.pbId = _ptr,
          'pwszName': (s) => s.pwszName = _ptr,
          'pwszIcon': (s) => s.pwszIcon = _ptr,
          'pwszDisplayName': (s) => s.pwszDisplayName = _ptr,
        },
      );
    });

    test('WEBAUTHN_CLIENT_DATA', () {
      _expectLayout<WebAuthnClientData>(
        layouts['_WEBAUTHN_CLIENT_DATA']!,
        sizeOf<WebAuthnClientData>(),
        (p) => p.cast<WebAuthnClientData>().ref,
        {
          'dwVersion': (s) => s.dwVersion = _int,
          'cbClientDataJSON': (s) => s.cbClientDataJSON = _int,
          'pbClientDataJSON': (s) => s.pbClientDataJSON = _ptr,
          'pwszHashAlgId': (s) => s.pwszHashAlgId = _ptr,
        },
      );
    });

    test('WEBAUTHN_COSE_CREDENTIAL_PARAMETER(S)', () {
      _expectLayout<WebAuthnCoseCredentialParameter>(
        layouts['_WEBAUTHN_COSE_CREDENTIAL_PARAMETER']!,
        sizeOf<WebAuthnCoseCredentialParameter>(),
        (p) => p.cast<WebAuthnCoseCredentialParameter>().ref,
        {
          'dwVersion': (s) => s.dwVersion = _int,
          'pwszCredentialType': (s) => s.pwszCredentialType = _ptr,
          'lAlg': (s) => s.lAlg = _int,
        },
      );
      _expectLayout<WebAuthnCoseCredentialParameters>(
        layouts['_WEBAUTHN_COSE_CREDENTIAL_PARAMETERS']!,
        sizeOf<WebAuthnCoseCredentialParameters>(),
        (p) => p.cast<WebAuthnCoseCredentialParameters>().ref,
        {
          'cCredentialParameters': (s) => s.cCredentialParameters = _int,
          'pCredentialParameters': (s) => s.pCredentialParameters = _ptr,
        },
      );
    });

    test('WEBAUTHN_CREDENTIAL(S)', () {
      _expectLayout<WebAuthnCredential>(
        layouts['_WEBAUTHN_CREDENTIAL']!,
        sizeOf<WebAuthnCredential>(),
        (p) => p.cast<WebAuthnCredential>().ref,
        {
          'dwVersion': (s) => s.dwVersion = _int,
          'cbId': (s) => s.cbId = _int,
          'pbId': (s) => s.pbId = _ptr,
          'pwszCredentialType': (s) => s.pwszCredentialType = _ptr,
        },
      );
      _expectLayout<WebAuthnCredentials>(
        layouts['_WEBAUTHN_CREDENTIALS']!,
        sizeOf<WebAuthnCredentials>(),
        (p) => p.cast<WebAuthnCredentials>().ref,
        {
          'cCredentials': (s) => s.cCredentials = _int,
          'pCredentials': (s) => s.pCredentials = _ptr,
        },
      );
    });

    test('WEBAUTHN_CREDENTIAL_EX and WEBAUTHN_CREDENTIAL_LIST', () {
      _expectLayout<WebAuthnCredentialEx>(
        layouts['_WEBAUTHN_CREDENTIAL_EX']!,
        sizeOf<WebAuthnCredentialEx>(),
        (p) => p.cast<WebAuthnCredentialEx>().ref,
        {
          'dwVersion': (s) => s.dwVersion = _int,
          'cbId': (s) => s.cbId = _int,
          'pbId': (s) => s.pbId = _ptr,
          'pwszCredentialType': (s) => s.pwszCredentialType = _ptr,
          'dwTransports': (s) => s.dwTransports = _int,
        },
      );
      _expectLayout<WebAuthnCredentialList>(
        layouts['_WEBAUTHN_CREDENTIAL_LIST']!,
        sizeOf<WebAuthnCredentialList>(),
        (p) => p.cast<WebAuthnCredentialList>().ref,
        {
          'cCredentials': (s) => s.cCredentials = _int,
          'ppCredentials': (s) => s.ppCredentials = _ptr,
        },
      );
    });

    test('WEBAUTHN_HMAC_SECRET_SALT(_VALUES)', () {
      _expectLayout<WebAuthnHmacSecretSalt>(
        layouts['_WEBAUTHN_HMAC_SECRET_SALT']!,
        sizeOf<WebAuthnHmacSecretSalt>(),
        (p) => p.cast<WebAuthnHmacSecretSalt>().ref,
        {
          'cbFirst': (s) => s.cbFirst = _int,
          'pbFirst': (s) => s.pbFirst = _ptr,
          'cbSecond': (s) => s.cbSecond = _int,
          'pbSecond': (s) => s.pbSecond = _ptr,
        },
      );
      _expectLayout<WebAuthnHmacSecretSaltValues>(
        layouts['_WEBAUTHN_HMAC_SECRET_SALT_VALUES']!,
        sizeOf<WebAuthnHmacSecretSaltValues>(),
        (p) => p.cast<WebAuthnHmacSecretSaltValues>().ref,
        {
          'pGlobalHmacSalt': (s) => s.pGlobalHmacSalt = _ptr,
          'cCredWithHmacSecretSaltList': (s) => s.cCredWithHmacSecretSaltList = _int,
          'pCredWithHmacSecretSaltList': (s) => s.pCredWithHmacSecretSaltList = _ptr,
        },
      );
    });

    test('WEBAUTHN_CRED_PROTECT_EXTENSION_IN', () {
      _expectLayout<WebAuthnCredProtectExtensionIn>(
        layouts['_WEBAUTHN_CRED_PROTECT_EXTENSION_IN']!,
        sizeOf<WebAuthnCredProtectExtensionIn>(),
        (p) => p.cast<WebAuthnCredProtectExtensionIn>().ref,
        {
          'dwCredProtect': (s) => s.dwCredProtect = _int,
          'bRequireCredProtect': (s) => s.bRequireCredProtect = _int,
        },
      );
    });

    test('WEBAUTHN_EXTENSION(S)', () {
      _expectLayout<WebAuthnExtension>(
        layouts['_WEBAUTHN_EXTENSION']!,
        sizeOf<WebAuthnExtension>(),
        (p) => p.cast<WebAuthnExtension>().ref,
        {
          'pwszExtensionIdentifier': (s) => s.pwszExtensionIdentifier = _ptr,
          'cbExtension': (s) => s.cbExtension = _int,
          'pvExtension': (s) => s.pvExtension = _ptr,
        },
      );
      _expectLayout<WebAuthnExtensions>(
        layouts['_WEBAUTHN_EXTENSIONS']!,
        sizeOf<WebAuthnExtensions>(),
        (p) => p.cast<WebAuthnExtensions>().ref,
        {'cExtensions': (s) => s.cExtensions = _int, 'pExtensions': (s) => s.pExtensions = _ptr},
      );
    });

    test('WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS', () {
      _expectLayout<WebAuthnMakeCredentialOptions>(
        layouts['_WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS']!,
        sizeOf<WebAuthnMakeCredentialOptions>(),
        (p) => p.cast<WebAuthnMakeCredentialOptions>().ref,
        {
          'dwVersion': (s) => s.dwVersion = _int,
          'dwTimeoutMilliseconds': (s) => s.dwTimeoutMilliseconds = _int,
          'CredentialList': (s) => s.credentialList.cCredentials = _int,
          'Extensions': (s) => s.extensions.cExtensions = _int,
          'dwAuthenticatorAttachment': (s) => s.dwAuthenticatorAttachment = _int,
          'bRequireResidentKey': (s) => s.bRequireResidentKey = _int,
          'dwUserVerificationRequirement': (s) => s.dwUserVerificationRequirement = _int,
          'dwAttestationConveyancePreference': (s) => s.dwAttestationConveyancePreference = _int,
          'dwFlags': (s) => s.dwFlags = _int,
          'pCancellationId': (s) => s.pCancellationId = _ptr,
          'pExcludeCredentialList': (s) => s.pExcludeCredentialList = _ptr,
          'dwEnterpriseAttestation': (s) => s.dwEnterpriseAttestation = _int,
          'dwLargeBlobSupport': (s) => s.dwLargeBlobSupport = _int,
          'bPreferResidentKey': (s) => s.bPreferResidentKey = _int,
          'bBrowserInPrivateMode': (s) => s.bBrowserInPrivateMode = _int,
          'bEnablePrf': (s) => s.bEnablePrf = _int,
          'pLinkedDevice': (s) => s.pLinkedDevice = _ptr,
          'cbJsonExt': (s) => s.cbJsonExt = _int,
          'pbJsonExt': (s) => s.pbJsonExt = _ptr,
          'pPRFGlobalEval': (s) => s.pPRFGlobalEval = _ptr,
          'cCredentialHints': (s) => s.cCredentialHints = _int,
          'ppwszCredentialHints': (s) => s.ppwszCredentialHints = _ptr,
          'bThirdPartyPayment': (s) => s.bThirdPartyPayment = _int,
          'pwszRemoteWebOrigin': (s) => s.pwszRemoteWebOrigin = _ptr,
          'cbPublicKeyCredentialCreationOptionsJSON': (s) =>
              s.cbPublicKeyCredentialCreationOptionsJSON = _int,
          'pbPublicKeyCredentialCreationOptionsJSON': (s) =>
              s.pbPublicKeyCredentialCreationOptionsJSON = _ptr,
          'cbAuthenticatorId': (s) => s.cbAuthenticatorId = _int,
          'pbAuthenticatorId': (s) => s.pbAuthenticatorId = _ptr,
        },
      );
    });

    test('WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS', () {
      _expectLayout<WebAuthnGetAssertionOptions>(
        layouts['_WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS']!,
        sizeOf<WebAuthnGetAssertionOptions>(),
        (p) => p.cast<WebAuthnGetAssertionOptions>().ref,
        {
          'dwVersion': (s) => s.dwVersion = _int,
          'dwTimeoutMilliseconds': (s) => s.dwTimeoutMilliseconds = _int,
          'CredentialList': (s) => s.credentialList.cCredentials = _int,
          'Extensions': (s) => s.extensions.cExtensions = _int,
          'dwAuthenticatorAttachment': (s) => s.dwAuthenticatorAttachment = _int,
          'dwUserVerificationRequirement': (s) => s.dwUserVerificationRequirement = _int,
          'dwFlags': (s) => s.dwFlags = _int,
          'pwszU2fAppId': (s) => s.pwszU2fAppId = _ptr,
          'pbU2fAppId': (s) => s.pbU2fAppId = _ptr,
          'pCancellationId': (s) => s.pCancellationId = _ptr,
          'pAllowCredentialList': (s) => s.pAllowCredentialList = _ptr,
          'dwCredLargeBlobOperation': (s) => s.dwCredLargeBlobOperation = _int,
          'cbCredLargeBlob': (s) => s.cbCredLargeBlob = _int,
          'pbCredLargeBlob': (s) => s.pbCredLargeBlob = _ptr,
          'pHmacSecretSaltValues': (s) => s.pHmacSecretSaltValues = _ptr,
          'bBrowserInPrivateMode': (s) => s.bBrowserInPrivateMode = _int,
          'pLinkedDevice': (s) => s.pLinkedDevice = _ptr,
          'bAutoFill': (s) => s.bAutoFill = _int,
          'cbJsonExt': (s) => s.cbJsonExt = _int,
          'pbJsonExt': (s) => s.pbJsonExt = _ptr,
          'cCredentialHints': (s) => s.cCredentialHints = _int,
          'ppwszCredentialHints': (s) => s.ppwszCredentialHints = _ptr,
          'pwszRemoteWebOrigin': (s) => s.pwszRemoteWebOrigin = _ptr,
          'cbPublicKeyCredentialRequestOptionsJSON': (s) =>
              s.cbPublicKeyCredentialRequestOptionsJSON = _int,
          'pbPublicKeyCredentialRequestOptionsJSON': (s) =>
              s.pbPublicKeyCredentialRequestOptionsJSON = _ptr,
          'cbAuthenticatorId': (s) => s.cbAuthenticatorId = _int,
          'pbAuthenticatorId': (s) => s.pbAuthenticatorId = _ptr,
        },
      );
    });

    test('WEBAUTHN_CREDENTIAL_ATTESTATION', () {
      _expectLayout<WebAuthnCredentialAttestation>(
        layouts['_WEBAUTHN_CREDENTIAL_ATTESTATION']!,
        sizeOf<WebAuthnCredentialAttestation>(),
        (p) => p.cast<WebAuthnCredentialAttestation>().ref,
        {
          'dwVersion': (s) => s.dwVersion = _int,
          'pwszFormatType': (s) => s.pwszFormatType = _ptr,
          'cbAuthenticatorData': (s) => s.cbAuthenticatorData = _int,
          'pbAuthenticatorData': (s) => s.pbAuthenticatorData = _ptr,
          'cbAttestation': (s) => s.cbAttestation = _int,
          'pbAttestation': (s) => s.pbAttestation = _ptr,
          'dwAttestationDecodeType': (s) => s.dwAttestationDecodeType = _int,
          'pvAttestationDecode': (s) => s.pvAttestationDecode = _ptr,
          'cbAttestationObject': (s) => s.cbAttestationObject = _int,
          'pbAttestationObject': (s) => s.pbAttestationObject = _ptr,
          'cbCredentialId': (s) => s.cbCredentialId = _int,
          'pbCredentialId': (s) => s.pbCredentialId = _ptr,
          'Extensions': (s) => s.extensions.cExtensions = _int,
          'dwUsedTransport': (s) => s.dwUsedTransport = _int,
          'bEpAtt': (s) => s.bEpAtt = _int,
          'bLargeBlobSupported': (s) => s.bLargeBlobSupported = _int,
          'bResidentKey': (s) => s.bResidentKey = _int,
          'bPrfEnabled': (s) => s.bPrfEnabled = _int,
          'cbUnsignedExtensionOutputs': (s) => s.cbUnsignedExtensionOutputs = _int,
          'pbUnsignedExtensionOutputs': (s) => s.pbUnsignedExtensionOutputs = _ptr,
          'pHmacSecret': (s) => s.pHmacSecret = _ptr,
          'bThirdPartyPayment': (s) => s.bThirdPartyPayment = _int,
          'dwTransports': (s) => s.dwTransports = _int,
          'cbClientDataJSON': (s) => s.cbClientDataJSON = _int,
          'pbClientDataJSON': (s) => s.pbClientDataJSON = _ptr,
          'cbRegistrationResponseJSON': (s) => s.cbRegistrationResponseJSON = _int,
          'pbRegistrationResponseJSON': (s) => s.pbRegistrationResponseJSON = _ptr,
        },
      );
    });

    test('WEBAUTHN_ASSERTION', () {
      _expectLayout<WebAuthnAssertion>(
        layouts['_WEBAUTHN_ASSERTION']!,
        sizeOf<WebAuthnAssertion>(),
        (p) => p.cast<WebAuthnAssertion>().ref,
        {
          'dwVersion': (s) => s.dwVersion = _int,
          'cbAuthenticatorData': (s) => s.cbAuthenticatorData = _int,
          'pbAuthenticatorData': (s) => s.pbAuthenticatorData = _ptr,
          'cbSignature': (s) => s.cbSignature = _int,
          'pbSignature': (s) => s.pbSignature = _ptr,
          'Credential': (s) => s.credential.dwVersion = _int,
          'cbUserId': (s) => s.cbUserId = _int,
          'pbUserId': (s) => s.pbUserId = _ptr,
          'Extensions': (s) => s.extensions.cExtensions = _int,
          'cbCredLargeBlob': (s) => s.cbCredLargeBlob = _int,
          'pbCredLargeBlob': (s) => s.pbCredLargeBlob = _ptr,
          'dwCredLargeBlobStatus': (s) => s.dwCredLargeBlobStatus = _int,
          'pHmacSecret': (s) => s.pHmacSecret = _ptr,
          'dwUsedTransport': (s) => s.dwUsedTransport = _int,
          'cbUnsignedExtensionOutputs': (s) => s.cbUnsignedExtensionOutputs = _int,
          'pbUnsignedExtensionOutputs': (s) => s.pbUnsignedExtensionOutputs = _ptr,
          'cbClientDataJSON': (s) => s.cbClientDataJSON = _int,
          'pbClientDataJSON': (s) => s.pbClientDataJSON = _ptr,
          'cbAuthenticationResponseJSON': (s) => s.cbAuthenticationResponseJSON = _int,
          'pbAuthenticationResponseJSON': (s) => s.pbAuthenticationResponseJSON = _ptr,
        },
      );
    });
  });

  group('HRESULT mapping', () {
    // Values from winerror.h, written out rather than taken from the bindings.
    int fromWin32(int code) => 0x80070000 | code;
    SecurityKeyException map(int hr, {String rpId = 'fhse:encryption'}) =>
        WindowsWebAuthnBackend.failureFor(hr, errorName: 'SomeError', rpId: rpId);

    test('each HRESULT maps to its failure', () {
      final expected = {
        0x80090036: SecurityKeyFailure.cancelled, // NTE_USER_CANCELLED
        fromWin32(1223): SecurityKeyFailure.cancelled, // ERROR_CANCELLED
        0x8009000F: SecurityKeyFailure.credentialExcluded, // NTE_EXISTS
        0x80090011: SecurityKeyFailure.noCredentials, // NTE_NOT_FOUND
        0x80090029: SecurityKeyFailure.unsupported, // NTE_NOT_SUPPORTED
        fromWin32(50): SecurityKeyFailure.unsupported, // ERROR_NOT_SUPPORTED
        0x80090027: SecurityKeyFailure.unsupported, // NTE_INVALID_PARAMETER
        0x80070057: SecurityKeyFailure.unsupported, // E_INVALIDARG
        0x80090023: SecurityKeyFailure.unsupported, // NTE_TOKEN_KEYSET_STORAGE_FULL
        fromWin32(1460): SecurityKeyFailure.timeout, // ERROR_TIMEOUT
        fromWin32(258): SecurityKeyFailure.timeout, // WAIT_TIMEOUT
        0x80090035: SecurityKeyFailure.transport, // NTE_DEVICE_NOT_FOUND
        0x80090030: SecurityKeyFailure.transport, // NTE_DEVICE_NOT_READY
        fromWin32(1167): SecurityKeyFailure.transport, // ERROR_DEVICE_NOT_CONNECTED
        fromWin32(21): SecurityKeyFailure.transport, // ERROR_NOT_READY
        fromWin32(31): SecurityKeyFailure.transport, // ERROR_GEN_FAILURE
        0x80004004: SecurityKeyFailure.unknown, // E_ABORT
        0x80004005: SecurityKeyFailure.unknown, // E_FAIL
      };
      expected.forEach((hr, failure) {
        expect(map(hr).failure, failure, reason: hr.toRadixString(16));
        // FFI returns an HRESULT as a signed Int32.
        expect(map(hr.toSigned(32)).failure, failure, reason: 'signed ${hr.toRadixString(16)}');
      });
    });

    test('parameter errors name the error and suspect a non-domain RP id', () {
      for (final hr in [0x80090027, 0x80070057, 0x80090029]) {
        final message = map(hr).message!;
        expect(message, contains('SomeError'));
        expect(message, contains(hr.toRadixString(16).toUpperCase()));
        expect(message, contains('"fhse:encryption" is not a domain'));
        expect(map(hr, rpId: 'example.com').message, contains('unlikely to be the cause'));
      }
    });

    test('unknown errors carry the hex HRESULT and the error name', () {
      expect(map(0x80004005).message, 'Windows WebAuthn error 0x80004005 (SomeError)');
    });
  });

  group('only a security key over USB or NFC, holding nothing on it', () {
    // WEBAUTHN_CTAP_TRANSPORT_* from webauthn.h, written out.
    const usb = 0x01, nfc = 0x02, ble = 0x04, internal = 0x10, hybrid = 0x20, smartCard = 0x40;

    test('USB and NFC pass', () {
      expect(WindowsWebAuthnBackend.refusal(transport: usb, resident: false), isNull);
      expect(WindowsWebAuthnBackend.refusal(transport: nfc, resident: false), isNull);
      // An assertion says nothing about residency.
      expect(WindowsWebAuthnBackend.refusal(transport: usb), isNull);
    });

    test('a phone, Bluetooth, Windows Hello or a smart card reader is refused', () {
      for (final transport in [hybrid, ble, internal, smartCard, usb | hybrid]) {
        final refused = WindowsWebAuthnBackend.refusal(transport: transport, resident: false);
        expect(refused?.failure, SecurityKeyFailure.unsupported, reason: '$transport');
        expect(refused!.message, contains('USB'));
      }
      expect(
        WindowsWebAuthnBackend.refusal(transport: hybrid)!.message,
        contains('through a phone or tablet'),
      );
    });

    test('an unreported transport is refused', () {
      expect(WindowsWebAuthnBackend.refusal(transport: null), isNotNull);
      expect(WindowsWebAuthnBackend.refusal(transport: 0), isNotNull);
    });

    test('a credential stored on the key is refused', () {
      final refused = WindowsWebAuthnBackend.refusal(transport: usb, resident: true);
      expect(refused?.failure, SecurityKeyFailure.unsupported);
      expect(refused!.message, contains('leave nothing on it'));
    });
  });
}
