import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../fhse_vault.dart' show KeyVerification;
import '../key_reply.dart';
import '../security_key_backend.dart';
import '../security_key_service.dart'
    show
        SecurityKeyException,
        SecurityKeyFailure,
        SecurityKeyInfo,
        SecurityKeyStatus,
        SecurityKeyTransport;
import 'webauthn_bindings.dart';

/// Security keys through Windows' own WebAuthn API (webauthn.dll).
///
/// Windows lets only elevated processes talk to FIDO devices directly, so the
/// app asks webauthn.dll, and the Windows Security dialog asks for the PIN or
/// fingerprint and the touch ([systemPrompts]). Raw hmac-secret salts need
/// WebAuthn API version 4 (Windows 11 22H2).
///
/// Each call blocks while the dialog is up, so it runs in a background isolate,
/// inside COM's single-threaded apartment. Only cross-platform authenticators
/// are allowed, never Windows Hello, and every call requires user
/// verification.
///
/// Enrollment shows two dialogs: one creates the credential, the next reads its
/// hmac-secret. webauthn.dll was reported to drop hmac-secret for a
/// non-discoverable credential. So when Windows does not report the extension
/// as on, the key is asked for the secret anyway, and only when none comes
/// back does enrollment retry with a discoverable credential (two more
/// dialogs). [debugLog] tells which path a key took.
///
/// Windows verifies the user itself, so the `verification` argument (the UI
/// passes [KeyVerification.system]) is ignored. Windows reads no serial
/// number, so `expectSerial` is ignored too and every [KeyReply] has a
/// null serial.
class WindowsWebAuthnBackend implements SecurityKeyBackend {
  /// Receives diagnostics: the API version, the owner window, and which
  /// enrollment path (non-discoverable or discoverable) Windows took. Nothing
  /// secret. `SecurityKeyService` sends them to the app's log.
  static void Function(String message)? debugLog;

  static const _timeoutMs = 120000;
  static const _userName = 'Wallet';
  static const _neededWindows = 'Security keys need Windows 11 version 22H2 or later';

  ({Win32 win, WebAuthnApi api, String path})? _system;

  /// The running operation's cancellation id and cancelled flag. Non-null
  /// while one runs, which makes a second call fail with busy.
  ({Pointer<Guid> id, bool hasId, Pointer<Int32> cancelled})? _running;

  @override
  Stream<SecurityKeyStatus> get status => const Stream.empty();

  @override
  bool get systemPrompts => true;

  @override
  Future<({bool nfc, bool usb})> capabilities() async => (nfc: false, usb: true);

  /// Windows gives the app no access to the key, so this describes a capable
  /// one without prompting. It still fails when this Windows is too old.
  @override
  Future<SecurityKeyInfo> inspect({required bool touch, required String prompt}) async {
    _load();
    return const SecurityKeyInfo(
      pinSet: true,
      pinRetries: null,
      supportsHmacSecret: true,
      supportsCredProtect: true,
      transport: SecurityKeyTransport.usb,
    );
  }

  /// Windows asks the user to set a PIN in its own dialog when one is needed.
  @override
  Future<void> setPin(String newPin, {int? expectSerial, required String prompt}) async =>
      throw const SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: 'Windows sets the PIN in its own dialog',
      );

  @override
  Future<KeyReply> enroll({
    required String rpId,
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
    int? expectSerial,
    required String prompt,
  }) => _perform(
    enroll: true,
    rpId: rpId,
    userId: userId,
    salt: salt,
    credentialIds: excludeCredentialIds,
  );

  @override
  Future<KeyReply> getHmacSecret({
    required String rpId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
    int? expectSerial,
    required String prompt,
  }) {
    if (credentialIds.isEmpty) {
      return Future.error(const SecurityKeyException(SecurityKeyFailure.noCredentials));
    }
    return _perform(
      enroll: false,
      rpId: rpId,
      userId: null,
      salt: salt,
      credentialIds: credentialIds,
    );
  }

  @override
  Future<void> cancel() async {
    final running = _running;
    if (running == null) return;
    // The flag stops a worker between its two enrollment dialogs, where
    // there is no operation to cancel.
    running.cancelled.value = 1;
    if (running.hasId) _system!.api.cancelCurrentOperation(running.id);
  }

  /// Maps a webauthn.dll HRESULT to the cross-platform failure codes.
  /// [errorName] is WebAuthNGetErrorName's text for it.
  static SecurityKeyException failureFor(
    int hresult, {
    required String errorName,
    required String rpId,
  }) {
    final hr = hresult.toUnsigned(32);
    final code = '0x${hr.toRadixString(16).toUpperCase().padLeft(8, '0')}';
    final described = errorName.isEmpty ? code : '$errorName, $code';
    final rpHint = _isDomain(rpId)
        ? 'The relying party id "$rpId" is a domain, so it is unlikely to be the cause.'
        : 'The relying party id "$rpId" is not a domain, which this Windows may refuse.';
    SecurityKeyException fail(SecurityKeyFailure failure, String message) =>
        SecurityKeyException(failure, message: message);
    return switch (hr) {
      nteUserCancelled || hrCancelled => fail(SecurityKeyFailure.cancelled, described),
      nteExists => fail(SecurityKeyFailure.credentialExcluded, described),
      nteNotFound => fail(SecurityKeyFailure.noCredentials, described),
      hrTimeout || hrWaitTimeout => fail(SecurityKeyFailure.timeout, described),
      nteTokenKeysetStorageFull => fail(
        SecurityKeyFailure.unsupported,
        'The key has no room for another credential ($described).',
      ),
      nteNotSupported || hrNotSupported => fail(
        SecurityKeyFailure.unsupported,
        'Windows or the key cannot meet the request ($described): the key may lack '
        'hmac-secret, credProtect or user verification. $rpHint',
      ),
      nteInvalidParameter || eInvalidArg => fail(
        SecurityKeyFailure.unsupported,
        'Windows rejected the request ($described). $rpHint',
      ),
      nteDeviceNotFound ||
      nteDeviceNotReady ||
      hrDeviceNotConnected ||
      hrNotReady ||
      hrGenFailure => fail(SecurityKeyFailure.transport, described),
      _ => fail(SecurityKeyFailure.unknown, 'Windows WebAuthn error $code ($errorName)'),
    };
  }

  static bool _isDomain(String rpId) =>
      RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$', caseSensitive: false).hasMatch(rpId);

  /// Opens webauthn.dll by its full System32 path, never by bare name, so a
  /// planted copy elsewhere on the search path is never loaded.
  ({Win32 win, WebAuthnApi api, String path}) _load() {
    if (_system case final system?) return system;
    final Win32 win;
    final WebAuthnApi api;
    final String path;
    final int version;
    try {
      win = Win32();
      path = '${win.systemDirectory}\\webauthn.dll';
      api = WebAuthnApi.open(path);
      version = api.getApiVersionNumber();
    } on ArgumentError catch (e) {
      throw SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: '$_neededWindows: webauthn.dll did not load (${e.message}).',
      );
    }
    if (version < webAuthnMinimumApiVersion) {
      throw SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: '$_neededWindows (WebAuthn API $webAuthnMinimumApiVersion; this has $version).',
      );
    }
    debugLog?.call('webauthn.dll API version $version');
    return _system = (win: win, api: api, path: path);
  }

  Future<KeyReply> _perform({
    required bool enroll,
    required String rpId,
    required Uint8List? userId,
    required Uint8List salt,
    required List<Uint8List> credentialIds,
  }) async {
    if (_running != null) throw const SecurityKeyException(SecurityKeyFailure.busy);
    if (salt.length != webAuthnCtapOneHmacSecretLength) {
      throw ArgumentError.value(salt.length, 'salt', 'must be 32 bytes');
    }
    final system = _load();
    final id = calloc<Guid>();
    final cancelled = calloc<Int32>();
    try {
      final hasId = system.api.getCancellationId(id) >= 0;
      _running = (id: id, hasId: hasId, cancelled: cancelled);
      final request = _Request(
        enroll: enroll,
        dllPath: system.path,
        hWnd: _ownerWindow(system.win),
        cancellationId: hasId ? Uint8List.fromList(id.cast<Uint8>().asTypedList(16)) : null,
        cancelledAddress: cancelled.address,
        rpId: rpId,
        userId: userId,
        salt: salt,
        credentialIds: credentialIds,
      );
      final outcome = await _spawn(request);
      final log = debugLog;
      if (log != null) outcome.log.forEach(log);
      if (outcome.error case final error?) throw error;
      return outcome.assertion!;
    } finally {
      _running = null;
      calloc
        ..free(id)
        ..free(cancelled);
    }
  }

  /// A static function, so the isolate's closure captures only [request].
  static Future<_Outcome> _spawn(_Request request) =>
      Isolate.run(() => _Worker.run(request), debugName: 'webauthn');

  /// The window Windows Security centres its dialog on: this process's own
  /// visible Flutter window, else the foreground window when it is ours, else
  /// any visible window of ours.
  static int _ownerWindow(Win32 win) {
    final pid = win.getCurrentProcessId();
    final own = <int>[];
    final callback = NativeCallable<EnumWindowsProc>.isolateLocal((int hWnd, int _) {
      if (win.isWindowVisible(hWnd) != 0 && win.windowProcessId(hWnd) == pid) own.add(hWnd);
      return 1;
    }, exceptionalReturn: 0);
    try {
      win.enumWindows(callback.nativeFunction, 0);
    } finally {
      callback.close();
    }
    final flutter = own.where((h) => win.className(h) == _flutterWindowClass).firstOrNull;
    final foreground = win.getForegroundWindow();
    final (hWnd, kind) = flutter != null
        ? (flutter, 'Flutter')
        : foreground != 0 && win.windowProcessId(foreground) == pid
        ? (foreground, 'foreground')
        : (own.firstOrNull ?? 0, own.isEmpty ? 'none' : 'own');
    debugLog?.call('owner window 0x${hWnd.toRadixString(16)} ($kind)');
    return hWnd;
  }

  static const _flutterWindowClass = 'FLUTTER_RUNNER_WIN32_WINDOW';
}

typedef _Outcome = ({KeyReply? assertion, SecurityKeyException? error, List<String> log});

/// What MakeCredential reported about the new credential.
typedef _Credential = ({
  Uint8List id,
  Uint8List authenticatorData,
  bool hmacSecret,
  int? credProtect,
  bool? resident,
  int? transport,
});

/// One operation, as sent to the worker isolate.
final class _Request {
  const _Request({
    required this.enroll,
    required this.dllPath,
    required this.hWnd,
    required this.cancellationId,
    required this.cancelledAddress,
    required this.rpId,
    required this.userId,
    required this.salt,
    required this.credentialIds,
  });

  final bool enroll;
  final String dllPath;
  final int hWnd;

  /// The GUID's 16 bytes from WebAuthNGetCancellationId, or null without one.
  final Uint8List? cancellationId;

  /// A native Int32 the calling isolate sets to cancel.
  final int cancelledAddress;
  final String rpId;
  final Uint8List? userId;
  final Uint8List salt;

  /// The exclude list when enrolling, the allow list otherwise.
  final List<Uint8List> credentialIds;
}

/// The worker isolate's side: one synchronous run per operation.
final class _Worker {
  _Worker(this._api, this._arena, this._request);

  final WebAuthnApi _api;
  final Arena _arena;
  final _Request _request;
  final _log = <String>[];
  late final _cancelled = Pointer<Int32>.fromAddress(_request.cancelledAddress);
  late final Pointer<Guid> _cancellationId = _copyGuid();
  late final Pointer<Utf16> _publicKey = webAuthnCredentialTypePublicKey.toNativeUtf16(
    allocator: _arena,
  );

  /// COM is entered and left within this one synchronous call, so both happen
  /// on the same OS thread.
  static _Outcome run(_Request request) {
    final win = Win32();
    final api = WebAuthnApi.open(request.dllPath);
    final com = win.coInitializeEx(nullptr, coinitApartmentThreaded);
    try {
      return using((arena) {
        final worker = _Worker(api, arena, request);
        try {
          final assertion = request.enroll
              ? worker._enroll()
              : worker._getHmacSecret(request.credentialIds);
          return (assertion: assertion, error: null, log: worker._log);
        } on SecurityKeyException catch (e) {
          return (assertion: null, error: e, log: worker._log);
        }
      });
    } finally {
      // S_OK or S_FALSE; RPC_E_CHANGED_MODE left the thread as it was.
      if (com >= 0) win.coUninitialize();
    }
  }

  KeyReply _enroll() {
    final first = _makeCredential(discoverable: false);
    _log.add('enroll: non-discoverable attempt, hmac-secret reported ${first.hmacSecret}');
    // Whether Windows reports the extension or not, the key's answer decides.
    final secret = _getHmacSecret([first.id], allowMissing: !first.hmacSecret);
    if (secret != null) {
      _logPath('non-discoverable', first);
      return _created(first, secret);
    }
    _log.add('enroll: no hmac-secret from the non-discoverable credential');
    final second = _makeCredential(discoverable: true);
    _log.add('enroll: discoverable retry, hmac-secret reported ${second.hmacSecret}');
    _logPath('discoverable', second);
    return _created(second, _getHmacSecret([second.id])!);
  }

  /// The reply for a new credential: [secret] read from it, with its
  /// makeCredential authenticator data for `checkEnrollment`.
  static KeyReply _created(_Credential made, KeyReply secret) => KeyReply(
    credentialId: secret.credentialId,
    hmacSecret: secret.hmacSecret,
    authenticatorData: secret.authenticatorData,
    creationAuthenticatorData: made.authenticatorData,
  );

  void _logPath(String path, _Credential made) => _log.add(
    'enroll path: $path (resident ${made.resident}, credProtect ${made.credProtect}, '
    'transport ${made.transport})',
  );

  _Credential _makeCredential({required bool discoverable}) {
    _checkCancelled();
    final request = _request;
    final userId = request.userId!;
    final rp = _arena<WebAuthnRpEntityInformation>();
    rp.ref
      ..dwVersion = webAuthnRpEntityInformationVersion
      ..pwszId = _string(request.rpId)
      ..pwszName = _string(request.rpId);
    final user = _arena<WebAuthnUserEntityInformation>();
    user.ref
      ..dwVersion = webAuthnUserEntityInformationVersion
      ..cbId = userId.length
      ..pbId = _bytes(userId)
      ..pwszName = _string(WindowsWebAuthnBackend._userName)
      ..pwszDisplayName = _string(WindowsWebAuthnBackend._userName);
    final param = _arena<WebAuthnCoseCredentialParameter>();
    param.ref
      ..dwVersion = webAuthnCoseCredentialParameterVersion
      ..pwszCredentialType = _publicKey
      ..lAlg = webAuthnCoseAlgorithmEs256;
    final params = _arena<WebAuthnCoseCredentialParameters>();
    params.ref
      ..cCredentialParameters = 1
      ..pCredentialParameters = param;

    final hmacSecret = _arena<Int32>()..value = 1;
    final credProtect = _arena<WebAuthnCredProtectExtensionIn>();
    credProtect.ref
      ..dwCredProtect = webAuthnUserVerificationRequired
      ..bRequireCredProtect = 1;
    final extensions = _arena<WebAuthnExtension>(2);
    extensions[0]
      ..pwszExtensionIdentifier = _string(webAuthnExtensionHmacSecret)
      ..cbExtension = sizeOf<Int32>()
      ..pvExtension = hmacSecret.cast();
    extensions[1]
      ..pwszExtensionIdentifier = _string(webAuthnExtensionCredProtect)
      ..cbExtension = sizeOf<WebAuthnCredProtectExtensionIn>()
      ..pvExtension = credProtect.cast();

    final options = _arena<WebAuthnMakeCredentialOptions>();
    options.ref
      ..dwVersion = makeCredentialOptionsVersion
      ..dwTimeoutMilliseconds = WindowsWebAuthnBackend._timeoutMs
      ..dwAuthenticatorAttachment = webAuthnAuthenticatorAttachmentCrossPlatform
      ..bRequireResidentKey = discoverable ? 1 : 0
      ..dwUserVerificationRequirement = webAuthnUserVerificationRequirementRequired
      ..dwAttestationConveyancePreference = webAuthnAttestationConveyanceNone
      ..pCancellationId = _cancellationId
      ..pExcludeCredentialList = _credentialList(request.credentialIds);
    options.ref.extensions
      ..cExtensions = 2
      ..pExtensions = extensions;

    final out = _arena<Pointer<WebAuthnCredentialAttestation>>();
    final hr = _api.makeCredential(
      request.hWnd,
      rp,
      user,
      params,
      _clientData('webauthn.create'),
      options,
      out,
    );
    final attestation = out.value;
    try {
      if (hr < 0) throw _failure(hr);
      if (attestation == nullptr) throw _noResponse;
      final a = attestation.ref;
      var hmacSecretOn = false;
      int? credProtectLevel;
      if (a.dwVersion >= credentialAttestationExtensionsVersion &&
          a.extensions.pExtensions != nullptr) {
        for (var i = 0; i < a.extensions.cExtensions; i++) {
          final e = a.extensions.pExtensions[i];
          if (e.pwszExtensionIdentifier == nullptr || e.pvExtension == nullptr) continue;
          if (e.cbExtension != sizeOf<Uint32>()) continue;
          final value = e.pvExtension.cast<Uint32>().value;
          switch (e.pwszExtensionIdentifier.toDartString()) {
            case webAuthnExtensionHmacSecret:
              hmacSecretOn = value != 0;
            case webAuthnExtensionCredProtect:
              credProtectLevel = value;
          }
        }
      }
      return (
        id: _copy(a.pbCredentialId, a.cbCredentialId),
        hmacSecret: hmacSecretOn,
        credProtect: credProtectLevel,
        authenticatorData: _copy(a.pbAuthenticatorData, a.cbAuthenticatorData),
        resident: a.dwVersion >= credentialAttestationResidentKeyVersion
            ? a.bResidentKey != 0
            : null,
        transport: a.dwVersion >= credentialAttestationTransportVersion ? a.dwUsedTransport : null,
      );
    } finally {
      if (attestation != nullptr) _api.freeCredentialAttestation(attestation);
    }
  }

  /// The key's hmac-secret over the salt, with the authenticator data
  /// `checkAssertion` reads. With [allowMissing], an answer without one gives
  /// null rather than a failure, for enrollment to try a discoverable
  /// credential instead.
  KeyReply? _getHmacSecret(List<Uint8List> credentialIds, {bool allowMissing = false}) {
    _checkCancelled();
    final request = _request;
    final salt = _arena<WebAuthnHmacSecretSalt>();
    salt.ref
      ..cbFirst = request.salt.length
      ..pbFirst = _bytes(request.salt);
    final salts = _arena<WebAuthnHmacSecretSaltValues>();
    salts.ref.pGlobalHmacSalt = salt;

    final options = _arena<WebAuthnGetAssertionOptions>();
    options.ref
      ..dwVersion = getAssertionOptionsVersion
      ..dwTimeoutMilliseconds = WindowsWebAuthnBackend._timeoutMs
      ..dwAuthenticatorAttachment = webAuthnAuthenticatorAttachmentCrossPlatform
      ..dwUserVerificationRequirement = webAuthnUserVerificationRequirementRequired
      ..dwFlags = webAuthnAuthenticatorHmacSecretValuesFlag
      ..pCancellationId = _cancellationId
      ..pAllowCredentialList = _credentialList(credentialIds)
      ..pHmacSecretSaltValues = salts;

    final out = _arena<Pointer<WebAuthnAssertion>>();
    final hr = _api.getAssertion(
      request.hWnd,
      _string(request.rpId),
      _clientData('webauthn.get'),
      options,
      out,
    );
    final assertion = out.value;
    try {
      if (hr < 0) throw _failure(hr);
      if (assertion == nullptr) throw _noResponse;
      final a = assertion.ref;
      // CTAP lets a key omit the credential when the allow list has one entry.
      final returned = _copy(a.credential.pbId, a.credential.cbId);
      final id = returned.isEmpty && credentialIds.length == 1 ? credentialIds.first : returned;
      final secret = a.dwVersion >= assertionHmacSecretVersion ? a.pHmacSecret : nullptr;
      if (secret == nullptr ||
          secret.ref.pbFirst == nullptr ||
          secret.ref.cbFirst != webAuthnCtapOneHmacSecretLength) {
        if (allowMissing) return null;
        throw const SecurityKeyException(
          SecurityKeyFailure.unsupported,
          message: 'Windows returned no hmac-secret',
        );
      }
      final view = secret.ref.pbFirst.asTypedList(webAuthnCtapOneHmacSecretLength);
      final hmacSecret = Uint8List.fromList(view);
      view.fillRange(0, view.length, 0);
      if (a.dwVersion >= assertionTransportVersion) {
        _log.add('assertion: transport ${a.dwUsedTransport}');
      }
      return KeyReply(
        credentialId: id,
        hmacSecret: hmacSecret,
        authenticatorData: _copy(a.pbAuthenticatorData, a.cbAuthenticatorData),
      );
    } finally {
      if (assertion != nullptr) _api.freeAssertion(assertion);
    }
  }

  void _checkCancelled() {
    if (_cancelled.value != 0) throw const SecurityKeyException(SecurityKeyFailure.cancelled);
  }

  SecurityKeyException _failure(int hr) =>
      WindowsWebAuthnBackend.failureFor(hr, errorName: _api.errorName(hr), rpId: _request.rpId);

  static const _noResponse = SecurityKeyException(
    SecurityKeyFailure.unknown,
    message: 'Windows returned no response',
  );

  /// A client data JSON for Windows to hash. Nothing checks its signature;
  /// FHSE uses only the hmac-secret.
  Pointer<WebAuthnClientData> _clientData(String type) {
    final random = Random.secure();
    final challenge = base64Url
        .encode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final json = utf8.encode(
      jsonEncode({
        'type': type,
        'challenge': challenge,
        'origin': _request.rpId,
        'crossOrigin': false,
      }),
    );
    final data = _arena<WebAuthnClientData>();
    data.ref
      ..dwVersion = webAuthnClientDataVersion
      ..cbClientDataJSON = json.length
      ..pbClientDataJSON = _bytes(json)
      ..pwszHashAlgId = _string(webAuthnHashAlgorithmSha256);
    return data;
  }

  Pointer<WebAuthnCredentialList> _credentialList(List<Uint8List> ids) {
    if (ids.isEmpty) return nullptr;
    final credentials = _arena<WebAuthnCredentialEx>(ids.length);
    final pointers = _arena<Pointer<WebAuthnCredentialEx>>(ids.length);
    for (var i = 0; i < ids.length; i++) {
      credentials[i]
        ..dwVersion = webAuthnCredentialExVersion
        ..cbId = ids[i].length
        ..pbId = _bytes(ids[i])
        ..pwszCredentialType = _publicKey;
      pointers[i] = credentials + i;
    }
    final list = _arena<WebAuthnCredentialList>();
    list.ref
      ..cCredentials = ids.length
      ..ppCredentials = pointers;
    return list;
  }

  Pointer<Guid> _copyGuid() {
    final id = _request.cancellationId;
    if (id == null) return nullptr;
    final guid = _arena<Uint8>(16);
    guid.asTypedList(16).setAll(0, id);
    return guid.cast();
  }

  Pointer<Utf16> _string(String value) => value.toNativeUtf16(allocator: _arena);

  Pointer<Uint8> _bytes(List<int> value) {
    final pointer = _arena<Uint8>(max(value.length, 1));
    pointer.asTypedList(value.length).setAll(0, value);
    return pointer;
  }

  static Uint8List _copy(Pointer<Uint8> data, int length) =>
      data == nullptr ? Uint8List(0) : Uint8List.fromList(data.asTypedList(length));
}
