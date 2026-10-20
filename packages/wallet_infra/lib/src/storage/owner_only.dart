import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../logging.dart';

/// Owner read/write (and, for folders, search): `0600` and `0700`.
const ownerOnlyFileMode = 0x180; // 0600
const ownerOnlyDirMode = 0x1C0; // 0700

/// Linux: keeps [dir], the wallet's folder, to the user who owns it, as a
/// phone's sandbox and a Mac app's container (`drwx------`) already do. The
/// files in it are sensitive: the wallet files, the seed store, the
/// security-key file and `wallet.key`. Another user on the computer must not
/// be able to copy them.
///
/// - Sets the process's umask to `077`, so every file and folder made from now
///   on is the owner's only, whoever makes it: Dart, wallet2, Tor. Files
///   outside [dir] that the app writes for the user (an export, say) are
///   private to them too.
/// - Tightens what is already there, from builds that made it `0755`/`0644`:
///   [dir] and its folders to `0700`, its files to `0600`. Symbolic links are
///   left alone, and so is whatever they point to.
///
/// Returns whether everything was set. A file system without Unix permissions
/// (a FAT or NTFS mount) refuses, which is logged, not thrown.
bool restrictToOwner(Directory dir) {
  try {
    final libc = _libc ??= _Libc();
    libc.umask(0x3F); // 077
    var ok = libc.chmod(dir.path, ownerOnlyDirMode);
    for (final entry in dir.listSync(recursive: true, followLinks: false)) {
      if (entry is Link) continue;
      ok = libc.chmod(entry.path, entry is Directory ? ownerOnlyDirMode : ownerOnlyFileMode) && ok;
    }
    if (!ok) log(LogLevel.warn, '[Paths] Some of ${dir.path} could not be made private');
    return ok;
  } catch (e) {
    log(LogLevel.error, '[Paths] Could not make ${dir.path} private: $e');
    return false;
  }
}

/// Sets the process's umask and returns the previous one. For tests, which
/// must put back what they change.
@visibleForTesting
int setUmask(int mask) => (_libc ??= _Libc()).umask(mask);

_Libc? _libc;

// int chmod(const char *path, mode_t mode); mode_t umask(mode_t mask);
// mode_t is 32 bits on Linux and 16 on macOS; passed in a full register either
// way, and only the low bits are read back.
typedef _ChmodN = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodD = int Function(Pointer<Utf8>, int);
typedef _UmaskN = Uint32 Function(Uint32);
typedef _UmaskD = int Function(int);

/// The two libc calls, looked up in the process: dart:io has neither.
class _Libc {
  _Libc() : this._(DynamicLibrary.process());

  _Libc._(DynamicLibrary lib)
    : _chmod = lib.lookupFunction<_ChmodN, _ChmodD>('chmod'),
      _umask = lib.lookupFunction<_UmaskN, _UmaskD>('umask');

  final _ChmodD _chmod;
  final _UmaskD _umask;

  bool chmod(String path, int mode) {
    final p = path.toNativeUtf8();
    try {
      return _chmod(p, mode) == 0;
    } finally {
      malloc.free(p);
    }
  }

  int umask(int mask) => _umask(mask) & 0x1FF;
}
