import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pointycastle/export.dart' show HMac, KeyParameter, SHA256Digest;

import '../logging.dart';
import '../paths.dart';
import 'atomic_file.dart';
import 'windows_tpm.dart';

/// A key in this PC's TPM that signs a challenge the same way every time, so
/// the signature is a secret only this PC can produce ([WindowsTpm]). There is
/// none elsewhere ([NoMachineKeys]).
abstract class MachineKeys {
  const MachineKeys();

  /// Signs [challenge] (32 bytes) with the key named [name]; with [create],
  /// makes the key first. Null when this PC has no TPM to use, or no key of
  /// that name. Throws [MachineKeyException] when the TPM fails otherwise,
  /// which may pass.
  Future<Uint8List?> sign(String name, Uint8List challenge, {bool create = false});
}

/// No TPM to bind with: Linux, macOS and the phones.
class NoMachineKeys extends MachineKeys {
  const NoMachineKeys();

  @override
  Future<Uint8List?> sign(String name, Uint8List challenge, {bool create = false}) async => null;
}

class MachineKeyException implements Exception {
  const MachineKeyException(this.message);

  final String message;

  @override
  String toString() => 'MachineKeyException: $message';
}

/// The typed password may be right, but the file is bound to a PC ([PcBinding])
/// and this one cannot produce its secret: another computer, a cleared or
/// replaced TPM, or a TPM that does not answer. The wallet is restored from its
/// recovery phrase on another computer.
class BoundToAnotherPcException implements Exception {
  const BoundToAnotherPcException();

  @override
  String toString() => 'BoundToAnotherPcException: this PC cannot open files bound to another';
}

/// Ties the files a typed password protects to this PC, on Windows:
/// `wallet.key` while security keys are off, `wallet.fhse` while they are on.
///
/// A secret only this PC's TPM can produce goes into the password those files
/// are encrypted with, beside the typed password. A copy of either file (a
/// backup, a disk image, a copy taken off the disk) then cannot be opened, nor
/// its password guessed, on another computer. It does not stop a program
/// running on this PC as the same user, which can use the TPM key just as it
/// can ask a security key. A bound file opens only on this PC: on another one,
/// or once its TPM is cleared, the wallet is restored from its recovery phrase.
///
/// `pc_binding.json`, beside the files, lists the bindings on record, newest
/// first. Each names its TPM key and its challenge, and keeps a check of the
/// secret, which tells another TPM from a wrong password. A second one is on
/// record only while a new binding replaces one this PC can no longer
/// produce, so a write cut short leaves the file openable either way.
///
/// A file written by an earlier build, or on a PC without a TPM, is not bound
/// and still opens with the typed password alone.
abstract final class PcBinding {
  static const fileName = 'pc_binding.json';

  /// This platform's keys: Windows' TPM, or none. Replaced in tests.
  @visibleForTesting
  static MachineKeys keys = Platform.isWindows ? const WindowsTpm() : const NoMachineKeys();

  // What this session's bindings produced, by key name: one TPM signature per
  // binding per session. Cleared by [endSession].
  static final _secrets = <String, Uint8List>{};

  static const _secretLabel = 'wallet pc binding secret v1';
  static const _checkLabel = 'wallet pc binding check v1';
  static const _keyPrefix = 'MAGIC Grants wallet binding';

  /// The passwords that may open a file written under [typed], most likely
  /// first: [typed] bound with each binding on record this PC can produce,
  /// then [typed] alone, for a file written unbound.
  static Future<PcPasswords> passwordsFor(String typed) async {
    final passwords = <String>[];
    var unavailable = false;
    for (final binding in await _read()) {
      final secret = await _secretFor(binding);
      if (secret == null) {
        unavailable = true;
      } else {
        passwords.add(_bind(typed, secret));
      }
    }
    final bound = passwords.length;
    passwords.add(typed);
    return PcPasswords._(passwords, bound: bound, unavailable: unavailable);
  }

  /// The password to write a file under [typed] with: bound with the newest
  /// binding this PC produces, or with a new one made now, which
  /// [PcWrite.write] records. [typed] alone where the PC has no TPM, or when
  /// making a key fails (logged: the file is then protected as before).
  static Future<PcWrite> forWrite(String typed) async {
    final record = await _read();
    if (record.isNotEmpty) {
      final secret = await _secretFor(record.first);
      if (secret != null) return PcWrite._(_bind(typed, secret), bound: true);
    }
    final random = Random.secure();
    final name =
        '$_keyPrefix ${[for (var i = 0; i < 8; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join()}';
    final challenge = Uint8List.fromList([for (var i = 0; i < 32; i++) random.nextInt(256)]);
    final Uint8List? signature;
    try {
      signature = await keys.sign(name, challenge, create: true);
    } on MachineKeyException catch (e) {
      log(LogLevel.warn, '[PcBinding] No TPM key could be made, so the file is not bound: $e');
      return PcWrite._(typed, bound: false);
    }
    if (signature == null) return PcWrite._(typed, bound: false);
    final secret = _derive(signature, _secretLabel);
    final made = _Binding(name, challenge, _derive(signature, _checkLabel));
    signature.fillRange(0, signature.length, 0);
    _secrets[name] = secret;
    log(LogLevel.info, '[PcBinding] Made a TPM key to bind the wallet files to this PC');
    return PcWrite._(_bind(typed, secret), bound: true, made: made);
  }

  /// Forgets what this session's bindings produced: part of a full lock.
  static void endSession() {
    for (final secret in _secrets.values) {
      secret.fillRange(0, secret.length, 0);
    }
    _secrets.clear();
  }

  /// Deletes the record, for a deleted wallet. The TPM keys stay: they open
  /// nothing without it.
  static Future<void> deleteRecord() async {
    endSession();
    final file = await _file();
    if (await file.exists()) await file.delete();
  }

  /// The bound password: the secret, then [typed].
  static String _bind(String typed, Uint8List secret) => 'pc1:${base64.encode(secret)}:$typed';

  static Future<Uint8List?> _secretFor(_Binding binding) async {
    if (_secrets[binding.key] case final secret?) return secret;
    final Uint8List? signature;
    try {
      signature = await keys.sign(binding.key, binding.challenge);
    } on MachineKeyException catch (e) {
      log(LogLevel.warn, '[PcBinding] The TPM did not answer: $e');
      return null;
    }
    if (signature == null) return null;
    final check = _derive(signature, _checkLabel);
    final secret = _derive(signature, _secretLabel);
    signature.fillRange(0, signature.length, 0);
    if (!_same(check, binding.check)) {
      log(LogLevel.warn, '[PcBinding] This TPM key is not the one the files were bound with');
      return null;
    }
    _secrets[binding.key] = secret;
    return secret;
  }

  /// HMAC-SHA256 keyed by the signature: one key, two labels.
  static Uint8List _derive(Uint8List signature, String label) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(signature));
    final input = utf8.encode(label);
    mac.update(input, 0, input.length);
    final out = Uint8List(mac.macSize);
    mac.doFinal(out, 0);
    return out;
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static Future<File> _file() async => File('${(await getAppDir()).path}/$fileName');

  /// The bindings on record, newest first; none when there is no record or it
  /// cannot be read.
  static Future<List<_Binding>> _read() async {
    final file = await _file();
    if (!await file.exists()) return const [];
    try {
      final json = jsonDecode(await file.readAsString());
      return [for (final entry in (json as Map)['bindings'] as List) ?_Binding.fromJson(entry)];
    } catch (e) {
      log(LogLevel.error, '[PcBinding] Could not read $fileName: $e');
      return const [];
    }
  }

  static Future<void> _write(List<_Binding> bindings) async => writeStringAtomic(
    await _file(),
    jsonEncode({
      'version': 1,
      'bindings': [for (final b in bindings) b.toJson()],
    }),
  );
}

/// The candidates [PcBinding.passwordsFor] found.
class PcPasswords {
  PcPasswords._(this.passwords, {required this.bound, required this.unavailable});

  /// Most likely first; the last is the typed password alone.
  final List<String> passwords;

  /// How many of [passwords], from the first, are bound.
  final int bound;

  /// A binding on record that this PC could not produce. When no password
  /// opens the file, this, not a wrong password, is the likely reason: throw
  /// [BoundToAnotherPcException].
  final bool unavailable;

  bool isBound(int index) => index < bound;
}

/// A file about to be written ([PcBinding.forWrite]).
class PcWrite {
  PcWrite._(this.password, {required this.bound, _Binding? made}) : _made = made;

  /// What to encrypt the file with.
  final String password;

  /// Whether [password] is bound to this PC.
  final bool bound;

  final _Binding? _made;

  /// Writes the file with [writeFile]. A binding made for it is recorded
  /// first, so a write cut short leaves it on record with the ones before it,
  /// and the ones it replaces are dropped once the file is written.
  Future<void> write(Future<void> Function() writeFile) async {
    final made = _made;
    if (made != null) await PcBinding._write([made, ...await PcBinding._read()]);
    await writeFile();
    if (made != null) await PcBinding._write([made]);
  }
}

class _Binding {
  const _Binding(this.key, this.challenge, this.check);

  /// The TPM key's name.
  final String key;
  final Uint8List challenge;

  /// Tells this binding's secret from another TPM's answer.
  final Uint8List check;

  Map<String, Object?> toJson() => {
    'key': key,
    'challenge': base64.encode(challenge),
    'check': base64.encode(check),
  };

  static _Binding? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    final challenge = json['challenge'];
    final check = json['check'];
    if (key is! String || challenge is! String || check is! String) return null;
    try {
      return _Binding(key, base64.decode(challenge), base64.decode(check));
    } on FormatException {
      return null;
    }
  }
}
