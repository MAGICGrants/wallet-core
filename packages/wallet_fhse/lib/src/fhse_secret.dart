import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'fhse_native.dart';

/// Size of the hmac-secret a FIDO2 key returns, and of an FHSE seed.
const fhseSecretLength = 32;

/// One FHSE file in memory: the FIDO2 user id and salt, the enrolled
/// credentials, and once created or unlocked, the root secret.
///
/// The root never leaves native memory except as [rootZ85], which is what the
/// wallet uses as its password. [dispose] frees (and wipes) the native object;
/// a finalizer does the same if a caller forgets.
class FhseSecret implements Finalizable {
  FhseSecret._(this._handle) {
    _finalizer.attach(this, _handle, detach: this);
  }

  static final _finalizer = NativeFinalizer(FhseNative.instance.secretFreePointer);

  Pointer<Void> _handle;

  static FhseNative get _n => FhseNative.instance;

  static FhseSecret _allocate() {
    final handle = _n.secretNew();
    if (handle == nullptr) throw const FhseException(FhseException.badAlloc, 'new');
    return FhseSecret._(handle);
  }

  /// A new file whose root is derived from [seed] (32 bytes), or random when
  /// [seed] is null. Its outer layer will be encrypted with [password]. Comes
  /// back unlocked, so keys can be added straight away.
  static FhseSecret create({required Uint8List password, Uint8List? seed}) {
    if (seed != null && seed.length != fhseSecretLength) {
      throw const FhseException(FhseException.badArgument, 'create: seed must be 32 bytes');
    }
    final secret = _allocate();
    try {
      _n.withBytes(password, (pass, passLen) {
        if (seed == null) {
          FhseNative.check(_n.create(secret._handle, pass, passLen, nullptr, 0), 'create');
        } else {
          _n.withBytes(seed, (s, sLen) {
            FhseNative.check(_n.create(secret._handle, pass, passLen, s, sLen), 'create');
          });
        }
      });
      return secret;
    } catch (_) {
      secret.dispose();
      rethrow;
    }
  }

  /// Reads a stored file with [password]. The root stays locked until
  /// [unlock] is given an enrolled key's hmac-secret.
  static FhseSecret open(Uint8List blob, {required Uint8List password}) {
    final secret = _allocate();
    try {
      _n.withBytes(blob, (b, bLen) {
        _n.withBytes(password, (pass, passLen) {
          FhseNative.check(_n.open(secret._handle, b, bLen, pass, passLen), 'open');
        });
      });
      return secret;
    } catch (_) {
      secret.dispose();
      rethrow;
    }
  }

  /// The z85 text of the root a [seed] produces; what [create] would make
  /// [rootZ85]. Used for a wallet's password before any key is enrolled.
  static String rootZ85ForSeed(Uint8List seed) {
    final secret = create(password: Uint8List(0), seed: seed);
    try {
      return secret.rootZ85;
    } finally {
      secret.dispose();
    }
  }

  void _checkLive() {
    if (_handle == nullptr) throw StateError('FhseSecret used after dispose');
  }

  /// The FIDO2 user id credentials are created under.
  Uint8List get fidoUserId => _view(_n.fidoUserId, 'fido_userid');

  /// The salt every key's hmac-secret is taken over.
  Uint8List get fidoSalt => _view(_n.fidoSalt, 'fido_salt');

  Uint8List _view(
    int Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>) fn,
    String op,
  ) {
    _checkLive();
    final out = calloc<Pointer<Uint8>>();
    final len = calloc<Size>();
    try {
      FhseNative.check(fn(_handle, out, len), op);
      return Uint8List.fromList(out.value.asTypedList(len.value));
    } finally {
      calloc.free(out);
      calloc.free(len);
    }
  }

  /// The credential ids of every enrolled key, in file order.
  List<Uint8List> get credentialIds {
    _checkLive();
    final count = _n.credCount(_handle);
    final out = calloc<Pointer<Uint8>>();
    final len = calloc<Size>();
    try {
      return [
        for (var i = 0; i < count; i++)
          () {
            FhseNative.check(_n.cred(_handle, i, out, len), 'cred');
            return Uint8List.fromList(out.value.asTypedList(len.value));
          }(),
      ];
    } finally {
      calloc.free(out);
      calloc.free(len);
    }
  }

  /// Decrypts the root with one enrolled key's hmac-secret. Throws
  /// [FhseException.keyUnavailable] when no entry opens with it.
  void unlock(Uint8List hmacSecret) {
    _checkLive();
    _n.withBytes(hmacSecret, (h, hLen) {
      FhseNative.check(_n.unlock(_handle, h, hLen), 'unlock');
    });
  }

  /// Wraps the root for one more key. Needs the root, so only after [create]
  /// or [unlock].
  void addKey({required Uint8List credentialId, required Uint8List hmacSecret}) {
    _checkLive();
    _n.withBytes(credentialId, (c, cLen) {
      _n.withBytes(hmacSecret, (h, hLen) {
        FhseNative.check(_n.addKey(_handle, c, cLen, h, hLen), 'add_key');
      });
    });
  }

  /// The serialised file. FHSE refuses to store one with no keys.
  Uint8List store() {
    _checkLive();
    final out = calloc<Pointer<Uint8>>();
    final len = calloc<Size>();
    try {
      FhseNative.check(_n.store(_handle, out, len), 'store');
      final bytes = Uint8List.fromList(out.value.asTypedList(len.value));
      _n.free(out.value, len.value);
      return bytes;
    } finally {
      calloc.free(out);
      calloc.free(len);
    }
  }

  /// The root as z85 text: the wallet password. Only after [create] or
  /// [unlock].
  String get rootZ85 {
    _checkLive();
    const size = 41;
    final out = calloc<Uint8>(size);
    try {
      FhseNative.check(_n.rootZ85(_handle, out.cast(), size), 'root');
      return out.cast<Utf8>().toDartString();
    } finally {
      _n.memzero(out.cast(), size);
      calloc.free(out);
    }
  }

  void dispose() {
    if (_handle == nullptr) return;
    _finalizer.detach(this);
    final handle = _handle;
    _handle = nullptr;
    FhseNative.instance.secretFreePointer.asFunction<void Function(Pointer<Void>)>()(handle);
  }
}
