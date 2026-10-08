import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// An FHSE operation failed. [code] is FHSE's `enum fhse_error` value, or one
/// of wfhse.h's own codes above it.
class FhseException implements Exception {
  const FhseException(this.code, this.operation);

  final int code;
  final String operation;

  static const badAlloc = 1;
  static const badArgument = 2;
  static const cborFailure = 3;
  static const cryptoFailure = 4;

  /// Wrong password for the outer layer, or a tampered file.
  static const decryptionFailure = 5;
  static const duplicateKey = 6;
  static const fidoFailure = 7;
  static const fidoNeedsPin = 8;

  /// No enrolled key produced this hmac-secret.
  static const keyUnavailable = 9;
  static const mlockFailure = 10;
  static const bufferTooSmall = 100;
  static const notUnlocked = 101;

  @override
  String toString() => 'FhseException($operation: ${_describe(code)})';

  static String _describe(int code) => switch (code) {
    badAlloc => 'allocation failure',
    badArgument => 'invalid argument',
    cborFailure => 'malformed file',
    cryptoFailure => 'cryptography failure',
    decryptionFailure => 'wrong password or damaged file',
    duplicateKey => 'key already enrolled',
    keyUnavailable => 'key is not enrolled',
    mlockFailure => 'could not lock memory',
    notUnlocked => 'not unlocked',
    _ => 'error $code',
  };
}

/// Where the native library comes from.
///
/// The plugin builds it per platform: a shared object on Android, and on iOS a
/// framework CocoaPods links into the app (Skylight's Podfile uses
/// `use_frameworks!`). Host tests point [FhseNative.libraryPathOverride] at a
/// CMake build of `src/`; see test/README.md.
DynamicLibrary _open() {
  final override = FhseNative.libraryPathOverride;
  if (override != null) return DynamicLibrary.open(override);
  if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open('libwallet_fhse.so');
  if (Platform.isIOS) return DynamicLibrary.open('wallet_fhse.framework/wallet_fhse');
  if (Platform.isMacOS) return DynamicLibrary.open('libwallet_fhse.dylib');
  throw UnsupportedError('wallet_fhse is not built for ${Platform.operatingSystem}');
}

typedef WfhseSecretNewN = Pointer<Void> Function();
typedef WfhseSecretFreeN = Void Function(Pointer<Void>);
typedef WfhseCreateN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Uint8>, Size);
typedef WfhseCreateD = int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef WfhseStoreN = Int32 Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef WfhseStoreD = int Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef WfhseCountN = Size Function(Pointer<Void>);
typedef WfhseCountD = int Function(Pointer<Void>);
typedef WfhseCredN = Int32 Function(Pointer<Void>, Size, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef WfhseCredD = int Function(Pointer<Void>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef WfhseViewN = Int32 Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef WfhseViewD = int Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef WfhseUnlockN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef WfhseUnlockD = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef WfhseAddKeyN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Uint8>, Size);
typedef WfhseAddKeyD = int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef WfhseRootN = Int32 Function(Pointer<Void>, Pointer<Utf8>, Size);
typedef WfhseRootD = int Function(Pointer<Void>, Pointer<Utf8>, int);
typedef WfhseHashN =
    Int32 Function(Pointer<Uint8>, Size, Pointer<Uint8>, Size, Pointer<Uint8>, Size);
typedef WfhseHashD = int Function(Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef WfhseRandomN = Int32 Function(Pointer<Uint8>, Size);
typedef WfhseRandomD = int Function(Pointer<Uint8>, int);
typedef WfhseFreeN = Void Function(Pointer<Uint8>, Size);
typedef WfhseFreeD = void Function(Pointer<Uint8>, int);
typedef WfhseZeroN = Void Function(Pointer<Void>, Size);
typedef WfhseZeroD = void Function(Pointer<Void>, int);

/// The functions of `src/wfhse.h`, bound by hand: there are few, and a
/// generator config nobody runs would read as reviewed bindings when they are
/// not.
class FhseNative {
  FhseNative._(DynamicLibrary lib)
    : secretNew = lib.lookupFunction<WfhseSecretNewN, WfhseSecretNewN>('wfhse_secret_new'),
      secretFreePointer = lib.lookup<NativeFunction<WfhseSecretFreeN>>('wfhse_secret_free'),
      create = lib.lookupFunction<WfhseCreateN, WfhseCreateD>('wfhse_secret_create'),
      open = lib.lookupFunction<WfhseCreateN, WfhseCreateD>('wfhse_secret_open'),
      store = lib.lookupFunction<WfhseStoreN, WfhseStoreD>('wfhse_secret_store'),
      credCount = lib.lookupFunction<WfhseCountN, WfhseCountD>('wfhse_secret_cred_count'),
      cred = lib.lookupFunction<WfhseCredN, WfhseCredD>('wfhse_secret_cred'),
      fidoUserId = lib.lookupFunction<WfhseViewN, WfhseViewD>('wfhse_secret_fido_userid'),
      fidoSalt = lib.lookupFunction<WfhseViewN, WfhseViewD>('wfhse_secret_fido_salt'),
      unlock = lib.lookupFunction<WfhseUnlockN, WfhseUnlockD>('wfhse_secret_unlock'),
      addKey = lib.lookupFunction<WfhseAddKeyN, WfhseAddKeyD>('wfhse_secret_add_key'),
      rootZ85 = lib.lookupFunction<WfhseRootN, WfhseRootD>('wfhse_secret_root_z85'),
      kdf = lib.lookupFunction<WfhseHashN, WfhseHashD>('wfhse_kdf'),
      hashPersonal = lib.lookupFunction<WfhseHashN, WfhseHashD>('wfhse_hash_personal'),
      random = lib.lookupFunction<WfhseRandomN, WfhseRandomD>('wfhse_random'),
      free = lib.lookupFunction<WfhseFreeN, WfhseFreeD>('wfhse_free'),
      memzero = lib.lookupFunction<WfhseZeroN, WfhseZeroD>('wfhse_memzero');

  /// Set by host tests to a CMake build of `src/`. Unused in the apps.
  static String? libraryPathOverride;

  static FhseNative? _instance;
  static FhseNative get instance => _instance ??= FhseNative._(_open());

  final Pointer<Void> Function() secretNew;
  final Pointer<NativeFunction<WfhseSecretFreeN>> secretFreePointer;
  final WfhseCreateD create;
  final WfhseCreateD open;
  final WfhseStoreD store;
  final WfhseCountD credCount;
  final WfhseCredD cred;
  final WfhseViewD fidoUserId;
  final WfhseViewD fidoSalt;
  final WfhseUnlockD unlock;
  final WfhseAddKeyD addKey;
  final WfhseRootD rootZ85;
  final WfhseHashD kdf;
  final WfhseHashD hashPersonal;
  final WfhseRandomD random;
  final WfhseFreeD free;
  final WfhseZeroD memzero;

  /// Copies [bytes] into native memory for the length of [body], then wipes and
  /// frees it. Secrets cross the boundary only this way, so none is left behind
  /// in the native heap.
  R withBytes<R>(Uint8List bytes, R Function(Pointer<Uint8> ptr, int length) body) {
    // calloc(0) may return null; one byte keeps a valid pointer for empty input.
    final ptr = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      ptr.asTypedList(bytes.length).setAll(0, bytes);
      return body(ptr, bytes.length);
    } finally {
      memzero(ptr.cast(), bytes.isEmpty ? 1 : bytes.length);
      calloc.free(ptr);
    }
  }

  /// Runs [body] with a [length]-byte native output buffer and returns a copy
  /// of what it wrote, wiping the buffer afterwards.
  Uint8List withOutput(int length, int Function(Pointer<Uint8> ptr, int length) body, String op) {
    final ptr = calloc<Uint8>(length);
    try {
      check(body(ptr, length), op);
      return Uint8List.fromList(ptr.asTypedList(length));
    } finally {
      memzero(ptr.cast(), length);
      calloc.free(ptr);
    }
  }

  static void check(int rc, String operation) {
    if (rc != 0) throw FhseException(rc, operation);
  }
}
