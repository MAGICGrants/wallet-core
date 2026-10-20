import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
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

/// Security keys on Linux, through the system's libfido2 (`libfido2.so.1`,
/// which openssh-client already pulls in on Debian, Ubuntu and Fedora).
///
/// libfido2 blocks, so each operation runs in an isolate of its own. The two
/// isolates share two native words: a cancel flag, which the worker's polling
/// loops read, and the address of the `fido_dev_t` the worker uses, which
/// [cancel] hands to `fido_dev_cancel` (libfido2 allows that from another
/// thread). That device is closed and freed here, once the worker has
/// returned, so a cancel never reaches a freed device.
///
/// libfido2 1.6 (Debian 11) is the oldest supported. Newer calls are used when
/// the library has them ([optionalSymbols]).
///
/// libfido2 cannot read a YubiKey's serial number, so [SecurityKeyInfo.serial]
/// is null and `expectSerial` cannot be checked. The key chosen in a touch
/// [inspect] is remembered instead, by its device path and by the kernel's name
/// for that plugging-in of it ([connectionId]). A later call goes to it while
/// it stays plugged in, and fails with [SecurityKeyFailure.differentKey] once
/// it is not, before any PIN is sent. Without such a key, a call uses the only
/// key plugged in, or has the user touch one of several; with a libfido2 too
/// old to ask for a touch, several keys are refused ([keyFor]).
class LinuxLibFido2Backend implements SecurityKeyBackend {
  /// Set by tests to a libfido2 that is not the system's (Homebrew's, on a
  /// Mac). Unused in the apps.
  static String? libraryPathOverride;

  /// What this backend needs. All are in libfido2 1.6.
  static const requiredSymbols = [
    'fido_init',
    'fido_strerr',
    'fido_dev_info_new',
    'fido_dev_info_manifest',
    'fido_dev_info_ptr',
    'fido_dev_info_path',
    'fido_dev_info_free',
    'fido_dev_new',
    'fido_dev_open',
    'fido_dev_close',
    'fido_dev_cancel',
    'fido_dev_free',
    'fido_dev_is_fido2',
    'fido_dev_get_retry_count',
    'fido_dev_set_pin',
    'fido_dev_get_cbor_info',
    'fido_dev_make_cred',
    'fido_dev_get_assert',
    'fido_cbor_info_new',
    'fido_cbor_info_free',
    'fido_cbor_info_extensions_ptr',
    'fido_cbor_info_extensions_len',
    'fido_cbor_info_options_name_ptr',
    'fido_cbor_info_options_value_ptr',
    'fido_cbor_info_options_len',
    'fido_cbor_info_maxcredcntlst',
    'fido_cbor_info_maxcredidlen',
    'fido_cred_new',
    'fido_cred_free',
    'fido_cred_set_type',
    'fido_cred_set_clientdata_hash',
    'fido_cred_set_rp',
    'fido_cred_set_user',
    'fido_cred_set_rk',
    'fido_cred_set_uv',
    'fido_cred_set_extensions',
    'fido_cred_set_prot',
    'fido_cred_exclude',
    'fido_cred_id_ptr',
    'fido_cred_id_len',
    'fido_cred_authdata_raw_ptr',
    'fido_cred_authdata_raw_len',
    'fido_assert_new',
    'fido_assert_free',
    'fido_assert_set_rp',
    'fido_assert_set_clientdata_hash',
    'fido_assert_allow_cred',
    'fido_assert_set_extensions',
    'fido_assert_set_hmac_salt',
    'fido_assert_set_uv',
    'fido_assert_count',
    'fido_assert_hmac_secret_ptr',
    'fido_assert_hmac_secret_len',
    'fido_assert_id_ptr',
    'fido_assert_authdata_ptr',
    'fido_assert_authdata_len',
    'fido_assert_id_len',
  ];

  /// Used when present. Touch selection (1.5) and the UV retry count (1.6)
  /// are in every supported version but are still looked up, so a stripped
  /// build degrades instead of failing. Minimum PIN length and forced PIN
  /// change are 1.12.
  static const optionalSymbols = [
    'fido_dev_get_touch_begin',
    'fido_dev_get_touch_status',
    'fido_dev_get_uv_retry_count',
    'fido_cbor_info_minpinlen',
    'fido_cbor_info_new_pin_required',
  ];

  static _Fido? _fido;
  static String? _library;

  final _status = StreamController<SecurityKeyStatus>.broadcast();

  /// The key the user chose in the last touch [inspect]: the one touched, or
  /// the only one plugged in. Null when its [connectionId] could not be read.
  ({String path, String id})? _chosen;

  /// The running operation's shared words: [0] the cancel flag, [1] the
  /// address of the worker's `fido_dev_t`. Null when none runs.
  Pointer<Int64>? _shared;
  Timer? _canceller;

  @override
  Stream<SecurityKeyStatus> get status => _status.stream;

  @override
  bool get systemPrompts => false;

  @override
  Future<({bool nfc, bool usb})> capabilities() async => (nfc: false, usb: true);

  @override
  Future<SecurityKeyInfo> inspect({required bool touch, required String prompt}) async =>
      await _run(_Inspect(touch)) as SecurityKeyInfo;

  /// [expectSerial] is ignored: libfido2 cannot read a serial number to
  /// compare (see the class comment).
  @override
  Future<void> setPin(String newPin, {int? expectSerial, required String prompt}) async {
    await _run(_SetPin(newPin));
  }

  @override
  Future<KeyReply> enroll({
    required String rpId,
    required Uint8List userId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> excludeCredentialIds,
    int? expectSerial,
    required String prompt,
  }) async {
    final pin = _pinOf(verification);
    _checkSalt(salt);
    return await _run(_Enroll(rpId, userId, salt, pin, excludeCredentialIds)) as KeyReply;
  }

  @override
  Future<KeyReply> getHmacSecret({
    required String rpId,
    required Uint8List salt,
    required KeyVerification verification,
    required List<Uint8List> credentialIds,
    int? expectSerial,
    required String prompt,
  }) async {
    final pin = _pinOf(verification);
    _checkSalt(salt);
    return await _run(_GetHmacSecret(rpId, salt, pin, credentialIds)) as KeyReply;
  }

  @override
  Future<void> cancel() async {
    final shared = _shared;
    if (shared == null) return;
    shared[0] = 1;
    // A cancel that reaches the key between two of its commands is dropped,
    // so it is sent again until the worker has returned.
    void send() {
      final dev = Pointer<_Dev>.fromAddress(shared[1]);
      if (dev != nullptr) _mainFido().devCancel(dev);
    }

    send();
    _canceller ??= Timer.periodic(const Duration(milliseconds: 100), (_) => send());
  }

  /// The failure a libfido2 return code means. [builtInUv]: the user is being
  /// verified by the key's own sensor. [pinSet]: the key has a PIN.
  static SecurityKeyFailure failureFor(int code, {bool builtInUv = false, bool pinSet = true}) =>
      switch (code) {
        _errPinInvalid => SecurityKeyFailure.pinInvalid,
        _errPinBlocked => SecurityKeyFailure.pinBlocked,
        _errPinAuthBlocked => SecurityKeyFailure.pinAuthBlocked,
        _errPinNotSet => SecurityKeyFailure.pinNotSet,
        // CTAP 2.1's PUAT_REQUIRED: the key wants a PIN token. After a
        // fingerprint that means the sensor is out of use and the PIN is next,
        // as on Android.
        _errPinRequired when builtInUv => SecurityKeyFailure.uvBlocked,
        _errPinRequired => pinSet ? SecurityKeyFailure.pinInvalid : SecurityKeyFailure.pinNotSet,
        _errPinPolicyViolation => SecurityKeyFailure.pinPolicy,
        _errUvInvalid => SecurityKeyFailure.uvInvalid,
        _errUvBlocked => SecurityKeyFailure.uvBlocked,
        // CTAP 2.1: built-in UV is switched off (no fingerprint enrolled).
        _errNotAllowed when builtInUv => SecurityKeyFailure.uvNotConfigured,
        _errCredentialExcluded => SecurityKeyFailure.credentialExcluded,
        _errNoCredentials => SecurityKeyFailure.noCredentials,
        _errKeepaliveCancel || _errOperationDenied => SecurityKeyFailure.cancelled,
        _errActionTimeout || _errUserActionTimeout => SecurityKeyFailure.timeout,
        _errUnsupportedOption ||
        _errUnsupportedExtension ||
        _errUnsupportedAlgorithm ||
        _errInvalidCommand ||
        _errLimitExceeded ||
        _errRequestTooLarge => SecurityKeyFailure.unsupported,
        _errTx ||
        _errRx ||
        _errRxNotCbor ||
        _errRxInvalidCbor ||
        _errInternal ||
        _errInvalidLength ||
        _errInvalidSeq ||
        _errTimeout ||
        _errChannelBusy ||
        _errInvalidChannel => SecurityKeyFailure.transport,
        _ => SecurityKeyFailure.unknown,
      };

  /// The authenticator data inside a CBOR byte string, as
  /// `fido_assert_authdata_ptr` returns it: libfido2 before 1.14 has no raw
  /// accessor for an assertion's. Throws a [FormatException] when [cbor] is
  /// not exactly one byte string.
  static Uint8List unwrapCborBytes(Uint8List cbor) {
    if (cbor.isEmpty || cbor[0] >> 5 != 2) throw const FormatException('not a CBOR byte string');
    final info = cbor[0] & 0x1f;
    final (header, length) = switch (info) {
      < 24 => (1, info),
      24 when cbor.length >= 2 => (2, cbor[1]),
      25 when cbor.length >= 3 => (3, cbor[1] << 8 | cbor[2]),
      _ => throw const FormatException('unsupported CBOR byte string length'),
    };
    if (header + length != cbor.length) throw const FormatException('CBOR byte string length');
    return Uint8List.sublistView(cbor, header);
  }

  /// Which of the keys plugged in ([paths]) an operation may open: a path, or
  /// null to have the user touch one. Never a key the user has not chosen
  /// while several are plugged in, so no PIN goes to the wrong one:
  ///
  /// - Without [touch], the key chosen earlier ([chosen]) while the same
  ///   plugging-in of it is there ([connectionId]); once it is not, the call
  ///   fails with [SecurityKeyFailure.differentKey].
  /// - Otherwise the only key plugged in. With [touch] it is touched too,
  ///   when libfido2 can ask ([canTouch]).
  /// - Otherwise a touch picks one of several; without [canTouch] they are
  ///   refused with [SecurityKeyFailure.multipleKeys].
  static String? keyFor({
    required List<String> paths,
    required bool touch,
    required bool canTouch,
    required ({String path, String id})? chosen,
    required String? Function(String path) connectionId,
  }) {
    if (!touch && chosen != null) {
      if (paths.contains(chosen.path) && connectionId(chosen.path) == chosen.id) return chosen.path;
      throw _differentKey;
    }
    if (paths.length == 1 && (!touch || !canTouch)) return paths.single;
    if (canTouch) return null;
    throw const SecurityKeyException(
      SecurityKeyFailure.multipleKeys,
      message: 'Several security keys are plugged in, and this libfido2 cannot ask which to use',
    );
  }

  /// What tells this plugging-in of the key at [path] (`/dev/hidrawN`) from
  /// any other: the kernel's name for the HID device behind it, such as
  /// `0003:1050:0407.000C`, whose last part counts up with every device it
  /// adds. A key pulled out and another put in, even at the same hidraw path,
  /// gets a new one. Null when it cannot be read.
  static String? connectionId(String path) {
    const prefix = '/dev/hidraw';
    if (!path.startsWith(prefix)) return null;
    try {
      final device = File('/sys/class/hidraw/${path.substring(5)}/device');
      return device.resolveSymbolicLinksSync().split('/').last;
    } on FileSystemException {
      return null;
    }
  }

  /// Whether a HID report descriptor declares the FIDO usage page (0xF1D0),
  /// the way libfido2 and systemd's fido_id tell a security key from other
  /// HID devices.
  static bool isFidoReportDescriptor(Uint8List descriptor) {
    var i = 0;
    while (i < descriptor.length) {
      final prefix = descriptor[i];
      if (prefix == 0xfe) {
        // A long item: its data size follows the prefix.
        if (i + 1 >= descriptor.length) return false;
        i += 3 + descriptor[i + 1];
        continue;
      }
      final size = const [0, 1, 2, 4][prefix & 3];
      if (i + 1 + size > descriptor.length) return false;
      if ((prefix & 0xfc) == 0x04) {
        // Usage Page, little-endian.
        var page = 0;
        for (var b = size; b > 0; b--) {
          page = page << 8 | descriptor[i + b];
        }
        if (page == 0xf1d0) return true;
      }
      i += 1 + size;
    }
    return false;
  }

  static String? _pinOf(KeyVerification verification) {
    if (verification.isSystem) {
      throw const SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: 'Linux has no system security key prompt',
      );
    }
    return verification.pin;
  }

  static void _checkSalt(Uint8List salt) {
    if (salt.length != 32) {
      throw const SecurityKeyException(
        SecurityKeyFailure.unknown,
        message: 'The hmac-secret salt must be 32 bytes',
      );
    }
  }

  /// This isolate's bindings, from the first library that loads.
  static _Fido _mainFido() {
    if (_fido case final fido?) return fido;
    final override = libraryPathOverride;
    final names = override != null ? [override] : const ['libfido2.so.1', 'libfido2.so'];
    SecurityKeyException? failure;
    for (final name in names) {
      try {
        final fido = _Fido.open(name);
        fido.init(0);
        _library = name;
        return _fido = fido;
      } on SecurityKeyException catch (e) {
        failure ??= e;
      }
    }
    throw failure!;
  }

  Future<Object?> _run(_Job job) async {
    if (_shared != null) {
      throw const SecurityKeyException(
        SecurityKeyFailure.busy,
        message: 'Another security key operation is in progress',
      );
    }
    final fido = _mainFido();
    final shared = calloc<Int64>(2);
    final statusPort = ReceivePort()
      ..listen((name) => _status.add(SecurityKeyStatus.values.byName(name as String)));
    _shared = shared;
    try {
      final reply = await _work(_Env(_library!, shared.address, statusPort.sendPort, _chosen), job);
      if (job case _Inspect(touch: true)) _chosen = reply.used;
      // The chosen key is gone; the next call starts afresh.
      if (reply.error?.failure == SecurityKeyFailure.differentKey) _chosen = null;
      if (reply.error case final error?) throw error;
      return reply.value;
    } on SecurityKeyException {
      rethrow;
    } catch (e) {
      throw SecurityKeyException(SecurityKeyFailure.unknown, message: '$e');
    } finally {
      _canceller?.cancel();
      _canceller = null;
      final dev = Pointer<_Dev>.fromAddress(shared[1]);
      if (dev != nullptr) fido.close(dev);
      statusPort.close();
      calloc.free(shared);
      _shared = null;
    }
  }

  /// Static, so the closure sent to the worker holds [env] and [job] and
  /// nothing of this backend.
  static Future<_Reply> _work(_Env env, _Job job) =>
      Isolate.run(() => _Worker.run(env, job), debugName: 'libfido2');
}

// fido/err.h
const _ok = 0x00;
const _errInvalidCommand = 0x01;
const _errInvalidLength = 0x03;
const _errInvalidSeq = 0x04;
const _errTimeout = 0x05;
const _errChannelBusy = 0x06;
const _errInvalidChannel = 0x0b;
const _errLimitExceeded = 0x15;
const _errUnsupportedExtension = 0x16;
const _errCredentialExcluded = 0x19;
const _errUnsupportedAlgorithm = 0x26;
const _errOperationDenied = 0x27;
const _errUnsupportedOption = 0x2b;
const _errKeepaliveCancel = 0x2d;
const _errNoCredentials = 0x2e;
const _errUserActionTimeout = 0x2f;
const _errNotAllowed = 0x30;
const _errPinInvalid = 0x31;
const _errPinBlocked = 0x32;
const _errPinAuthBlocked = 0x34;
const _errPinNotSet = 0x35;
const _errPinRequired = 0x36;
const _errPinPolicyViolation = 0x37;
const _errRequestTooLarge = 0x39;
const _errActionTimeout = 0x3a;
const _errUvBlocked = 0x3c;
const _errUvInvalid = 0x3f;
const _errTx = -1;
const _errRx = -2;
const _errRxNotCbor = -3;
const _errRxInvalidCbor = -4;
const _errInternal = -9;

// fido/param.h, fido/types.h
const _coseEs256 = -7;
const _extHmacSecret = 0x01;
const _credProtUvRequired = 0x03;
const _optFalse = 1;
const _optTrue = 2;

const _hmacSecret = 'hmac-secret';
const _credProtect = 'credProtect';

/// The user entity's name. The credential is not discoverable, so the key
/// keeps none of it; the other platforms send the same.
const _userName = 'FHSE Encryption';

const _cancelled = SecurityKeyException(
  SecurityKeyFailure.cancelled,
  message: 'The operation was cancelled',
);
const _outOfMemory = SecurityKeyException(SecurityKeyFailure.unknown, message: 'Out of memory');
const _differentKey = SecurityKeyException(
  SecurityKeyFailure.differentKey,
  message: 'The security key chosen earlier is no longer plugged in',
);

/// What a worker needs besides its job.
final class _Env {
  const _Env(this.library, this.shared, this.status, this.chosen);

  final String library;

  /// The address of the shared words (see [LinuxLibFido2Backend._shared]).
  final int shared;

  /// Takes [SecurityKeyStatus] names.
  final SendPort status;

  /// The key the user chose (see [LinuxLibFido2Backend.keyFor]).
  final ({String path, String id})? chosen;
}

final class _Reply {
  const _Reply({this.value, this.error, this.used});

  final Object? value;
  final SecurityKeyException? error;

  /// The key the operation used, when its connection id could be read.
  final ({String path, String id})? used;
}

sealed class _Job {
  const _Job();

  Object? run(_Worker worker);
}

final class _Inspect extends _Job {
  const _Inspect(this.touch);

  final bool touch;

  @override
  Object? run(_Worker worker) => worker.inspect(touch);
}

final class _SetPin extends _Job {
  const _SetPin(this.newPin);

  final String newPin;

  @override
  Object? run(_Worker worker) {
    worker.setPin(newPin);
    return null;
  }
}

final class _Enroll extends _Job {
  const _Enroll(this.rpId, this.userId, this.salt, this.pin, this.excludeCredentialIds);

  final String rpId;
  final Uint8List userId;
  final Uint8List salt;

  /// Null for built-in UV.
  final String? pin;
  final List<Uint8List> excludeCredentialIds;

  @override
  Object? run(_Worker worker) => worker.enroll(this);
}

final class _GetHmacSecret extends _Job {
  const _GetHmacSecret(this.rpId, this.salt, this.pin, this.credentialIds);

  final String rpId;
  final Uint8List salt;

  /// Null for built-in UV.
  final String? pin;
  final List<Uint8List> credentialIds;

  @override
  Object? run(_Worker worker) => worker.getHmacSecret(this);
}

/// What `fido_dev_get_cbor_info` reports, as far as FHSE cares.
typedef _Info = ({
  Set<String> extensions,
  Map<String, bool> options,
  int maxCredentials,
  int maxIdLength,
  int minPinLength,
  bool forcePinChange,
});

/// One operation, in its own isolate.
final class _Worker {
  _Worker(this.fido, this.env) : shared = Pointer<Int64>.fromAddress(env.shared);

  final _Fido fido;
  final _Env env;

  /// [0]: the cancel flag. [1]: the address of [dev], for the other isolate,
  /// which closes and frees it.
  final Pointer<Int64> shared;

  /// The key this operation uses, once chosen.
  Pointer<_Dev> dev = nullptr;
  ({String path, String id})? used;
  bool touched = false;

  /// The key's own sensor verifies the user, so a wait is for a finger.
  bool builtInUv = false;
  bool pinSet = true;
  SecurityKeyStatus? _sent;

  static _Reply run(_Env env, _Job job) {
    _Worker? worker;
    try {
      final fido = _Fido.open(env.library);
      fido.init(0);
      worker = _Worker(fido, env);
      return _Reply(value: job.run(worker), used: worker.used);
    } catch (e) {
      var error = e is SecurityKeyException
          ? e
          : SecurityKeyException(SecurityKeyFailure.unknown, message: '$e');
      // A cancel can surface as whatever the interrupted call returned.
      if (worker != null &&
          worker.cancelled &&
          const {
            SecurityKeyFailure.transport,
            SecurityKeyFailure.unknown,
            SecurityKeyFailure.timeout,
          }.contains(error.failure)) {
        error = _cancelled;
      }
      return _Reply(error: error, used: worker?.used);
    }
  }

  bool get cancelled => shared[0] != 0;

  // ----- Operations -----

  SecurityKeyInfo inspect(bool touch) {
    _acquire(touch: touch);
    final info = _readInfo();
    pinSet = info.options['clientPin'] == true;
    final uv = info.options['uv'] == true;
    return SecurityKeyInfo(
      pinSet: pinSet,
      pinRetries: pinSet ? _retries(fido.getRetryCount) : null,
      supportsHmacSecret: info.extensions.contains(_hmacSecret),
      supportsCredProtect: info.extensions.contains(_credProtect),
      transport: SecurityKeyTransport.usb,
      fingerprintReady: uv && info.options['pinUvAuthToken'] == true,
      fingerprintRetries: uv ? _retries(fido.getUvRetryCount) : null,
      minPinLength: info.minPinLength,
      forcePinChange: info.forcePinChange,
      touched: touched,
    );
  }

  void setPin(String newPin) {
    _acquire(touch: false);
    final info = _readInfo();
    final clientPin = info.options['clientPin'];
    if (clientPin == null) {
      throw const SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: 'This security key does not support a PIN',
      );
    }
    if (clientPin) {
      throw const SecurityKeyException(
        SecurityKeyFailure.pinAlreadySet,
        message: 'This security key already has a PIN',
      );
    }
    if (newPin.runes.length < info.minPinLength) {
      throw SecurityKeyException(
        SecurityKeyFailure.pinPolicy,
        message: 'The PIN must be at least ${info.minPinLength} characters',
      );
    }
    if (_utf8Length(newPin) > 63) {
      throw const SecurityKeyException(
        SecurityKeyFailure.pinPolicy,
        message: 'The PIN must be at most 63 bytes',
      );
    }
    _withPin(newPin, (pin) {
      _checkCancelled();
      _check(fido.devSetPin(dev, pin, nullptr));
    });
  }

  /// Creates the credential, then takes its hmac-secret: two touches.
  KeyReply enroll(_Enroll job) {
    _acquire(touch: false);
    final info = _readInfo();
    final missing = [_hmacSecret, _credProtect].where((e) => !info.extensions.contains(e));
    if (missing.isNotEmpty) {
      throw SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: 'This security key does not support ${missing.join(' and ')}',
      );
    }
    _requireVerification(info, job.pin);
    return _withPin(job.pin, (pin) {
      final (credentialId, creation) = _makeCredential(job, info, pin);
      _checkCancelled();
      final reply = _assert(job.rpId, job.salt, [credentialId], pin);
      return KeyReply(
        credentialId: reply.credentialId,
        hmacSecret: reply.hmacSecret,
        authenticatorData: reply.authenticatorData,
        creationAuthenticatorData: creation,
      );
    });
  }

  KeyReply getHmacSecret(_GetHmacSecret job) {
    _acquire(touch: false);
    final info = _readInfo();
    if (!info.extensions.contains(_hmacSecret)) {
      throw const SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: 'This security key does not support hmac-secret',
      );
    }
    _requireVerification(info, job.pin);
    final ids = _usable(job.credentialIds, info);
    // Keys refuse allow lists longer than they say; Android sends 8 when the
    // key does not say.
    final batch = info.maxCredentials > 0 ? info.maxCredentials : 8;
    return _withPin(job.pin, (pin) {
      for (var i = 0; i < ids.length; i += batch) {
        _checkCancelled();
        try {
          return _assert(job.rpId, job.salt, ids.sublist(i, min(i + batch, ids.length)), pin);
        } on SecurityKeyException catch (e) {
          if (e.failure != SecurityKeyFailure.noCredentials) rethrow;
        }
      }
      throw const SecurityKeyException(
        SecurityKeyFailure.noCredentials,
        message: 'None of the enrolled credentials is on this security key',
      );
    });
  }

  // ----- CTAP -----

  /// makeCredential: the new credential's id and the authenticator data the
  /// key signed, which `checkEnrollment` reads (user verified, credProtect
  /// level 3, hmac-secret on). Not `fido_cred_prot()`, which returns the level
  /// that was asked for rather than the one the key applied.
  (Uint8List, Uint8List) _makeCredential(_Enroll job, _Info info, Pointer<Utf8> pin) {
    final cred = fido.credNew();
    if (cred == nullptr) throw _outOfMemory;
    try {
      using((arena) {
        final name = _userName.toNativeUtf8(allocator: arena);
        _check(fido.credSetType(cred, _coseEs256));
        _check(fido.credSetClientdataHash(cred, _native(arena, _random(32)), 32));
        _check(fido.credSetRp(cred, job.rpId.toNativeUtf8(allocator: arena), nullptr));
        _check(
          fido.credSetUser(
            cred,
            _native(arena, job.userId),
            job.userId.length,
            name,
            name,
            nullptr,
          ),
        );
        _check(fido.credSetRk(cred, _optFalse));
        // hmac-secret first: libfido2 before 1.7 let set_extensions replace
        // the mask that set_prot adds to.
        _check(fido.credSetExtensions(cred, _extHmacSecret));
        _check(fido.credSetProt(cred, _credProtUvRequired));
        if (builtInUv) _check(fido.credSetUv(cred, _optTrue));
        for (final id in _usable(job.excludeCredentialIds, info)) {
          _check(fido.credExclude(cred, _native(arena, id), id.length));
        }
      });
      _checkCancelled();
      _reportUserNeeded();
      final r = fido.devMakeCred(dev, cred, pin);
      _report(SecurityKeyStatus.processing);
      _check(r);

      final id = _copy(fido.credIdPtr(cred), fido.credIdLen(cred));
      if (id.isEmpty) {
        throw const SecurityKeyException(
          SecurityKeyFailure.unknown,
          message: 'The security key returned no credential',
        );
      }
      return (id, _copy(fido.credAuthdataRawPtr(cred), fido.credAuthdataRawLen(cred)));
    } finally {
      _release(cred, fido.credFree);
    }
  }

  /// getAssertion with hmac-secret over [salt], from whichever of [ids] the
  /// key holds: the secret, the credential it answered with, and the
  /// authenticator data `checkAssertion` reads (the UV flag: without it the
  /// key answers from its non-UV secret, which differs from the enrolled one).
  KeyReply _assert(String rpId, Uint8List salt, List<Uint8List> ids, Pointer<Utf8> pin) {
    final assertion = fido.assertNew();
    if (assertion == nullptr) throw _outOfMemory;
    try {
      using((arena) {
        _check(fido.assertSetRp(assertion, rpId.toNativeUtf8(allocator: arena)));
        _check(fido.assertSetClientdataHash(assertion, _native(arena, _random(32)), 32));
        for (final id in ids) {
          _check(fido.assertAllowCred(assertion, _native(arena, id), id.length));
        }
        _check(fido.assertSetExtensions(assertion, _extHmacSecret));
        _check(fido.assertSetHmacSalt(assertion, _native(arena, salt), salt.length));
        if (builtInUv) _check(fido.assertSetUv(assertion, _optTrue));
      });
      _checkCancelled();
      _reportUserNeeded();
      final r = fido.devGetAssert(dev, assertion, pin);
      _report(SecurityKeyStatus.processing);
      _check(r);

      if (fido.assertCount(assertion) < 1) {
        throw const SecurityKeyException(
          SecurityKeyFailure.unknown,
          message: 'The security key returned no assertion',
        );
      }
      var id = _copy(fido.assertIdPtr(assertion, 0), fido.assertIdLen(assertion, 0));
      // A key may leave the credential out when the allow list has one entry.
      if (id.isEmpty && ids.length == 1) id = Uint8List.fromList(ids.single);
      return KeyReply(
        credentialId: id,
        hmacSecret: _copy(
          fido.assertHmacSecretPtr(assertion, 0),
          fido.assertHmacSecretLen(assertion, 0),
        ),
        authenticatorData: LinuxLibFido2Backend.unwrapCborBytes(
          _copy(fido.assertAuthdataPtr(assertion, 0), fido.assertAuthdataLen(assertion, 0)),
        ),
      );
    } finally {
      // fido_assert_free wipes libfido2's copy of the secret.
      _release(assertion, fido.assertFree);
    }
  }

  /// Checks the key can verify the user as asked: a PIN that is set, need not
  /// be changed first and could be its PIN, or built-in UV that is set up and
  /// hands out tokens. Built-in UV also needs the PIN set: on a key without
  /// one, whoever holds it could set a PIN and use that instead. A PIN that
  /// cannot be the key's is not sent, so it costs no attempt.
  void _requireVerification(_Info info, String? pin) {
    builtInUv = pin == null;
    pinSet = info.options['clientPin'] == true;
    if (!pinSet) {
      throw const SecurityKeyException(
        SecurityKeyFailure.pinNotSet,
        message: 'This security key has no PIN set',
      );
    }
    if (pin == null) {
      if (info.options['uv'] != true || info.options['pinUvAuthToken'] != true) {
        throw const SecurityKeyException(
          SecurityKeyFailure.uvNotConfigured,
          message: 'This security key has no fingerprint set up for use without its PIN',
        );
      }
      return;
    }
    if (info.forcePinChange) {
      throw const SecurityKeyException(
        SecurityKeyFailure.pinChangeRequired,
        message: 'This security key needs a new PIN before it can be used',
      );
    }
    // Shorter than the key's own minimum, it cannot be the key's PIN.
    if (pin.runes.length < info.minPinLength || _utf8Length(pin) > 63) {
      throw SecurityKeyException(
        SecurityKeyFailure.pinInvalid,
        message: 'Incorrect PIN',
        retries: _retries(fido.getRetryCount),
      );
    }
  }

  _Info _readInfo() {
    final info = fido.cborInfoNew();
    if (info == nullptr) throw _outOfMemory;
    try {
      _check(fido.devGetCborInfo(dev, info));
      final names = _strings(fido.cborInfoOptionsNamePtr(info), fido.cborInfoOptionsLen(info));
      final values = fido.cborInfoOptionsValuePtr(info);
      return (
        extensions: _strings(
          fido.cborInfoExtensionsPtr(info),
          fido.cborInfoExtensionsLen(info),
        ).toSet(),
        options: {for (var i = 0; i < names.length; i++) names[i]: values[i] != 0},
        maxCredentials: fido.cborInfoMaxCredCount(info),
        maxIdLength: fido.cborInfoMaxCredIdLength(info),
        minPinLength: max(4, fido.cborInfoMinPinLength?.call(info) ?? 0),
        forcePinChange: fido.cborInfoNewPinRequired?.call(info) ?? false,
      );
    } finally {
      _release(info, fido.cborInfoFree);
    }
  }

  // ----- Finding the key -----

  /// Opens the key for this operation, as [LinuxLibFido2Backend.keyFor]
  /// decides: the one chosen earlier, the only one, or the one the user
  /// touches now.
  void _acquire({required bool touch}) {
    while (true) {
      final paths = _waitForKeys();
      final path = LinuxLibFido2Backend.keyFor(
        paths: paths,
        touch: touch,
        canTouch: fido.canTouch,
        chosen: env.chosen,
        connectionId: LinuxLibFido2Backend.connectionId,
      );
      if (path == null) {
        if (_selectByTouch(paths)) return;
        continue;
      }
      _use(path);
      // Again with the key open, in case it was swapped in between.
      if (!touch && env.chosen != null && used?.id != env.chosen!.id) throw _differentKey;
      return;
    }
  }

  /// The keys plugged in, once there is one. Polls twice a second.
  List<String> _waitForKeys() {
    while (true) {
      _checkCancelled();
      final paths = _manifest();
      if (paths.isNotEmpty) return paths;
      if (_keyWithoutAccess()) {
        throw const SecurityKeyException(
          SecurityKeyFailure.transport,
          message:
              'A security key is plugged in, but this user may not open it (/dev/hidraw*). '
              'Install the udev rules that give the logged-in user access (uaccess), '
              "such as systemd's 60-fido-id.rules or libfido2's 70-u2f.rules.",
        );
      }
      _report(SecurityKeyStatus.waitingForKey);
      _pause(500);
    }
  }

  List<String> _manifest() {
    const slots = 64;
    final list = fido.devInfoNew(slots);
    if (list == nullptr) throw _outOfMemory;
    final found = calloc<Size>();
    try {
      _check(fido.devInfoManifest(list, slots, found));
      return [
        for (var i = 0; i < found.value; i++)
          fido.devInfoPath(fido.devInfoPtr(list, i)).toDartString(),
      ];
    } finally {
      calloc.free(found);
      final slot = calloc<Pointer<_DevInfo>>()..value = list;
      fido.devInfoFree(slot, slots);
      calloc.free(slot);
    }
  }

  /// Asks every key in [paths] for a touch and keeps the one touched. False
  /// when keys came or went meanwhile, so the caller starts over.
  bool _selectByTouch(List<String> paths) {
    final waiting = <String, Pointer<_Dev>>{};
    final touchedOut = calloc<Int32>();
    SecurityKeyException? failure;
    try {
      for (final path in paths) {
        final Pointer<_Dev> device;
        try {
          device = _open(path);
        } on SecurityKeyException catch (e) {
          failure = e;
          continue;
        }
        final r = fido.touchBegin!(device);
        if (r == _ok) {
          waiting[path] = device;
        } else {
          failure = _error(r);
          fido.close(device);
        }
      }
      if (waiting.isEmpty) throw failure!;
      _report(SecurityKeyStatus.keyConnected);
      _report(SecurityKeyStatus.touchNeeded);
      final sinceManifest = Stopwatch()..start();
      while (true) {
        _checkCancelled();
        final round = Stopwatch()..start();
        for (final path in [...waiting.keys]) {
          final device = waiting[path]!;
          // libfido2 waits up to 50 ms for the answer and reports a timeout as
          // not touched yet.
          final r = fido.touchStatus!(device, touchedOut, 50);
          if (r != _ok) {
            failure = _error(r);
            waiting.remove(path);
            fido.devCancel(device);
            fido.close(device);
          } else if (touchedOut.value != 0) {
            waiting.remove(path);
            touched = true;
            _select(path, device);
            return true;
          }
        }
        if (waiting.isEmpty) throw failure!;
        if (sinceManifest.elapsedMilliseconds >= 500) {
          sinceManifest.reset();
          final now = _manifest();
          if (now.length != paths.length || !now.every(paths.contains)) return false;
        }
        // A key that was pulled out answers at once; do not spin on it.
        final left = 50 - round.elapsedMilliseconds;
        if (left > 0) sleep(Duration(milliseconds: left));
      }
    } finally {
      calloc.free(touchedOut);
      for (final device in waiting.values) {
        fido.devCancel(device);
        fido.close(device);
      }
    }
  }

  Pointer<_Dev> _open(String path) {
    final device = fido.devNew();
    if (device == nullptr) throw _outOfMemory;
    final r = using((arena) => fido.devOpen(device, path.toNativeUtf8(allocator: arena)));
    if (r != _ok) {
      _release(device, fido.devFree);
      throw SecurityKeyException(
        SecurityKeyFailure.transport,
        message: 'Could not open the security key (${_describe(r)})',
      );
    }
    return device;
  }

  void _use(String path) {
    final device = _open(path);
    _report(SecurityKeyStatus.keyConnected);
    _select(path, device);
  }

  /// Makes [device] this operation's key. From here the other isolate owns
  /// it: it can cancel it, and it frees it.
  void _select(String path, Pointer<_Dev> device) {
    dev = device;
    if (LinuxLibFido2Backend.connectionId(path) case final id?) used = (path: path, id: id);
    shared[1] = device.address;
    if (!fido.devIsFido2(device)) {
      throw const SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: 'This security key does not support FIDO2',
      );
    }
    _report(SecurityKeyStatus.processing);
  }

  /// A FIDO key is plugged in that this user may not open: libfido2 skips
  /// such hidraw nodes without a word. Without the udev rule that grants the
  /// logged-in user access, the wait would never end.
  static bool _keyWithoutAccess() {
    if (!Platform.isLinux) return false;
    try {
      var found = false;
      for (final node in Directory('/sys/class/hidraw').listSync()) {
        final name = node.path.split('/').last;
        final descriptor = File('${node.path}/device/report_descriptor').readAsBytesSync();
        if (!LinuxLibFido2Backend.isFidoReportDescriptor(descriptor)) continue;
        if (using((arena) => _access('/dev/$name'.toNativeUtf8(allocator: arena), 6) == 0)) {
          // Readable and writable (R_OK | W_OK), yet not listed: not ours.
          return false;
        }
        found = true;
      }
      return found;
    } on FileSystemException {
      return false;
    }
  }

  static final _access = DynamicLibrary.process()
      .lookupFunction<Int32 Function(Pointer<Utf8>, Int32), int Function(Pointer<Utf8>, int)>(
        'access',
      );

  // ----- Helpers -----

  void _check(int r) {
    if (r != _ok) throw _error(r);
  }

  SecurityKeyException _error(int code) {
    final failure = LinuxLibFido2Backend.failureFor(code, builtInUv: builtInUv, pinSet: pinSet);
    return SecurityKeyException(
      failure,
      message: _describe(code),
      retries: switch (failure) {
        SecurityKeyFailure.pinInvalid => _retries(fido.getRetryCount),
        SecurityKeyFailure.uvInvalid => _retries(fido.getUvRetryCount),
        _ => null,
      },
    );
  }

  String _describe(int code) => '${fido.strerr(code).toDartString()} ($code)';

  int? _retries(int Function(Pointer<_Dev>, Pointer<Int32>)? count) {
    if (count == null || dev == nullptr) return null;
    final out = calloc<Int32>();
    try {
      return count(dev, out) == _ok ? out.value : null;
    } finally {
      calloc.free(out);
    }
  }

  void _checkCancelled() {
    if (cancelled) throw _cancelled;
  }

  void _pause(int ms) {
    for (var left = ms; left > 0; left -= 50) {
      _checkCancelled();
      sleep(Duration(milliseconds: min(50, left)));
    }
    _checkCancelled();
  }

  void _report(SecurityKeyStatus status) {
    if (status == _sent) return;
    _sent = status;
    env.status.send(status.name);
  }

  void _reportUserNeeded() =>
      _report(builtInUv ? SecurityKeyStatus.fingerprintNeeded : SecurityKeyStatus.touchNeeded);

  /// Runs [body] with [pin] as libfido2 takes it, NUL-terminated UTF-8 in
  /// native memory, and wipes it after. A null [pin] (built-in UV) is NULL.
  T _withPin<T>(String? pin, T Function(Pointer<Utf8> pin) body) {
    if (pin == null) return body(nullptr);
    final bytes = utf8.encode(pin);
    final native = calloc<Uint8>(bytes.length + 1);
    final view = native.asTypedList(bytes.length + 1)..setAll(0, bytes);
    bytes.fillRange(0, bytes.length, 0);
    try {
      return body(native.cast());
    } finally {
      view.fillRange(0, view.length, 0);
      calloc.free(native);
    }
  }

  /// Drops ids this key could never have issued: empty, or longer than it
  /// allows.
  static List<Uint8List> _usable(List<Uint8List> ids, _Info info) => [
    for (final id in ids)
      if (id.isNotEmpty && (info.maxIdLength == 0 || id.length <= info.maxIdLength)) id,
  ];

  static List<String> _strings(Pointer<Pointer<Utf8>> strings, int count) => [
    for (var i = 0; i < count; i++) strings[i].toDartString(),
  ];

  static Pointer<Uint8> _native(Arena arena, Uint8List bytes) {
    final native = arena<Uint8>(max(bytes.length, 1));
    native.asTypedList(bytes.length).setAll(0, bytes);
    return native;
  }

  static Uint8List _copy(Pointer<Uint8> data, int length) =>
      data == nullptr || length == 0 ? Uint8List(0) : Uint8List.fromList(data.asTypedList(length));

  static Uint8List _random(int length) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
  }

  static int _utf8Length(String s) =>
      s.runes.fold(0, (n, r) => n + (r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4))));
}

final class _Dev extends Opaque {}

final class _DevInfo extends Opaque {}

final class _CborInfo extends Opaque {}

final class _Cred extends Opaque {}

final class _Assert extends Opaque {}

/// Calls one of libfido2's `fido_*_free(T **)`, which take the handle by
/// reference.
void _release<T extends NativeType>(Pointer<T> handle, void Function(Pointer<Pointer<T>>) free) {
  final slot = calloc<IntPtr>()..value = handle.address;
  free(slot.cast());
  calloc.free(slot);
}

typedef _DevN = Int32 Function(Pointer<_Dev>);
typedef _DevD = int Function(Pointer<_Dev>);
typedef _CountN = Int32 Function(Pointer<_Dev>, Pointer<Int32>);
typedef _CountD = int Function(Pointer<_Dev>, Pointer<Int32>);
typedef _InfoStrings = Pointer<Pointer<Utf8>> Function(Pointer<_CborInfo>);
typedef _InfoSizeN = Size Function(Pointer<_CborInfo>);
typedef _InfoSizeD = int Function(Pointer<_CborInfo>);
typedef _InfoU64N = Uint64 Function(Pointer<_CborInfo>);
typedef _CredIntN = Int32 Function(Pointer<_Cred>, Int32);
typedef _CredIntD = int Function(Pointer<_Cred>, int);
typedef _CredBytesN = Int32 Function(Pointer<_Cred>, Pointer<Uint8>, Size);
typedef _CredBytesD = int Function(Pointer<_Cred>, Pointer<Uint8>, int);
typedef _CredPtr = Pointer<Uint8> Function(Pointer<_Cred>);
typedef _CredLenN = Size Function(Pointer<_Cred>);
typedef _CredLenD = int Function(Pointer<_Cred>);
typedef _AssertIntN = Int32 Function(Pointer<_Assert>, Int32);
typedef _AssertIntD = int Function(Pointer<_Assert>, int);
typedef _AssertBytesN = Int32 Function(Pointer<_Assert>, Pointer<Uint8>, Size);
typedef _AssertBytesD = int Function(Pointer<_Assert>, Pointer<Uint8>, int);
typedef _AssertPtrN = Pointer<Uint8> Function(Pointer<_Assert>, Size);
typedef _AssertPtrD = Pointer<Uint8> Function(Pointer<_Assert>, int);
typedef _AssertLenN = Size Function(Pointer<_Assert>, Size);
typedef _AssertLenD = int Function(Pointer<_Assert>, int);

/// The libfido2 calls this backend makes, bound by hand like FhseNative's.
final class _Fido {
  _Fido._(DynamicLibrary lib)
    : init = lib.lookupFunction<Void Function(Int32), void Function(int)>('fido_init'),
      strerr = lib.lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>(
        'fido_strerr',
      ),
      devInfoNew = lib
          .lookupFunction<Pointer<_DevInfo> Function(Size), Pointer<_DevInfo> Function(int)>(
            'fido_dev_info_new',
          ),
      devInfoManifest = lib
          .lookupFunction<
            Int32 Function(Pointer<_DevInfo>, Size, Pointer<Size>),
            int Function(Pointer<_DevInfo>, int, Pointer<Size>)
          >('fido_dev_info_manifest'),
      devInfoPtr = lib
          .lookupFunction<
            Pointer<_DevInfo> Function(Pointer<_DevInfo>, Size),
            Pointer<_DevInfo> Function(Pointer<_DevInfo>, int)
          >('fido_dev_info_ptr'),
      devInfoPath = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<_DevInfo>),
            Pointer<Utf8> Function(Pointer<_DevInfo>)
          >('fido_dev_info_path'),
      devInfoFree = lib
          .lookupFunction<
            Void Function(Pointer<Pointer<_DevInfo>>, Size),
            void Function(Pointer<Pointer<_DevInfo>>, int)
          >('fido_dev_info_free'),
      devNew = lib.lookupFunction<Pointer<_Dev> Function(), Pointer<_Dev> Function()>(
        'fido_dev_new',
      ),
      devOpen = lib
          .lookupFunction<
            Int32 Function(Pointer<_Dev>, Pointer<Utf8>),
            int Function(Pointer<_Dev>, Pointer<Utf8>)
          >('fido_dev_open'),
      devClose = lib.lookupFunction<_DevN, _DevD>('fido_dev_close'),
      devCancel = lib.lookupFunction<_DevN, _DevD>('fido_dev_cancel'),
      devFree = lib
          .lookupFunction<
            Void Function(Pointer<Pointer<_Dev>>),
            void Function(Pointer<Pointer<_Dev>>)
          >('fido_dev_free'),
      devIsFido2 = lib.lookupFunction<Bool Function(Pointer<_Dev>), bool Function(Pointer<_Dev>)>(
        'fido_dev_is_fido2',
      ),
      getRetryCount = lib.lookupFunction<_CountN, _CountD>('fido_dev_get_retry_count'),
      devSetPin = lib
          .lookupFunction<
            Int32 Function(Pointer<_Dev>, Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<_Dev>, Pointer<Utf8>, Pointer<Utf8>)
          >('fido_dev_set_pin'),
      devGetCborInfo = lib
          .lookupFunction<
            Int32 Function(Pointer<_Dev>, Pointer<_CborInfo>),
            int Function(Pointer<_Dev>, Pointer<_CborInfo>)
          >('fido_dev_get_cbor_info'),
      devMakeCred = lib
          .lookupFunction<
            Int32 Function(Pointer<_Dev>, Pointer<_Cred>, Pointer<Utf8>),
            int Function(Pointer<_Dev>, Pointer<_Cred>, Pointer<Utf8>)
          >('fido_dev_make_cred'),
      devGetAssert = lib
          .lookupFunction<
            Int32 Function(Pointer<_Dev>, Pointer<_Assert>, Pointer<Utf8>),
            int Function(Pointer<_Dev>, Pointer<_Assert>, Pointer<Utf8>)
          >('fido_dev_get_assert'),
      touchBegin = lib.providesSymbol('fido_dev_get_touch_begin')
          ? lib.lookupFunction<_DevN, _DevD>('fido_dev_get_touch_begin')
          : null,
      touchStatus = lib.providesSymbol('fido_dev_get_touch_status')
          ? lib.lookupFunction<
              Int32 Function(Pointer<_Dev>, Pointer<Int32>, Int32),
              int Function(Pointer<_Dev>, Pointer<Int32>, int)
            >('fido_dev_get_touch_status')
          : null,
      getUvRetryCount = lib.providesSymbol('fido_dev_get_uv_retry_count')
          ? lib.lookupFunction<_CountN, _CountD>('fido_dev_get_uv_retry_count')
          : null,
      cborInfoNew = lib
          .lookupFunction<Pointer<_CborInfo> Function(), Pointer<_CborInfo> Function()>(
            'fido_cbor_info_new',
          ),
      cborInfoFree = lib
          .lookupFunction<
            Void Function(Pointer<Pointer<_CborInfo>>),
            void Function(Pointer<Pointer<_CborInfo>>)
          >('fido_cbor_info_free'),
      cborInfoExtensionsPtr = lib.lookupFunction<_InfoStrings, _InfoStrings>(
        'fido_cbor_info_extensions_ptr',
      ),
      cborInfoExtensionsLen = lib.lookupFunction<_InfoSizeN, _InfoSizeD>(
        'fido_cbor_info_extensions_len',
      ),
      cborInfoOptionsNamePtr = lib.lookupFunction<_InfoStrings, _InfoStrings>(
        'fido_cbor_info_options_name_ptr',
      ),
      cborInfoOptionsValuePtr = lib
          .lookupFunction<
            Pointer<Uint8> Function(Pointer<_CborInfo>),
            Pointer<Uint8> Function(Pointer<_CborInfo>)
          >('fido_cbor_info_options_value_ptr'),
      cborInfoOptionsLen = lib.lookupFunction<_InfoSizeN, _InfoSizeD>('fido_cbor_info_options_len'),
      cborInfoMaxCredCount = lib.lookupFunction<_InfoU64N, _InfoSizeD>(
        'fido_cbor_info_maxcredcntlst',
      ),
      cborInfoMaxCredIdLength = lib.lookupFunction<_InfoU64N, _InfoSizeD>(
        'fido_cbor_info_maxcredidlen',
      ),
      cborInfoMinPinLength = lib.providesSymbol('fido_cbor_info_minpinlen')
          ? lib.lookupFunction<_InfoU64N, _InfoSizeD>('fido_cbor_info_minpinlen')
          : null,
      cborInfoNewPinRequired = lib.providesSymbol('fido_cbor_info_new_pin_required')
          ? lib.lookupFunction<
              Bool Function(Pointer<_CborInfo>),
              bool Function(Pointer<_CborInfo>)
            >('fido_cbor_info_new_pin_required')
          : null,
      credNew = lib.lookupFunction<Pointer<_Cred> Function(), Pointer<_Cred> Function()>(
        'fido_cred_new',
      ),
      credFree = lib
          .lookupFunction<
            Void Function(Pointer<Pointer<_Cred>>),
            void Function(Pointer<Pointer<_Cred>>)
          >('fido_cred_free'),
      credSetType = lib.lookupFunction<_CredIntN, _CredIntD>('fido_cred_set_type'),
      credSetClientdataHash = lib.lookupFunction<_CredBytesN, _CredBytesD>(
        'fido_cred_set_clientdata_hash',
      ),
      credSetRp = lib
          .lookupFunction<
            Int32 Function(Pointer<_Cred>, Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<_Cred>, Pointer<Utf8>, Pointer<Utf8>)
          >('fido_cred_set_rp'),
      credSetUser = lib
          .lookupFunction<
            Int32 Function(
              Pointer<_Cred>,
              Pointer<Uint8>,
              Size,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
            ),
            int Function(
              Pointer<_Cred>,
              Pointer<Uint8>,
              int,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
            )
          >('fido_cred_set_user'),
      credSetRk = lib.lookupFunction<_CredIntN, _CredIntD>('fido_cred_set_rk'),
      credSetUv = lib.lookupFunction<_CredIntN, _CredIntD>('fido_cred_set_uv'),
      credSetExtensions = lib.lookupFunction<_CredIntN, _CredIntD>('fido_cred_set_extensions'),
      credSetProt = lib.lookupFunction<_CredIntN, _CredIntD>('fido_cred_set_prot'),
      credExclude = lib.lookupFunction<_CredBytesN, _CredBytesD>('fido_cred_exclude'),
      credIdPtr = lib.lookupFunction<_CredPtr, _CredPtr>('fido_cred_id_ptr'),
      credIdLen = lib.lookupFunction<_CredLenN, _CredLenD>('fido_cred_id_len'),
      credAuthdataRawPtr = lib.lookupFunction<_CredPtr, _CredPtr>('fido_cred_authdata_raw_ptr'),
      credAuthdataRawLen = lib.lookupFunction<_CredLenN, _CredLenD>('fido_cred_authdata_raw_len'),
      assertNew = lib.lookupFunction<Pointer<_Assert> Function(), Pointer<_Assert> Function()>(
        'fido_assert_new',
      ),
      assertFree = lib
          .lookupFunction<
            Void Function(Pointer<Pointer<_Assert>>),
            void Function(Pointer<Pointer<_Assert>>)
          >('fido_assert_free'),
      assertSetRp = lib
          .lookupFunction<
            Int32 Function(Pointer<_Assert>, Pointer<Utf8>),
            int Function(Pointer<_Assert>, Pointer<Utf8>)
          >('fido_assert_set_rp'),
      assertSetClientdataHash = lib.lookupFunction<_AssertBytesN, _AssertBytesD>(
        'fido_assert_set_clientdata_hash',
      ),
      assertAllowCred = lib.lookupFunction<_AssertBytesN, _AssertBytesD>('fido_assert_allow_cred'),
      assertSetExtensions = lib.lookupFunction<_AssertIntN, _AssertIntD>(
        'fido_assert_set_extensions',
      ),
      assertSetHmacSalt = lib.lookupFunction<_AssertBytesN, _AssertBytesD>(
        'fido_assert_set_hmac_salt',
      ),
      assertSetUv = lib.lookupFunction<_AssertIntN, _AssertIntD>('fido_assert_set_uv'),
      assertCount = lib
          .lookupFunction<Size Function(Pointer<_Assert>), int Function(Pointer<_Assert>)>(
            'fido_assert_count',
          ),
      assertHmacSecretPtr = lib.lookupFunction<_AssertPtrN, _AssertPtrD>(
        'fido_assert_hmac_secret_ptr',
      ),
      assertHmacSecretLen = lib.lookupFunction<_AssertLenN, _AssertLenD>(
        'fido_assert_hmac_secret_len',
      ),
      assertIdPtr = lib.lookupFunction<_AssertPtrN, _AssertPtrD>('fido_assert_id_ptr'),
      assertAuthdataPtr = lib.lookupFunction<_AssertPtrN, _AssertPtrD>('fido_assert_authdata_ptr'),
      assertAuthdataLen = lib.lookupFunction<_AssertLenN, _AssertLenD>('fido_assert_authdata_len'),
      assertIdLen = lib.lookupFunction<_AssertLenN, _AssertLenD>('fido_assert_id_len');

  /// Opens [name] and binds it. Throws [SecurityKeyFailure.unsupported] when
  /// it does not load or lacks a required call.
  factory _Fido.open(String name) {
    final DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open(name);
    } on ArgumentError catch (e) {
      throw SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: 'libfido2 could not be loaded ($name): ${e.message}',
      );
    }
    final missing = LinuxLibFido2Backend.requiredSymbols.where((s) => !lib.providesSymbol(s));
    if (missing.isNotEmpty) {
      throw SecurityKeyException(
        SecurityKeyFailure.unsupported,
        message: 'libfido2 is too old (1.6 or newer is needed): no ${missing.join(', ')}',
      );
    }
    return _Fido._(lib);
  }

  final void Function(int) init;
  final Pointer<Utf8> Function(int) strerr;
  final Pointer<_DevInfo> Function(int) devInfoNew;
  final int Function(Pointer<_DevInfo>, int, Pointer<Size>) devInfoManifest;
  final Pointer<_DevInfo> Function(Pointer<_DevInfo>, int) devInfoPtr;
  final Pointer<Utf8> Function(Pointer<_DevInfo>) devInfoPath;
  final void Function(Pointer<Pointer<_DevInfo>>, int) devInfoFree;
  final Pointer<_Dev> Function() devNew;
  final int Function(Pointer<_Dev>, Pointer<Utf8>) devOpen;
  final _DevD devClose;
  final _DevD devCancel;
  final void Function(Pointer<Pointer<_Dev>>) devFree;
  final bool Function(Pointer<_Dev>) devIsFido2;
  final _CountD getRetryCount;
  final int Function(Pointer<_Dev>, Pointer<Utf8>, Pointer<Utf8>) devSetPin;
  final int Function(Pointer<_Dev>, Pointer<_CborInfo>) devGetCborInfo;
  final int Function(Pointer<_Dev>, Pointer<_Cred>, Pointer<Utf8>) devMakeCred;
  final int Function(Pointer<_Dev>, Pointer<_Assert>, Pointer<Utf8>) devGetAssert;
  final _DevD? touchBegin;
  final int Function(Pointer<_Dev>, Pointer<Int32>, int)? touchStatus;
  final _CountD? getUvRetryCount;
  final Pointer<_CborInfo> Function() cborInfoNew;
  final void Function(Pointer<Pointer<_CborInfo>>) cborInfoFree;
  final _InfoStrings cborInfoExtensionsPtr;
  final _InfoSizeD cborInfoExtensionsLen;
  final _InfoStrings cborInfoOptionsNamePtr;
  final Pointer<Uint8> Function(Pointer<_CborInfo>) cborInfoOptionsValuePtr;
  final _InfoSizeD cborInfoOptionsLen;
  final _InfoSizeD cborInfoMaxCredCount;
  final _InfoSizeD cborInfoMaxCredIdLength;
  final _InfoSizeD? cborInfoMinPinLength;
  final bool Function(Pointer<_CborInfo>)? cborInfoNewPinRequired;
  final Pointer<_Cred> Function() credNew;
  final void Function(Pointer<Pointer<_Cred>>) credFree;
  final _CredIntD credSetType;
  final _CredBytesD credSetClientdataHash;
  final int Function(Pointer<_Cred>, Pointer<Utf8>, Pointer<Utf8>) credSetRp;
  final int Function(
    Pointer<_Cred>,
    Pointer<Uint8>,
    int,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
  credSetUser;
  final _CredIntD credSetRk;
  final _CredIntD credSetUv;
  final _CredIntD credSetExtensions;
  final _CredIntD credSetProt;
  final _CredBytesD credExclude;
  final _CredPtr credIdPtr;
  final _CredLenD credIdLen;
  final _CredPtr credAuthdataRawPtr;
  final _CredLenD credAuthdataRawLen;
  final Pointer<_Assert> Function() assertNew;
  final void Function(Pointer<Pointer<_Assert>>) assertFree;
  final int Function(Pointer<_Assert>, Pointer<Utf8>) assertSetRp;
  final _AssertBytesD assertSetClientdataHash;
  final _AssertBytesD assertAllowCred;
  final _AssertIntD assertSetExtensions;
  final _AssertBytesD assertSetHmacSalt;
  final _AssertIntD assertSetUv;
  final int Function(Pointer<_Assert>) assertCount;
  final _AssertPtrD assertHmacSecretPtr;
  final _AssertLenD assertHmacSecretLen;
  final _AssertPtrD assertIdPtr;
  final _AssertPtrD assertAuthdataPtr;
  final _AssertLenD assertAuthdataLen;
  final _AssertLenD assertIdLen;

  /// Touch selection needs both halves.
  bool get canTouch => touchBegin != null && touchStatus != null;

  void close(Pointer<_Dev> dev) {
    devClose(dev);
    _release(dev, devFree);
  }
}
