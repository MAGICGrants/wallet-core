import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pc_binding.dart' show MachineKeyException, MachineKeys;

/// This PC's TPM, through CNG's Microsoft Platform Crypto Provider: one
/// RSA-2048 signing key per binding, made inside the TPM and never leaving it,
/// used with no prompt (`NCRYPT_SILENT_FLAG`). RSA PKCS#1 v1.5 signatures are
/// deterministic, so a challenge gets the same signature from the same key
/// every time.
///
/// The key is the Windows user's, not this app's: another program running as
/// the same user can open it by name and sign with it (see `PcBinding`).
///
/// Making a key can take seconds on some TPMs, and every call blocks, so each
/// runs in a background isolate.
class WindowsTpm extends MachineKeys {
  const WindowsTpm();

  @override
  Future<Uint8List?> sign(String name, Uint8List challenge, {bool create = false}) {
    if (challenge.length != _digestLength) {
      throw ArgumentError.value(challenge.length, 'challenge', 'must be 32 bytes');
    }
    return Isolate.run(() => _sign(name, challenge, create), debugName: 'tpm');
  }

  /// Signs [challenge] as a SHA-256 digest: it is 32 random bytes, and the TPM
  /// signs whatever digest it is given.
  static Uint8List? _sign(String name, Uint8List challenge, bool create) {
    final cng = _NCrypt.open();
    return using((arena) {
      final provider = arena<IntPtr>();
      if (cng.openStorageProvider(provider, _str(_platformProvider, arena), 0) != 0) {
        return null; // No TPM, or none Windows can use.
      }
      final key = arena<IntPtr>();
      try {
        final keyName = _str(name, arena);
        if (create) {
          _check(
            cng.createPersistedKey(provider.value, key, _str(_rsa, arena), keyName, 0, 0),
            'NCryptCreatePersistedKey',
          );
          _setDword(cng, key.value, _lengthProperty, 2048, arena);
          _setDword(cng, key.value, _keyUsageProperty, _allowSigning, arena);
          _check(cng.finalizeKey(key.value, _silent), 'NCryptFinalizeKey');
        } else {
          final status = cng.openKey(provider.value, key, keyName, 0, _silent).toUnsigned(32);
          if (status == _nteBadKeyset || status == _nteNotFound) return null;
          _check(status, 'NCryptOpenKey');
        }
        final padding = arena<_Pkcs1PaddingInfo>()..ref.algorithm = _str(_sha256, arena);
        final digest = arena<Uint8>(_digestLength)..asTypedList(_digestLength).setAll(0, challenge);
        final size = arena<Uint32>();
        const flags = _padPkcs1 | _silent;
        _check(
          cng.signHash(key.value, padding.cast(), digest, _digestLength, nullptr, 0, size, flags),
          'NCryptSignHash',
        );
        final signature = arena<Uint8>(size.value);
        _check(
          cng.signHash(
            key.value,
            padding.cast(),
            digest,
            _digestLength,
            signature,
            size.value,
            size,
            flags,
          ),
          'NCryptSignHash',
        );
        return Uint8List.fromList(signature.asTypedList(size.value));
      } finally {
        if (key.value != 0) cng.freeObject(key.value);
        cng.freeObject(provider.value);
      }
    });
  }

  static void _setDword(_NCrypt cng, int key, String property, int value, Arena arena) {
    final input = arena<Uint32>()..value = value;
    _check(
      cng.setProperty(key, _str(property, arena), input.cast(), sizeOf<Uint32>(), _silent),
      'NCryptSetProperty($property)',
    );
  }

  static Pointer<Utf16> _str(String value, Arena arena) => value.toNativeUtf16(allocator: arena);

  static void _check(int status, String call) {
    if (status != 0) {
      final code = status.toUnsigned(32).toRadixString(16).toUpperCase().padLeft(8, '0');
      throw MachineKeyException('$call failed (0x$code)');
    }
  }

  // ncrypt.h, bcrypt.h
  static const _platformProvider = 'Microsoft Platform Crypto Provider';
  static const _rsa = 'RSA';
  static const _sha256 = 'SHA256';
  static const _lengthProperty = 'Length';
  static const _keyUsageProperty = 'Key Usage';
  static const _allowSigning = 0x00000002; // NCRYPT_ALLOW_SIGNING_FLAG
  static const _padPkcs1 = 0x00000002; // BCRYPT_PAD_PKCS1
  static const _silent = 0x00000040; // NCRYPT_SILENT_FLAG
  static const _nteBadKeyset = 0x80090016;
  static const _nteNotFound = 0x80090011;
  static const _digestLength = 32;
}

/// BCRYPT_PKCS1_PADDING_INFO.
final class _Pkcs1PaddingInfo extends Struct {
  external Pointer<Utf16> algorithm;
}

// SECURITY_STATUS is a LONG; NCRYPT_*_HANDLE is a ULONG_PTR.
typedef _OpenProviderN = Int32 Function(Pointer<IntPtr>, Pointer<Utf16>, Uint32);
typedef _OpenProviderD = int Function(Pointer<IntPtr>, Pointer<Utf16>, int);
typedef _OpenKeyN = Int32 Function(IntPtr, Pointer<IntPtr>, Pointer<Utf16>, Uint32, Uint32);
typedef _OpenKeyD = int Function(int, Pointer<IntPtr>, Pointer<Utf16>, int, int);
typedef _CreateKeyN =
    Int32 Function(IntPtr, Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, Uint32, Uint32);
typedef _CreateKeyD = int Function(int, Pointer<IntPtr>, Pointer<Utf16>, Pointer<Utf16>, int, int);
typedef _SetPropertyN = Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint8>, Uint32, Uint32);
typedef _SetPropertyD = int Function(int, Pointer<Utf16>, Pointer<Uint8>, int, int);
typedef _FinalizeN = Int32 Function(IntPtr, Uint32);
typedef _FinalizeD = int Function(int, int);
typedef _SignHashN =
    Int32 Function(
      IntPtr,
      Pointer<Void>,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Uint32,
    );
typedef _SignHashD =
    int Function(
      int,
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint32>,
      int,
    );
typedef _FreeN = Int32 Function(IntPtr);
typedef _FreeD = int Function(int);

/// The ncrypt.dll functions, from System32 by full path so a planted copy
/// elsewhere on the search path is never loaded.
final class _NCrypt {
  _NCrypt._(DynamicLibrary lib)
    : openStorageProvider = lib.lookupFunction<_OpenProviderN, _OpenProviderD>(
        'NCryptOpenStorageProvider',
      ),
      openKey = lib.lookupFunction<_OpenKeyN, _OpenKeyD>('NCryptOpenKey'),
      createPersistedKey = lib.lookupFunction<_CreateKeyN, _CreateKeyD>('NCryptCreatePersistedKey'),
      setProperty = lib.lookupFunction<_SetPropertyN, _SetPropertyD>('NCryptSetProperty'),
      finalizeKey = lib.lookupFunction<_FinalizeN, _FinalizeD>('NCryptFinalizeKey'),
      signHash = lib.lookupFunction<_SignHashN, _SignHashD>('NCryptSignHash'),
      freeObject = lib.lookupFunction<_FreeN, _FreeD>('NCryptFreeObject');

  factory _NCrypt.open() => _NCrypt._(DynamicLibrary.open('${_systemDirectory()}\\ncrypt.dll'));

  final _OpenProviderD openStorageProvider;
  final _OpenKeyD openKey;
  final _CreateKeyD createPersistedKey;
  final _SetPropertyD setProperty;
  final _FinalizeD finalizeKey;
  final _SignHashD signHash;
  final _FreeD freeObject;
}

/// System32's path. kernel32 is opened by bare name: it is a KnownDLL, mapped
/// from System32 into every process, so no search path is consulted.
String _systemDirectory() {
  final getSystemDirectory = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Uint32 Function(Pointer<Utf16>, Uint32), int Function(Pointer<Utf16>, int)>(
        'GetSystemDirectoryW',
      );
  const capacity = 260; // MAX_PATH
  final buffer = calloc<Uint16>(capacity).cast<Utf16>();
  try {
    final length = getSystemDirectory(buffer, capacity);
    if (length == 0 || length >= capacity) {
      throw const MachineKeyException('GetSystemDirectoryW failed');
    }
    return buffer.toDartString(length: length);
  } finally {
    calloc.free(buffer);
  }
}
