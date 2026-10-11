import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../logging.dart';

/// Keeps [path], a directory, and everything in it now and later, out of the
/// phone's iCloud and computer backups. Returns whether the flag reads back as
/// set. iOS only: Android's backup rules already leave out everything but the
/// metadata backup, and the desktop builds have no such backups.
///
/// Why it matters: the wallet files, the seed store and the security-key file
/// must not reach a backup. Their keystore items are this-device-only, but an
/// encrypted backup restored to the *same* phone brings those back too, and the
/// pair then reopens the wallet with whatever protection it had when the backup
/// was made (before security keys, or with a key since removed).
///
/// Through CoreFoundation's C API with `dart:ffi` rather than a platform
/// channel, so a background isolate, which may be the first to run after an
/// update, can set it too. Set on the directory, not on each file: wallet2 and
/// the vault replace files by rename, which drops a per-file flag, while a
/// directory's flag covers whatever is inside it.
bool excludeFromDeviceBackup(String path) {
  if (!Platform.isIOS) return false;
  try {
    return (_coreFoundation ??= _CoreFoundation()).exclude(path);
  } catch (e) {
    log(LogLevel.error, '[Backup] Could not exclude $path from device backups: $e');
    return false;
  }
}

_CoreFoundation? _coreFoundation;

// CFURLRef CFURLCreateFromFileSystemRepresentation(CFAllocatorRef, const UInt8*, CFIndex, Boolean)
typedef _CreateUrlN = Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, IntPtr, Uint8);
typedef _CreateUrlD = Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int, int);
// Boolean CFURLSetResourcePropertyForKey(CFURLRef, CFStringRef, CFTypeRef, CFErrorRef*)
typedef _SetPropN = Uint8 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _SetPropD = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
// Boolean CFURLCopyResourcePropertyForKey(CFURLRef, CFStringRef, void* (CFTypeRef*), CFErrorRef*)
typedef _CopyPropN =
    Uint8 Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>);
typedef _CopyPropD =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>);
// void CFRelease(CFTypeRef)
typedef _ReleaseN = Void Function(Pointer<Void>);
typedef _ReleaseD = void Function(Pointer<Void>);

/// The handful of CoreFoundation calls [excludeFromDeviceBackup] needs, looked
/// up in the process: CoreFoundation is always loaded in an iOS app.
class _CoreFoundation {
  _CoreFoundation() : this._(DynamicLibrary.process());

  _CoreFoundation._(DynamicLibrary lib)
    : _createUrl = lib.lookupFunction<_CreateUrlN, _CreateUrlD>(
        'CFURLCreateFromFileSystemRepresentation',
      ),
      _setProperty = lib.lookupFunction<_SetPropN, _SetPropD>('CFURLSetResourcePropertyForKey'),
      _copyProperty = lib.lookupFunction<_CopyPropN, _CopyPropD>(
        'CFURLCopyResourcePropertyForKey',
      ),
      _release = lib.lookupFunction<_ReleaseN, _ReleaseD>('CFRelease'),
      // Both are `const` globals holding a CF object pointer.
      _excludedKey = lib.lookup<Pointer<Void>>('kCFURLIsExcludedFromBackupKey').value,
      _true = lib.lookup<Pointer<Void>>('kCFBooleanTrue').value;

  final _CreateUrlD _createUrl;
  final _SetPropD _setProperty;
  final _CopyPropD _copyProperty;
  final _ReleaseD _release;
  final Pointer<Void> _excludedKey;
  final Pointer<Void> _true;

  bool exclude(String path) {
    final set = _withDirectoryUrl(path, (url) => _setProperty(url, _excludedKey, _true, nullptr));
    if (set == 0) return false;
    // Read back through a new URL: a CFURL caches the values set on it.
    return _withDirectoryUrl(path, (url) {
      final value = calloc<Pointer<Void>>();
      try {
        if (_copyProperty(url, _excludedKey, value, nullptr) == 0) return 0;
        final read = value.value;
        if (read == nullptr) return 0;
        _release(read);
        // CFBoolean values are singletons, so identity is equality.
        return read == _true ? 1 : 0;
      } finally {
        calloc.free(value);
      }
    }) ==
        1;
  }

  int _withDirectoryUrl(String path, int Function(Pointer<Void> url) body) {
    final bytes = path.toNativeUtf8();
    try {
      final url = _createUrl(nullptr, bytes.cast<Uint8>(), bytes.length, 1);
      if (url == nullptr) return 0;
      try {
        return body(url);
      } finally {
        _release(url);
      }
    } finally {
      malloc.free(bytes);
    }
  }
}
