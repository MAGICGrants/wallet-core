import 'dart:typed_data';

import 'cbor.dart';
import 'crypto.dart';
import 'keys.dart';
import 'padding.dart';
import 'records.dart';

/// One backup file (plan §2.1):
///
/// ```
/// file       = header (3 B) ‖ nonce (24 B) ‖ ciphertext
/// header     = format_version (u8, = 1) ‖ key_epoch (u16, big-endian)   authenticated as AD
/// ciphertext = XChaCha20-Poly1305(k_enc(key_epoch), nonce, AD = header, plaintext)  (+16 B tag)
/// plaintext  = body_len (u32, big-endian) ‖ body ‖ zero padding
/// body       = deterministic CBOR map, keys 0–10
/// ```
///
/// Only the version and the epoch are visible. There is no magic number, so a
/// file does not announce what it is.
const formatVersion = 1;

/// The key epochs this build reads and writes. Only 0 exists yet.
const knownEpochs = {0};
const currentEpoch = 0;

const headerLength = 3;
const _overhead = headerLength + XChaCha20Poly1305.nonceLength + XChaCha20Poly1305.tagLength + 4;

/// The largest body that fits in one file.
const maxBodyLength = maxFileSize - _overhead;

/// The kinds of file.
abstract final class FileKind {
  static const change = 0;
  static const snapshotChunk = 1;
}

enum BackupFileError {
  unknownVersion,
  unknownEpoch,
  sealFailed,
  badPadding,
  notCanonical,
  malformed,
}

class BackupFileException implements Exception {
  const BackupFileException(this.error, [this.detail = '']);

  final BackupFileError error;
  final String detail;

  @override
  String toString() => 'BackupFileException(${error.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// The sealed content of one file.
class BackupFileBody {
  BackupFileBody({
    required this.deviceId,
    required this.seq,
    required this.kind,
    required this.lamport,
    required this.created,
    required this.seen,
    required this.records,
    this.snapshotId,
    this.chunkIndex,
    this.chunkCount,
    this.covers,
  });

  /// 16 random bytes per wallet instance (§4.1).
  final Uint8List deviceId;

  /// Per device, from 1, never reused.
  final int seq;
  final int kind;

  /// The writer's Lamport clock (§4.2).
  final int lamport;

  /// Unix seconds. Display only; nothing orders on it.
  final int created;

  /// For every other device the writer had read: hex device id → highest seq.
  final Map<String, int> seen;
  final List<BackupRecord> records;

  final Uint8List? snapshotId;
  final int? chunkIndex;
  final int? chunkCount;

  /// For a snapshot chunk: hex device id → highest seq it includes.
  final Map<String, int>? covers;

  String get deviceIdHex => toHex(deviceId);

  Uint8List encode() => cborEncode({
    0: deviceId,
    1: seq,
    2: kind,
    3: lamport,
    4: created,
    5: _pairs(seen),
    6: [for (final r in records) CborRaw(r.raw)],
    if (snapshotId != null) 7: snapshotId,
    if (chunkIndex != null) 8: chunkIndex,
    if (chunkCount != null) 9: chunkCount,
    if (covers != null) 10: _pairs(covers!),
  });

  static List<Object?> _pairs(Map<String, int> m) {
    final keys = m.keys.toList()..sort();
    return [
      for (final k in keys) [fromHex(k), m[k]],
    ];
  }

  static BackupFileBody decode(Uint8List body) {
    try {
      cborCheckCanonical(body);
    } on CborFormatException catch (e) {
      throw BackupFileException(BackupFileError.notCanonical, e.message);
    }
    try {
      return _decode(body);
    } on CborFormatException catch (e) {
      throw BackupFileException(BackupFileError.malformed, e.message);
    } on RecordFormatException catch (e) {
      throw BackupFileException(BackupFileError.malformed, e.message);
    } on TypeError catch (e) {
      throw BackupFileException(BackupFileError.malformed, '$e');
    }
  }

  static BackupFileBody _decode(Uint8List body) {
    final r = CborReader(body);
    final count = r.readMapHeader();
    final fields = <int, Object?>{};
    List<BackupRecord>? records;
    for (var i = 0; i < count; i++) {
      final key = r.read();
      if (key is! int) throw const RecordFormatException('body key');
      if (key == 6) {
        final n = r.readArrayHeader();
        records = [for (var j = 0; j < n; j++) BackupRecord.parse(Uint8List.fromList(r.readRaw()))];
      } else {
        // Unknown body keys are a format change; keys 0–10 are fixed by v1.
        if (key > 10) throw const RecordFormatException('unknown body key');
        fields[key] = r.read();
      }
    }
    final deviceId = fields[0];
    if (deviceId is! Uint8List || deviceId.length != 16) {
      throw const RecordFormatException('device id');
    }
    final kind = fields[2] as int;
    if (kind != FileKind.change && kind != FileKind.snapshotChunk) {
      throw const RecordFormatException('file kind');
    }
    final snapshotId = fields[7] as Uint8List?;
    if (kind == FileKind.snapshotChunk && (snapshotId == null || snapshotId.length != 16)) {
      throw const RecordFormatException('snapshot id');
    }
    return BackupFileBody(
      deviceId: deviceId,
      seq: fields[1] as int,
      kind: kind,
      lamport: fields[3] as int,
      created: fields[4] as int,
      seen: _readPairs(fields[5]),
      records: records ?? (throw const RecordFormatException('records')),
      snapshotId: snapshotId,
      chunkIndex: fields[8] as int?,
      chunkCount: fields[9] as int?,
      covers: fields[10] == null ? null : _readPairs(fields[10]),
    );
  }

  static Map<String, int> _readPairs(Object? v) {
    if (v is! List) throw const RecordFormatException('device/seq pairs');
    final out = <String, int>{};
    for (final pair in v) {
      if (pair is! List || pair.length != 2) throw const RecordFormatException('pair');
      final id = pair[0];
      final seq = pair[1];
      if (id is! Uint8List || id.length != 16 || seq is! int) {
        throw const RecordFormatException('pair');
      }
      out[toHex(id)] = seq;
    }
    return out;
  }
}

/// Seals [body] into a complete file, padded to its final size.
Uint8List sealBackupFile(BackupKeys keys, BackupFileBody body, {int epoch = currentEpoch}) {
  final encoded = body.encode();
  return sealEncodedBody(
    keys,
    encoded,
    epoch: epoch,
    exactSize: body.kind == FileKind.snapshotChunk,
  );
}

/// Seals an already-encoded body. Snapshot chunks ([exactSize]) are always
/// exactly [maxFileSize].
Uint8List sealEncodedBody(
  BackupKeys keys,
  Uint8List encoded, {
  int epoch = currentEpoch,
  bool exactSize = false,
}) {
  if (encoded.length > maxBodyLength) throw ArgumentError('body too large: ${encoded.length}');
  final total = exactSize ? maxFileSize : paddedFileSize(_overhead + encoded.length);
  final plaintextLength =
      total - headerLength - XChaCha20Poly1305.nonceLength - XChaCha20Poly1305.tagLength;
  final plaintext = Uint8List(plaintextLength);
  ByteData.sublistView(plaintext).setUint32(0, encoded.length, Endian.big);
  plaintext.setRange(4, 4 + encoded.length, encoded);

  final header = Uint8List(headerLength)
    ..[0] = formatVersion
    ..[1] = epoch >> 8
    ..[2] = epoch & 0xff;
  final nonce = randomBytes(XChaCha20Poly1305.nonceLength);
  final sealed = XChaCha20Poly1305.seal(keys.encryptionKey(epoch), nonce, header, plaintext);
  plaintext.fillRange(0, plaintext.length, 0);

  final out = Uint8List(total)
    ..setRange(0, headerLength, header)
    ..setRange(headerLength, headerLength + nonce.length, nonce)
    ..setRange(headerLength + nonce.length, total, sealed);
  return out;
}

/// The visible header: format version and key epoch.
(int version, int epoch)? peekHeader(Uint8List file) {
  if (file.length < headerLength) return null;
  return (file[0], (file[1] << 8) | file[2]);
}

/// Opens [file]. Used whole or not at all: any failure throws
/// [BackupFileException] and nothing from the file is returned.
BackupFileBody openBackupFile(BackupKeys keys, Uint8List file) {
  final header = peekHeader(file);
  if (header == null) throw const BackupFileException(BackupFileError.malformed, 'too short');
  final (version, epoch) = header;
  if (version != formatVersion) throw const BackupFileException(BackupFileError.unknownVersion);
  if (!knownEpochs.contains(epoch)) throw const BackupFileException(BackupFileError.unknownEpoch);
  if (file.length > maxFileSize ||
      file.length <
          headerLength + XChaCha20Poly1305.nonceLength + XChaCha20Poly1305.tagLength + 4) {
    throw const BackupFileException(BackupFileError.malformed, 'size');
  }

  final Uint8List plaintext;
  try {
    plaintext = XChaCha20Poly1305.open(
      keys.encryptionKey(epoch),
      Uint8List.sublistView(file, headerLength, headerLength + XChaCha20Poly1305.nonceLength),
      Uint8List.sublistView(file, 0, headerLength),
      Uint8List.sublistView(file, headerLength + XChaCha20Poly1305.nonceLength),
    );
  } on AuthenticationFailed {
    throw const BackupFileException(BackupFileError.sealFailed);
  }

  try {
    final bodyLength = ByteData.sublistView(plaintext).getUint32(0, Endian.big);
    if (bodyLength > plaintext.length - 4) {
      throw const BackupFileException(BackupFileError.malformed, 'body length');
    }
    for (var i = 4 + bodyLength; i < plaintext.length; i++) {
      if (plaintext[i] != 0) throw const BackupFileException(BackupFileError.badPadding);
    }
    return BackupFileBody.decode(Uint8List.fromList(plaintext.sublist(4, 4 + bodyLength)));
  } finally {
    plaintext.fillRange(0, plaintext.length, 0);
  }
}
