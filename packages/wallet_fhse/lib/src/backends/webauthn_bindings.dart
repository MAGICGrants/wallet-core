// FFI bindings for Windows' WebAuthn API (webauthn.dll) and the few kernel32,
// user32 and ole32 functions WindowsWebAuthnBackend needs.
//
// The structs follow Microsoft's webauthn.h (github.com/microsoft/webauthn,
// MIT), commit 0ef86c2fe31e5b0608cc4fce4820935bd644cabb of 2025-09-11
// (WEBAUTHN_API_VERSION_9). Each struct is bound whole, at that header's
// current version, so its size and offsets can be checked against the header:
// test/windows_webauthn_layout_test.dart compares them with clang's Windows
// layout dumps in test/fixtures/webauthn_layout/.
//
// Windows types map to explicit widths: DWORD, LONG and BOOL are 32-bit on
// Windows (LLP64), WCHAR is UTF-16, and every pointer is 64-bit. Flutter builds
// Windows apps for x64 and arm64 only, which share one calling convention, so
// WINAPI (__stdcall) needs nothing here.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The version that added raw hmac-secret salts on GetAssertion:
/// pHmacSecretSaltValues (GetAssertion options 6, assertion 3) arrived with
/// API version 4, and WEBAUTHN_AUTHENTICATOR_HMAC_SECRET_VALUES_FLAG was added
/// to the header while it was still at version 4. Windows 11 22H2 ships it.
const webAuthnMinimumApiVersion = 4;

/// Struct versions this backend fills. Make-credential options 4 has the
/// cancellation id (2), the exclude list (3) and bPreferResidentKey (4);
/// get-assertion options 6 has the allow list (4) and the hmac-secret salts (6).
const makeCredentialOptionsVersion = 4;
const getAssertionOptionsVersion = 6;

const webAuthnRpEntityInformationVersion = 1;
const webAuthnUserEntityInformationVersion = 1;
const webAuthnClientDataVersion = 1;
const webAuthnCoseCredentialParameterVersion = 1;
const webAuthnCredentialExVersion = 1;

/// Output struct versions that carry the fields this backend reads.
const credentialAttestationExtensionsVersion = 2;
const credentialAttestationTransportVersion = 3;
const credentialAttestationResidentKeyVersion = 4;
const assertionHmacSecretVersion = 3;
const assertionTransportVersion = 4;

const webAuthnCoseAlgorithmEs256 = -7;
const webAuthnAuthenticatorAttachmentCrossPlatform = 2;
const webAuthnUserVerificationRequirementRequired = 1;
const webAuthnAttestationConveyanceNone = 1;

/// credProtect level 3: the credential is used only after user verification.
const webAuthnUserVerificationRequired = 3;

/// The salts are raw CTAP hmac-secret salts, not WebAuthn PRF inputs (which
/// Windows would hash first).
const webAuthnAuthenticatorHmacSecretValuesFlag = 0x00100000;
const webAuthnCtapOneHmacSecretLength = 32;

const webAuthnCredentialTypePublicKey = 'public-key';
const webAuthnHashAlgorithmSha256 = 'SHA-256';
const webAuthnExtensionHmacSecret = 'hmac-secret';
const webAuthnExtensionCredProtect = 'credProtect';

// HRESULTs, from winerror.h.
const nteExists = 0x8009000F;
const nteNotFound = 0x80090011;
const nteTokenKeysetStorageFull = 0x80090023;
const nteInvalidParameter = 0x80090027;
const nteNotSupported = 0x80090029;
const nteDeviceNotReady = 0x80090030;
const nteDeviceNotFound = 0x80090035;
const nteUserCancelled = 0x80090036;
const eInvalidArg = 0x80070057;

/// HRESULT_FROM_WIN32(code): 0x80070000 | code.
const hrNotReady = 0x80070015; // ERROR_NOT_READY (21)
const hrGenFailure = 0x8007001F; // ERROR_GEN_FAILURE (31)
const hrNotSupported = 0x80070032; // ERROR_NOT_SUPPORTED (50)
const hrWaitTimeout = 0x80070102; // WAIT_TIMEOUT (258)
const hrDeviceNotConnected = 0x8007048F; // ERROR_DEVICE_NOT_CONNECTED (1167)
const hrCancelled = 0x800704C7; // ERROR_CANCELLED (1223)
const hrTimeout = 0x800705B4; // ERROR_TIMEOUT (1460)

const coinitApartmentThreaded = 0x2;

final class Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

final class WebAuthnRpEntityInformation extends Struct {
  @Uint32()
  external int dwVersion;
  external Pointer<Utf16> pwszId;
  external Pointer<Utf16> pwszName;
  external Pointer<Utf16> pwszIcon;
}

final class WebAuthnUserEntityInformation extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int cbId;
  external Pointer<Uint8> pbId;
  external Pointer<Utf16> pwszName;
  external Pointer<Utf16> pwszIcon;
  external Pointer<Utf16> pwszDisplayName;
}

final class WebAuthnClientData extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int cbClientDataJSON;
  external Pointer<Uint8> pbClientDataJSON;
  external Pointer<Utf16> pwszHashAlgId;
}

final class WebAuthnCoseCredentialParameter extends Struct {
  @Uint32()
  external int dwVersion;
  external Pointer<Utf16> pwszCredentialType;
  @Int32()
  external int lAlg;
}

final class WebAuthnCoseCredentialParameters extends Struct {
  @Uint32()
  external int cCredentialParameters;
  external Pointer<WebAuthnCoseCredentialParameter> pCredentialParameters;
}

final class WebAuthnCredential extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int cbId;
  external Pointer<Uint8> pbId;
  external Pointer<Utf16> pwszCredentialType;
}

final class WebAuthnCredentials extends Struct {
  @Uint32()
  external int cCredentials;
  external Pointer<WebAuthnCredential> pCredentials;
}

final class WebAuthnCredentialEx extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int cbId;
  external Pointer<Uint8> pbId;
  external Pointer<Utf16> pwszCredentialType;
  @Uint32()
  external int dwTransports;
}

final class WebAuthnCredentialList extends Struct {
  @Uint32()
  external int cCredentials;
  external Pointer<Pointer<WebAuthnCredentialEx>> ppCredentials;
}

final class WebAuthnHmacSecretSalt extends Struct {
  @Uint32()
  external int cbFirst;
  external Pointer<Uint8> pbFirst;
  @Uint32()
  external int cbSecond;
  external Pointer<Uint8> pbSecond;
}

final class WebAuthnHmacSecretSaltValues extends Struct {
  external Pointer<WebAuthnHmacSecretSalt> pGlobalHmacSalt;
  @Uint32()
  external int cCredWithHmacSecretSaltList;
  external Pointer<Void> pCredWithHmacSecretSaltList;
}

final class WebAuthnCredProtectExtensionIn extends Struct {
  @Uint32()
  external int dwCredProtect;
  @Int32()
  external int bRequireCredProtect;
}

final class WebAuthnExtension extends Struct {
  external Pointer<Utf16> pwszExtensionIdentifier;
  @Uint32()
  external int cbExtension;
  external Pointer<Void> pvExtension;
}

final class WebAuthnExtensions extends Struct {
  @Uint32()
  external int cExtensions;
  external Pointer<WebAuthnExtension> pExtensions;
}

final class WebAuthnMakeCredentialOptions extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int dwTimeoutMilliseconds;
  external WebAuthnCredentials credentialList;
  external WebAuthnExtensions extensions;
  @Uint32()
  external int dwAuthenticatorAttachment;
  @Int32()
  external int bRequireResidentKey;
  @Uint32()
  external int dwUserVerificationRequirement;
  @Uint32()
  external int dwAttestationConveyancePreference;
  @Uint32()
  external int dwFlags;
  // Version 2.
  external Pointer<Guid> pCancellationId;
  // Version 3.
  external Pointer<WebAuthnCredentialList> pExcludeCredentialList;
  // Version 4.
  @Uint32()
  external int dwEnterpriseAttestation;
  @Uint32()
  external int dwLargeBlobSupport;
  @Int32()
  external int bPreferResidentKey;
  // Version 5.
  @Int32()
  external int bBrowserInPrivateMode;
  // Version 6.
  @Int32()
  external int bEnablePrf;
  // Version 7.
  external Pointer<Void> pLinkedDevice;
  @Uint32()
  external int cbJsonExt;
  external Pointer<Uint8> pbJsonExt;
  // Version 8.
  external Pointer<WebAuthnHmacSecretSalt> pPRFGlobalEval;
  @Uint32()
  external int cCredentialHints;
  external Pointer<Pointer<Utf16>> ppwszCredentialHints;
  @Int32()
  external int bThirdPartyPayment;
  // Version 9.
  external Pointer<Utf16> pwszRemoteWebOrigin;
  @Uint32()
  external int cbPublicKeyCredentialCreationOptionsJSON;
  external Pointer<Uint8> pbPublicKeyCredentialCreationOptionsJSON;
  @Uint32()
  external int cbAuthenticatorId;
  external Pointer<Uint8> pbAuthenticatorId;
}

final class WebAuthnGetAssertionOptions extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int dwTimeoutMilliseconds;
  external WebAuthnCredentials credentialList;
  external WebAuthnExtensions extensions;
  @Uint32()
  external int dwAuthenticatorAttachment;
  @Uint32()
  external int dwUserVerificationRequirement;
  @Uint32()
  external int dwFlags;
  // Version 2.
  external Pointer<Utf16> pwszU2fAppId;
  external Pointer<Int32> pbU2fAppId;
  // Version 3.
  external Pointer<Guid> pCancellationId;
  // Version 4.
  external Pointer<WebAuthnCredentialList> pAllowCredentialList;
  // Version 5.
  @Uint32()
  external int dwCredLargeBlobOperation;
  @Uint32()
  external int cbCredLargeBlob;
  external Pointer<Uint8> pbCredLargeBlob;
  // Version 6.
  external Pointer<WebAuthnHmacSecretSaltValues> pHmacSecretSaltValues;
  @Int32()
  external int bBrowserInPrivateMode;
  // Version 7.
  external Pointer<Void> pLinkedDevice;
  @Int32()
  external int bAutoFill;
  @Uint32()
  external int cbJsonExt;
  external Pointer<Uint8> pbJsonExt;
  // Version 8.
  @Uint32()
  external int cCredentialHints;
  external Pointer<Pointer<Utf16>> ppwszCredentialHints;
  // Version 9.
  external Pointer<Utf16> pwszRemoteWebOrigin;
  @Uint32()
  external int cbPublicKeyCredentialRequestOptionsJSON;
  external Pointer<Uint8> pbPublicKeyCredentialRequestOptionsJSON;
  @Uint32()
  external int cbAuthenticatorId;
  external Pointer<Uint8> pbAuthenticatorId;
}

/// Allocated by webauthn.dll; read fields past version 1 only when [dwVersion]
/// has them.
final class WebAuthnCredentialAttestation extends Struct {
  @Uint32()
  external int dwVersion;
  external Pointer<Utf16> pwszFormatType;
  @Uint32()
  external int cbAuthenticatorData;
  external Pointer<Uint8> pbAuthenticatorData;
  @Uint32()
  external int cbAttestation;
  external Pointer<Uint8> pbAttestation;
  @Uint32()
  external int dwAttestationDecodeType;
  external Pointer<Void> pvAttestationDecode;
  @Uint32()
  external int cbAttestationObject;
  external Pointer<Uint8> pbAttestationObject;
  @Uint32()
  external int cbCredentialId;
  external Pointer<Uint8> pbCredentialId;
  // Version 2.
  external WebAuthnExtensions extensions;
  // Version 3.
  @Uint32()
  external int dwUsedTransport;
  // Version 4.
  @Int32()
  external int bEpAtt;
  @Int32()
  external int bLargeBlobSupported;
  @Int32()
  external int bResidentKey;
  // Version 5.
  @Int32()
  external int bPrfEnabled;
  // Version 6.
  @Uint32()
  external int cbUnsignedExtensionOutputs;
  external Pointer<Uint8> pbUnsignedExtensionOutputs;
  // Version 7.
  external Pointer<WebAuthnHmacSecretSalt> pHmacSecret;
  @Int32()
  external int bThirdPartyPayment;
  // Version 8.
  @Uint32()
  external int dwTransports;
  @Uint32()
  external int cbClientDataJSON;
  external Pointer<Uint8> pbClientDataJSON;
  @Uint32()
  external int cbRegistrationResponseJSON;
  external Pointer<Uint8> pbRegistrationResponseJSON;
}

/// Allocated by webauthn.dll; read fields past version 1 only when [dwVersion]
/// has them.
final class WebAuthnAssertion extends Struct {
  @Uint32()
  external int dwVersion;
  @Uint32()
  external int cbAuthenticatorData;
  external Pointer<Uint8> pbAuthenticatorData;
  @Uint32()
  external int cbSignature;
  external Pointer<Uint8> pbSignature;
  external WebAuthnCredential credential;
  @Uint32()
  external int cbUserId;
  external Pointer<Uint8> pbUserId;
  // Version 2.
  external WebAuthnExtensions extensions;
  @Uint32()
  external int cbCredLargeBlob;
  external Pointer<Uint8> pbCredLargeBlob;
  @Uint32()
  external int dwCredLargeBlobStatus;
  // Version 3.
  external Pointer<WebAuthnHmacSecretSalt> pHmacSecret;
  // Version 4.
  @Uint32()
  external int dwUsedTransport;
  // Version 5.
  @Uint32()
  external int cbUnsignedExtensionOutputs;
  external Pointer<Uint8> pbUnsignedExtensionOutputs;
  // Version 6.
  @Uint32()
  external int cbClientDataJSON;
  external Pointer<Uint8> pbClientDataJSON;
  @Uint32()
  external int cbAuthenticationResponseJSON;
  external Pointer<Uint8> pbAuthenticationResponseJSON;
}

typedef MakeCredentialNative =
    Int32 Function(
      IntPtr hWnd,
      Pointer<WebAuthnRpEntityInformation>,
      Pointer<WebAuthnUserEntityInformation>,
      Pointer<WebAuthnCoseCredentialParameters>,
      Pointer<WebAuthnClientData>,
      Pointer<WebAuthnMakeCredentialOptions>,
      Pointer<Pointer<WebAuthnCredentialAttestation>>,
    );
typedef MakeCredentialDart =
    int Function(
      int hWnd,
      Pointer<WebAuthnRpEntityInformation>,
      Pointer<WebAuthnUserEntityInformation>,
      Pointer<WebAuthnCoseCredentialParameters>,
      Pointer<WebAuthnClientData>,
      Pointer<WebAuthnMakeCredentialOptions>,
      Pointer<Pointer<WebAuthnCredentialAttestation>>,
    );
typedef GetAssertionNative =
    Int32 Function(
      IntPtr hWnd,
      Pointer<Utf16> rpId,
      Pointer<WebAuthnClientData>,
      Pointer<WebAuthnGetAssertionOptions>,
      Pointer<Pointer<WebAuthnAssertion>>,
    );
typedef GetAssertionDart =
    int Function(
      int hWnd,
      Pointer<Utf16> rpId,
      Pointer<WebAuthnClientData>,
      Pointer<WebAuthnGetAssertionOptions>,
      Pointer<Pointer<WebAuthnAssertion>>,
    );

/// webauthn.dll. Every function looked up here exists since API version 1.
final class WebAuthnApi {
  /// Opens the dll at [path], which must be a full path.
  WebAuthnApi.open(String path) : this._(DynamicLibrary.open(path));

  WebAuthnApi._(DynamicLibrary lib)
    : getApiVersionNumber = lib.lookupFunction<Uint32 Function(), int Function()>(
        'WebAuthNGetApiVersionNumber',
      ),
      makeCredential = lib.lookupFunction<MakeCredentialNative, MakeCredentialDart>(
        'WebAuthNAuthenticatorMakeCredential',
      ),
      getAssertion = lib.lookupFunction<GetAssertionNative, GetAssertionDart>(
        'WebAuthNAuthenticatorGetAssertion',
      ),
      freeCredentialAttestation = lib
          .lookupFunction<
            Void Function(Pointer<WebAuthnCredentialAttestation>),
            void Function(Pointer<WebAuthnCredentialAttestation>)
          >('WebAuthNFreeCredentialAttestation'),
      freeAssertion = lib
          .lookupFunction<
            Void Function(Pointer<WebAuthnAssertion>),
            void Function(Pointer<WebAuthnAssertion>)
          >('WebAuthNFreeAssertion'),
      getCancellationId = lib
          .lookupFunction<Int32 Function(Pointer<Guid>), int Function(Pointer<Guid>)>(
            'WebAuthNGetCancellationId',
          ),
      cancelCurrentOperation = lib
          .lookupFunction<Int32 Function(Pointer<Guid>), int Function(Pointer<Guid>)>(
            'WebAuthNCancelCurrentOperation',
          ),
      _getErrorName = lib
          .lookupFunction<Pointer<Utf16> Function(Int32), Pointer<Utf16> Function(int)>(
            'WebAuthNGetErrorName',
          );

  final int Function() getApiVersionNumber;
  final MakeCredentialDart makeCredential;
  final GetAssertionDart getAssertion;
  final void Function(Pointer<WebAuthnCredentialAttestation>) freeCredentialAttestation;
  final void Function(Pointer<WebAuthnAssertion>) freeAssertion;
  final int Function(Pointer<Guid>) getCancellationId;
  final int Function(Pointer<Guid>) cancelCurrentOperation;
  final Pointer<Utf16> Function(int) _getErrorName;

  /// The W3C DOM error name Windows gives [hresult], such as "NotAllowedError".
  String errorName(int hresult) {
    final name = _getErrorName(hresult.toSigned(32));
    return name == nullptr ? '' : name.toDartString();
  }
}

typedef EnumWindowsProc = Int32 Function(IntPtr hWnd, IntPtr lParam);

/// The kernel32, user32 and ole32 functions the backend needs, looked up on
/// first use.
final class Win32 {
  /// kernel32 by bare name: it is a KnownDLL, mapped from System32 into every
  /// process before any code runs, so no search path is consulted. Every other
  /// library is opened by its full System32 path.
  Win32() : _kernel32 = DynamicLibrary.open('kernel32.dll');

  final DynamicLibrary _kernel32;
  late final _user32 = DynamicLibrary.open('$systemDirectory\\user32.dll');
  late final _ole32 = DynamicLibrary.open('$systemDirectory\\ole32.dll');

  late final String systemDirectory = _systemDirectory();

  late final getCurrentProcessId = _kernel32.lookupFunction<Uint32 Function(), int Function()>(
    'GetCurrentProcessId',
  );
  late final _getSystemDirectory = _kernel32
      .lookupFunction<Uint32 Function(Pointer<Utf16>, Uint32), int Function(Pointer<Utf16>, int)>(
        'GetSystemDirectoryW',
      );

  late final enumWindows = _user32
      .lookupFunction<
        Int32 Function(Pointer<NativeFunction<EnumWindowsProc>>, IntPtr),
        int Function(Pointer<NativeFunction<EnumWindowsProc>>, int)
      >('EnumWindows');
  late final getWindowThreadProcessId = _user32
      .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
        'GetWindowThreadProcessId',
      );
  late final isWindowVisible = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
    'IsWindowVisible',
  );
  late final getForegroundWindow = _user32.lookupFunction<IntPtr Function(), int Function()>(
    'GetForegroundWindow',
  );
  late final _getClassName = _user32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Int32),
        int Function(int, Pointer<Utf16>, int)
      >('GetClassNameW');

  late final coInitializeEx = _ole32
      .lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>(
        'CoInitializeEx',
      );
  late final coUninitialize = _ole32.lookupFunction<Void Function(), void Function()>(
    'CoUninitialize',
  );

  /// The process id that owns [hWnd].
  int windowProcessId(int hWnd) {
    final pid = calloc<Uint32>();
    try {
      getWindowThreadProcessId(hWnd, pid);
      return pid.value;
    } finally {
      calloc.free(pid);
    }
  }

  String className(int hWnd) {
    const capacity = 256;
    final buffer = calloc<Uint16>(capacity).cast<Utf16>();
    try {
      final length = _getClassName(hWnd, buffer, capacity);
      return length <= 0 ? '' : buffer.toDartString(length: length);
    } finally {
      calloc.free(buffer);
    }
  }

  String _systemDirectory() {
    const capacity = 260; // MAX_PATH
    final buffer = calloc<Uint16>(capacity).cast<Utf16>();
    try {
      final length = _getSystemDirectory(buffer, capacity);
      if (length == 0 || length >= capacity) {
        throw ArgumentError('GetSystemDirectoryW failed');
      }
      return buffer.toDartString(length: length);
    } finally {
      calloc.free(buffer);
    }
  }
}
