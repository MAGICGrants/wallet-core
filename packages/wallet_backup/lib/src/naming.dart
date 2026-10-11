import 'dart:convert';
import 'dart:typed_data';

import 'backup_file.dart';
import 'crypto.dart';
import 'keys.dart';

/// File names (plan §3).
///
/// Every file has a **plain name** derived from its sealed content. A light-wallet
/// server would get plain names; every other location gets keyed hashes of
/// them, so the provider learns nothing from a name, not even how many devices
/// write. Names are locators only: after opening a file the reader recomputes
/// its plain name from the content and trusts that.
abstract final class BackupNames {
  /// `c-<device_id, 32 hex>-<seq, 16 hex>`.
  static String change(Uint8List deviceId, int seq) =>
      'c-${toHex(deviceId)}-${seq.toRadixString(16).padLeft(16, '0')}';

  /// `s-<snapshot_id, 32 hex>-<chunk_index, 4 hex>`.
  static String snapshotChunk(Uint8List snapshotId, int chunkIndex) =>
      's-${toHex(snapshotId)}-${chunkIndex.toRadixString(16).padLeft(4, '0')}';

  static String plainNameOf(BackupFileBody body) => body.kind == FileKind.snapshotChunk
      ? snapshotChunk(body.snapshotId!, body.chunkIndex ?? 0)
      : change(body.deviceId, body.seq);

  static final _plain = RegExp(r'^(c-[0-9a-f]{32}-[0-9a-f]{16}|s-[0-9a-f]{32}-[0-9a-f]{4})$');

  static bool isPlainName(String name) => _plain.hasMatch(name);

  /// The folder holding this seed's files at a location other than an LWS:
  /// `b32(H_16[k_name]("folder name"))`.
  static String folder(BackupKeys keys) => base32(keys.nameHash('folder name'));

  /// A file's name at a location other than an LWS:
  /// `b32(H_16[k_name]("file name" ‖ plain_name))`.
  static String hashed(BackupKeys keys, String plainName) =>
      base32(keys.nameHash('file name', ascii.encode(plainName)));

  static final _hashed = RegExp(r'^[a-z2-7]{26}$');

  static bool isHashedName(String name) => _hashed.hasMatch(name);
}

/// Lowercase RFC 4648 base32 without padding, so names survive case-insensitive
/// file systems. 16 bytes give 26 characters.
String base32(Uint8List data) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final b in data) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out.write(alphabet[(buffer >> (bits - 5)) & 31]);
      bits -= 5;
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}
