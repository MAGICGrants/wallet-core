import 'backup_file.dart';
import 'crypto.dart';
import 'records.dart';

/// The merged content of every file read so far (plan §4.3).
///
/// - Outgoing payments: union keyed by txid. Identical copies collapse; two
///   differing copies of one txid are both kept and reported.
/// - Contacts: the version with the highest `(lamport, device_id)` wins,
///   deletions included.
/// - Unknown record types: kept, deduplicated by their bytes.
///
/// Adding the same file twice, or files in any order, gives the same state.
class BackupState {
  final Map<String, List<OutgoingPaymentRecord>> _payments = {};
  final Map<String, ContactRecord> _contacts = {};
  final Map<String, BackupRecord> _unknown = {};

  /// Plain names already merged, so a file is counted once.
  final Set<String> _files = {};

  /// Per device: the change seqs present.
  final Map<String, Set<int>> _seqs = {};

  /// Per device: the highest seq any file says it has seen of it.
  final Map<String, int> _seenBy = {};

  /// Per device: the highest seq covered by a snapshot.
  final Map<String, int> _covered = {};

  int _maxLamport = 0;

  int get maxLamport => _maxLamport;
  int get fileCount => _files.length;
  bool containsFile(String plainName) => _files.contains(plainName);

  /// Highest change seq present for [deviceIdHex], or 0.
  int maxSeqOf(String deviceIdHex) {
    final s = _seqs[deviceIdHex];
    var max = _covered[deviceIdHex] ?? 0;
    if (s != null) {
      for (final v in s) {
        if (v > max) max = v;
      }
    }
    return max;
  }

  /// Every other device's highest seq, for a new file's `seen`.
  Map<String, int> seenExcept(String deviceIdHex) => {
    for (final d in {..._seqs.keys, ..._covered.keys})
      if (d != deviceIdHex) d: maxSeqOf(d),
  };

  /// Merges one opened file. Returns false if it was already merged.
  bool add(String plainName, BackupFileBody body) {
    if (!_files.add(plainName)) return false;
    final device = body.deviceIdHex;
    if (body.kind == FileKind.change) {
      (_seqs[device] ??= {}).add(body.seq);
    }
    for (final e in body.seen.entries) {
      if ((_seenBy[e.key] ?? 0) < e.value) _seenBy[e.key] = e.value;
    }
    for (final e in (body.covers ?? const <String, int>{}).entries) {
      if ((_covered[e.key] ?? 0) < e.value) _covered[e.key] = e.value;
    }
    if (body.lamport > _maxLamport) _maxLamport = body.lamport;
    for (final r in body.records) {
      _addRecord(r);
    }
    return true;
  }

  void _addRecord(BackupRecord r) {
    switch (r) {
      case final OutgoingPaymentRecord p:
        final copies = _payments[p.txidHex] ??= [];
        if (!copies.any((c) => bytesEqual(c.raw, p.raw))) copies.add(p);
      case final ContactRecord c:
        if (c.lamport > _maxLamport) _maxLamport = c.lamport;
        final current = _contacts[c.id];
        if (current == null || c.beats(current)) _contacts[c.id] = c;
      case final UnknownRecord u:
        _unknown.putIfAbsent(toHex(u.raw), () => u);
    }
  }

  /// One copy per txid: of the copies carrying a tx key (or of all, if none
  /// does), the one with the lowest bytes, so every reader picks the same.
  OutgoingPaymentRecord? payment(String txidHex) {
    final copies = _payments[txidHex];
    if (copies == null || copies.isEmpty) return null;
    final keyed = copies.where((c) => c.hasTxKey).toList();
    final pool = keyed.isEmpty ? copies : keyed;
    return pool.reduce((a, b) => compareBytes(a.raw, b.raw) <= 0 ? a : b);
  }

  bool hasPayment(String txidHex) => _payments.containsKey(txidHex);

  Iterable<OutgoingPaymentRecord> get payments sync* {
    for (final txid in _payments.keys) {
      yield payment(txid)!;
    }
  }

  int get paymentCount => _payments.length;

  /// Txids with more than one differing record.
  List<String> get conflictingPayments => [
    for (final e in _payments.entries)
      if (e.value.length > 1) e.key,
  ];

  /// The winning version of every contact, deletions included.
  Map<String, ContactRecord> get contactVersions => Map.unmodifiable(_contacts);

  /// Live contacts: winners that are not deletions.
  Iterable<ContactRecord> get contacts => _contacts.values.where((c) => !c.deleted);

  int get unknownRecordCount => _unknown.length;

  /// Sequence gaps per device: seqs below the highest present that no file
  /// holds and no snapshot covers.
  Map<String, List<int>> get gaps {
    final out = <String, List<int>>{};
    for (final e in _seqs.entries) {
      final covered = _covered[e.key] ?? 0;
      final max = e.value.fold<int>(covered, (a, b) => a > b ? a : b);
      final missing = [
        for (var s = covered + 1; s <= max; s++)
          if (!e.value.contains(s)) s,
      ];
      if (missing.isNotEmpty) out[e.key] = missing;
    }
    return out;
  }

  /// Devices another device has seen further than their files reach here:
  /// hex device id → how many seqs are missing at the end.
  Map<String, int> get missingTails {
    final out = <String, int>{};
    for (final e in _seenBy.entries) {
      final have = maxSeqOf(e.key);
      if (e.value > have) out[e.key] = e.value - have;
    }
    return out;
  }
}
