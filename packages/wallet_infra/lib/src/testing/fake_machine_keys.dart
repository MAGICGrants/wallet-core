import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' show HMac, KeyParameter, SHA256Digest;

import '../storage/pc_binding.dart';

/// A TPM for tests: keys held in memory, each signing a challenge the same way
/// every time. **Tests only.**
///
/// [present] false is a PC with no TPM; [forgetAll] is another PC, or a
/// cleared TPM; [replace] puts a different key under the same name; [failing]
/// is a TPM that does not answer.
class FakeMachineKeys extends MachineKeys {
  final _keys = <String, Uint8List>{};
  final _random = Random.secure();

  bool present = true;
  bool failing = false;

  /// Signatures made, to tell a cached secret from a new one.
  int signs = 0;

  Iterable<String> get names => _keys.keys;

  void forgetAll() => _keys.clear();

  void replace(String name) => _keys[name] = _newKey();

  @override
  Future<Uint8List?> sign(String name, Uint8List challenge, {bool create = false}) async {
    if (failing) throw const MachineKeyException('the fake TPM does not answer');
    if (!present) return null;
    if (create) {
      if (_keys.containsKey(name)) throw MachineKeyException('$name exists');
      _keys[name] = _newKey();
    }
    final key = _keys[name];
    if (key == null) return null;
    signs++;
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
    mac.update(challenge, 0, challenge.length);
    final out = Uint8List(mac.macSize);
    mac.doFinal(out, 0);
    return out;
  }

  Uint8List _newKey() => Uint8List.fromList([for (var i = 0; i < 32; i++) _random.nextInt(256)]);
}
