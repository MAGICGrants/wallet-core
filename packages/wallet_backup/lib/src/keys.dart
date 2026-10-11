import 'dart:typed_data';

import 'package:wallet_domain/wallet_domain.dart' show carrotHash, carrotHash32;

/// The backup's keys, all from the metadata root `M` (plan §1.2):
///
/// ```
/// K          = H_32[M]("Monero metadata backup v1")
/// k_enc(e)   = H_32[K]("encryption key" ‖ IntToBytes16(e))
/// k_name     = H_32[K]("naming key")
/// t_lws(e)   = H_32[K]("LWS write token" ‖ IntToBytes16(e))
/// ```
///
/// One key per job, so a leak of one does not expose the others. Nothing in a
/// backup file contains `M`, `K`, the seed, or any wallet key, so a leaked file
/// key costs privacy, never funds. The strings are placeholders until a Monero
/// addendum fixes them.
class BackupKeys {
  BackupKeys.fromMetadataRoot(Uint8List metadataRoot)
    : _root = carrotHash32(metadataRoot, 'Monero metadata backup v1') {
    _naming = carrotHash32(_root, 'naming key');
  }

  final Uint8List _root;
  late final Uint8List _naming;
  final Map<int, Uint8List> _encryption = {};
  bool _wiped = false;

  /// `k_enc(epoch)`.
  Uint8List encryptionKey(int epoch) {
    _checkLive();
    return _encryption[epoch] ??= carrotHash32(_root, 'encryption key', _u16le(epoch));
  }

  /// `k_name`.
  Uint8List get namingKey {
    _checkLive();
    return _naming;
  }

  /// `t_lws(epoch)`, for the light-wallet server location once it exists.
  Uint8List lwsWriteToken(int epoch) {
    _checkLive();
    return carrotHash32(_root, 'LWS write token', _u16le(epoch));
  }

  /// `H_16[k_name](domain ‖ data)`, for location names (§3).
  Uint8List nameHash(String domain, [List<int> data = const []]) {
    _checkLive();
    return carrotHash(16, _naming, domain, data);
  }

  void wipe() {
    _root.fillRange(0, _root.length, 0);
    _naming.fillRange(0, _naming.length, 0);
    for (final k in _encryption.values) {
      k.fillRange(0, k.length, 0);
    }
    _encryption.clear();
    _wiped = true;
  }

  void _checkLive() {
    if (_wiped) throw StateError('backup keys were wiped');
  }

  static Uint8List _u16le(int v) {
    if (v < 0 || v > 0xffff) throw ArgumentError('epoch out of range');
    return Uint8List.fromList([v & 0xff, v >> 8]);
  }
}
