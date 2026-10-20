import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:pointycastle/export.dart' show SHA256Digest;
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_infra/wallet_infra.dart';

import 'backup_file.dart';
import 'bundle.dart';
import 'cbor.dart';
import 'crypto.dart';
import 'keys.dart';
import 'location.dart';
import 'merge.dart';
import 'monero_address.dart';
import 'naming.dart';
import 'records.dart';

/// Why the backup is or is not running.
enum BackupAvailability {
  /// No wallet unlocked yet, or locked again.
  closed,

  /// Keys are being derived and the local copy read.
  opening,
  open,

  /// A 25-word seed: it *is* the spend key, so nothing is derived from it.
  legacySeed,

  /// A polyseed with an offset passphrase, which this version cannot key.
  unsupportedPassphrase,
}

/// One storage location the app offers, and how the service treats it. Every
/// location is off until the user turns it on.
class BackupLocationConfig {
  const BackupLocationConfig({
    required this.location,
    this.delayPayments = false,
    this.onDevice = false,
  });

  final BackupLocation location;

  /// Upload payment records after a random delay, so an
  /// upload right after a send says less about it. For locations that do not
  /// already see the send.
  final bool delayPayments;

  /// The location is a folder on this device that the OS copies off it
  /// (Android Auto Backup). Deleting the wallet deletes it.
  final bool onDevice;
}

/// What the service last saw at one location.
class LocationStatus {
  const LocationStatus({
    required this.id,
    required this.enabled,
    this.available,
    this.fileCount,
    this.pendingUploads = 0,
    this.awaitingConfirmation = 0,
    this.bytes,
    this.lastUpload,
    this.lastError,
  });

  final String id;
  final bool enabled;

  /// Null until checked.
  final bool? available;

  /// Files there for this wallet, as last listed.
  final int? fileCount;

  /// Local files not there yet (including payments held back by the delay).
  final int pendingUploads;

  /// Files handed over that the provider has not yet reported as uploaded.
  final int awaitingConfirmation;

  /// Bytes used, for an on-device folder.
  final int? bytes;
  final DateTime? lastUpload;
  final String? lastError;
}

/// What one location holds for the unlocked wallet, as [MetadataBackupService.findBackups]
/// saw it without writing anything.
class LocationProbe {
  const LocationProbe({required this.id, required this.available, required this.files});

  final String id;

  /// Whether the location could be reached (e.g. iCloud Drive signed in).
  final bool available;

  /// Files there for this wallet; 0 when there are none or it is unavailable.
  final int files;

  bool get found => available && files > 0;
}

/// A file that could not be used, and why.
class FailedFile {
  const FailedFile(this.locationId, this.name, this.reason);

  final String locationId;
  final String name;
  final String reason;
}

/// What a restore found.
class RestoreReport {
  const RestoreReport({
    required this.at,
    required this.filesRead,
    required this.payments,
    required this.contactsRestored,
    required this.failed,
    required this.gaps,
    required this.missingTails,
    required this.conflictingPayments,
  });

  final DateTime at;
  final int filesRead;
  final int payments;
  final int contactsRestored;
  final List<FailedFile> failed;

  /// Device (hex) → missing seqs.
  final Map<String, List<int>> gaps;

  /// Device (hex) → seqs another device saw that no file here holds.
  final Map<String, int> missingTails;
  final List<String> conflictingPayments;

  bool get isClean =>
      failed.isEmpty && gaps.isEmpty && missingTails.isEmpty && conflictingPayments.isEmpty;
}

/// The result of importing a backup file.
class ImportResult {
  const ImportResult({required this.added, required this.alreadyPresent, required this.failed});

  final int added;
  final int alreadyPresent;
  final int failed;
}

/// Persisted per wallet: the device id, the next seq, the Lamport clock, and
/// the address book as of the last sync, which is the base the next sync
/// compares against to tell a local edit from a remote one.
class _DeviceState {
  _DeviceState({
    required this.deviceId,
    required this.nextSeq,
    required this.lamport,
    required this.contactBase,
    required this.contactsJoined,
  });

  /// A device that has not synced its address book yet: it joins first.
  factory _DeviceState.fresh() => _DeviceState(
    deviceId: randomBytes(16),
    nextSeq: 1,
    lamport: 0,
    contactBase: {},
    contactsJoined: false,
  );

  Uint8List deviceId;
  int nextSeq;
  int lamport;

  /// Contact id → fingerprint of the version this device last had.
  Map<String, String> contactBase;

  /// Whether [contactBase] is this device's own last sync. Until it is, the
  /// address book joins the backup rather than merging against a base (see
  /// [MetadataBackupService._syncContacts]).
  bool contactsJoined;

  Map<String, Object?> toJson() => {
    'v': 1,
    'device': toHex(deviceId),
    'nextSeq': nextSeq,
    'lamport': lamport,
    'contacts': contactBase,
    'joined': contactsJoined,
  };

  static _DeviceState? fromJson(Object? j) {
    if (j is! Map<String, dynamic> || j['v'] != 1) return null;
    try {
      return _DeviceState(
        deviceId: fromHex(j['device'] as String),
        nextSeq: j['nextSeq'] as int,
        lamport: j['lamport'] as int,
        contactBase: (j['contacts'] as Map<String, dynamic>).cast<String, String>(),
        // A state written before joining existed comes from a device that was
        // already syncing.
        contactsJoined: j['joined'] as bool? ?? true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// The seed-keyed metadata backup: payment destinations and
/// transaction keys of Monero sends, and the address book, as many small
/// sealed files in every chosen location.
///
/// Opt-in: off until the user turns it on ([setEnabled]), and then each
/// location is off until the user turns that on too. While it is off nothing is
/// written, not even the local copy or the device state, and no location is
/// read; the service only holds the keys of the unlocked wallet, so turning it
/// on works without unlocking again.
///
/// Each change becomes one file: written to the local copy first, then
/// uploaded to every enabled location. Every sync lists each location, opens
/// anything new, merges it, applies what changed elsewhere to the address book,
/// and uploads what a location is missing. Nothing is ever deleted from a
/// location here: compaction is not in this version.
class MetadataBackupService extends ChangeNotifier
    with WidgetsBindingObserver
    implements MetadataBackup {
  MetadataBackupService({
    required Future<Directory> Function() localRoot,
    Future<Directory> Function()? stateRoot,
    this._locations = const [],
    this.paymentUploadDelay = const Duration(minutes: 10),
    this.pollInterval = const Duration(minutes: 5),
    this.observeLifecycle = true,
    Future<List<String>?> Function()? readContacts,
    Future<void> Function(Map<String, Contact?> changes)? applyContactChanges,
    DateTime Function()? clock,
    Random? random,
  }) : _localRoot = localRoot,
       _stateRoot = stateRoot ?? localRoot,
       _readContacts = readContacts ?? readEncodedContacts,
       _applyContacts = applyContactChanges ?? ContactsSync.applyRemote,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  /// Preference key of the backup's own switch; off when absent.
  static const enabledPrefKey = 'metadataBackup.enabled';

  /// Preference keys: `metadataBackup.enabled.<location id>`; off when absent.
  static String enabledKey(String locationId) => 'metadataBackup.enabled.$locationId';

  final Future<Directory> Function() _localRoot;

  /// Where the device state lives. Kept out of phone backups where the app
  /// can arrange it (iOS), so a phone restored from a backup starts a new
  /// device id instead of writing as the old phone.
  final Future<Directory> Function() _stateRoot;
  final List<BackupLocationConfig> _locations;
  final Duration paymentUploadDelay;
  final Duration pollInterval;
  final bool observeLifecycle;
  final Future<List<String>?> Function() _readContacts;
  final Future<void> Function(Map<String, Contact?>) _applyContacts;
  final DateTime Function() _clock;
  final Random _random;

  BackupAvailability _availability = BackupAvailability.closed;
  BackupKeys? _keys;
  String? _folder;
  _DeviceState? _state;
  BackupState _merged = BackupState();
  List<CryptoWallet> _wallets = const [];

  /// Plain names in the local copy, and each one's name at other locations.
  final Map<String, String> _hashedNames = {};

  /// Names at a location that failed to open, so they are not fetched again
  /// every sync. Per location id.
  final Map<String, Set<String>> _rejected = {};
  final List<FailedFile> _failed = [];

  /// Payment files held back from delayed locations until this time.
  final Map<String, DateTime> _notBefore = {};

  /// Files handed to a location, not yet reported uploaded.
  final Map<String, Set<String>> _awaiting = {};

  /// Locations whose files have been checked for upload once this session:
  /// nothing here remembers what an earlier session handed over.
  final Set<String> _uploadChecked = {};

  final Map<String, LocationStatus> _locationStatus = {};
  final Map<String, bool> _enabled = {};
  bool? _on;

  Timer? _pollTimer;
  Timer? _delayTimer;
  Timer? _historyDebounce;
  bool _observing = false;
  Future<void> _chain = Future.value();
  DateTime? _lastSync;
  String? _lastError;
  RestoreReport? _lastRestore;
  Completer<RestoreReport?>? _restoreDone;

  // ----- Status for the UI -----

  BackupAvailability get availability => _availability;
  bool get isOpen => _availability == BackupAvailability.open;

  /// Whether the user has turned the backup on, as last read ([isEnabled]).
  bool get enabled => _on ?? false;

  /// On and open: the device state and the local copy are loaded, so changes
  /// can be written. Every write and sync checks this.
  bool get _active => isOpen && _state != null;
  DateTime? get lastSync => _lastSync;
  String? get lastError => _lastError;
  int get fileCount => _merged.fileCount;
  int get paymentCount => _merged.paymentCount;

  /// The contacts a file saved now would carry: the backup's, or with no
  /// location on (when the address book is not recorded), the address book's.
  int get contactCount => _contactsSyncing ? _merged.contacts.length : _addressBookSize;
  List<FailedFile> get failedFiles => List.unmodifiable(_failed);
  RestoreReport? get lastRestoreReport => _lastRestore;

  /// What the restore in progress found, once its first sync is done; null if
  /// the seed has no backup or the backup could not open. Completes at once
  /// when no restore is running.
  Future<RestoreReport?> restoreResult() => _restoreDone?.future ?? Future.value(_lastRestore);
  List<BackupLocationConfig> get locations => List.unmodifiable(_locations);

  LocationStatus statusOf(String locationId) =>
      _locationStatus[locationId] ??
      LocationStatus(id: locationId, enabled: _enabled[locationId] ?? false);

  /// Outgoing Monero transactions in history with no backup record: sent from
  /// another wallet, or before this backup existed and since lost.
  int get unrecordedOutgoingCount {
    var n = 0;
    for (final w in _wallets.where(_eligible)) {
      for (final tx in w.txHistory) {
        if (tx.direction == txDirectionOutgoing && !_merged.hasPayment(tx.hash)) n++;
      }
    }
    return n;
  }

  // ----- Settings -----

  /// Whether the user has turned the backup on. Off by default.
  Future<bool> isEnabled() async =>
      _on ??= await SharedPreferencesService.get<bool>(enabledPrefKey) ?? false;

  /// Turns the backup on or off.
  ///
  /// On: keeps the local copy (from which a backup file is saved), and records
  /// every past payment and the address book in it. [locations] are turned on in
  /// the same step, so the first sync already reads and writes them; with
  /// [reportRestore] it reports what they held, as after a restore, and starts a
  /// new device id.
  ///
  /// Off: turns every location off, and deletes the local copy and the device
  /// state. Every location keeps its files: nothing but [deleteFromLocation]
  /// deletes them.
  Future<void> setEnabled(
    bool enabled, {
    Iterable<String> locations = const [],
    bool reportRestore = false,
  }) async {
    if (enabled) {
      for (final id in locations) {
        _enabled[id] = true;
        await SharedPreferencesService.set<bool>(enabledKey(id), true);
      }
      _on = true;
      await SharedPreferencesService.set<bool>(enabledPrefKey, true);
      await _serial(() async {
        if (isOpen && _state == null) await _activate(restored: reportRestore);
      });
      notifyListeners();
      if (_active) {
        _startTimers();
        await sync(reportRestore: reportRestore);
      }
      return;
    }

    _on = false;
    await SharedPreferencesService.set<bool>(enabledPrefKey, false);
    _stopTimers();
    for (final c in _locations) {
      final id = c.location.id;
      _enabled[id] = false;
      await SharedPreferencesService.set<bool>(enabledKey(id), false);
    }
    await _serial(() async {
      final folder = _folder;
      if (folder != null) {
        await _local.deleteFolder(folder);
        final state = await _stateFile();
        if (await state.exists()) await state.delete();
      }
      _deactivate();
    });
    notifyListeners();
  }

  Future<bool> isLocationEnabled(String id) async =>
      _enabled[id] ??= await SharedPreferencesService.get<bool>(enabledKey(id)) ?? false;

  /// Turns a location on or off. Turning on reads what is there and uploads
  /// everything it lacks, adding files and never removing or replacing one.
  /// Turning off only stops adding: the files stay, and Android backup keeps
  /// carrying an on-device location's, until [deleteFromLocation].
  ///
  /// With the last one off, the address book stops syncing: the next one
  /// turned on joins ([_syncContacts]).
  Future<void> setLocationEnabled(String id, bool enabled) async {
    _enabled[id] = enabled;
    await SharedPreferencesService.set<bool>(enabledKey(id), enabled);
    if (!enabled && !await _anyLocationEnabled()) {
      await _serial(() async {
        final state = _state;
        if (state != null) await _leaveContactSync(state);
      });
    }
    _locationStatus[id] = LocationStatus(id: id, enabled: enabled);
    notifyListeners();
    if (enabled) unawaited(sync());
  }

  /// Looks in every location for this wallet's backup without writing anything
  /// or turning anything on, even with the backup off: the after-restore
  /// question asks this before the user has chosen to use any location.
  /// Needs the wallet unlocked ([isOpen]).
  Future<List<LocationProbe>> findBackups() => _serial(() async {
    final folder = _folder;
    if (!isOpen || folder == null) throw StateError('The backup is not open.');
    return [for (final c in _locations) await _probe(c.location, folder)];
  });

  Future<LocationProbe> _probe(BackupLocation location, String folder) async {
    try {
      if (!await location.isAvailable()) {
        return LocationProbe(id: location.id, available: false, files: 0);
      }
      final files = (await location.list(folder)).length;
      return LocationProbe(id: location.id, available: true, files: files);
    } catch (e) {
      log(LogLevel.warn, '[Backup] Location ${location.id}: $e');
      return LocationProbe(id: location.id, available: false, files: 0);
    }
  }

  /// How many of this wallet's files [id] holds, without reading or writing
  /// any, even with the backup or [id] off. A location that is off can still
  /// hold some: the files stay when it is turned off, and Android puts back a
  /// copy with the app's files. They stay until the user deletes them
  /// ([deleteFromLocation]); turning the location on reads them. Needs the
  /// wallet unlocked ([isOpen]); 0 otherwise.
  Future<int> filesIn(String id) => _serial(() async {
    final folder = _folder;
    if (!isOpen || folder == null) return 0;
    return (await _probe(_locations.firstWhere((c) => c.location.id == id).location, folder)).files;
  });

  /// Deletes this wallet's files from [id], e.g. the iCloud copy: the only
  /// way a location's files are ever deleted. The local copy and every other
  /// location keep theirs.
  Future<void> deleteFromLocation(String id) => _serial(() async {
    final folder = _folder;
    if (folder == null) return;
    await _locations.firstWhere((c) => c.location.id == id).location.deleteFolder(folder);
    _rejected.remove(id);
    _awaiting.remove(id);
    _uploadChecked.remove(id);
    _locationStatus[id] = LocationStatus(id: id, enabled: await isLocationEnabled(id));
    notifyListeners();
  });

  // ----- MetadataBackup -----

  @override
  Future<void> open(
    SeedSource seed, {
    required List<CryptoWallet> wallets,
    bool restored = false,
  }) async {
    if (restored) {
      _restoreDone = Completer<RestoreReport?>();
      _lastRestore = null;
    }
    try {
      await _open(seed, wallets: wallets, restored: restored);
    } finally {
      if (_restoreDone?.isCompleted == false) _restoreDone!.complete(_lastRestore);
    }
  }

  Future<void> _open(
    SeedSource seed, {
    required List<CryptoWallet> wallets,
    required bool restored,
  }) async {
    if (!SeedSecret.isAvailableFor(seed)) {
      await close();
      _availability = seed is MoneroLegacySeed
          ? BackupAvailability.legacySeed
          : BackupAvailability.unsupportedPassphrase;
      notifyListeners();
      return;
    }

    final m = await SeedSecret.derive(seed, SeedPurpose.metadata);
    final keys = BackupKeys.fromMetadataRoot(m);
    m.fillRange(0, m.length, 0);
    final folder = BackupNames.folder(keys);

    await _serial(() async {
      // The same wallet again (a re-open after a connection change): keep the
      // state, just sync.
      if (isOpen && folder == _folder && !restored) {
        keys.wipe();
        _wallets = wallets;
        return;
      }
      _resetSession();
      _keys = keys;
      _folder = folder;
      _wallets = wallets;
      _availability = BackupAvailability.opening;
      notifyListeners();

      // Off: only the keys, so the user can turn it on from here. Nothing is
      // read or written until then.
      if (await isEnabled()) await _activate(restored: restored);
      _availability = BackupAvailability.open;
    });

    if (!_active) {
      notifyListeners();
      return;
    }
    _startTimers();
    await sync(reportRestore: restored);
  }

  /// Loads (or starts) the device state and the local copy: what being on
  /// needs. A restore always starts a new device id; so does a first run.
  Future<void> _activate({required bool restored}) async {
    _state = restored ? null : await _loadState();
    if (_state == null) {
      // A restore or a first run joins the backup's address book; no earlier
      // base carries over.
      _state = _DeviceState.fresh();
      await _saveState();
    }
    await _loadLocalCopy();
  }

  @override
  Future<void> close() async {
    _stopTimers();
    await _serial(() async {
      _resetSession();
      _availability = BackupAvailability.closed;
    });
    notifyListeners();
  }

  /// Also forgets the switches, so a wallet made after this one starts with
  /// the backup off. Every location keeps its files, as [setEnabled] leaves
  /// them: only the user deletes those ([deleteFromLocation]).
  @override
  Future<void> deleteLocal() async {
    await close();
    _on = null;
    _enabled.clear();
    await SharedPreferencesService.remove(enabledPrefKey);
    for (final c in _locations) {
      await SharedPreferencesService.remove(enabledKey(c.location.id));
    }
    await _serial(() async {
      for (final root in {(await _localRoot()).path, (await _stateRoot()).path}) {
        final dir = Directory(root);
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    });
  }

  @override
  void contactsChanged() {
    if (_active) unawaited(sync());
  }

  @override
  void historyChanged(CryptoWallet wallet) {
    if (!_active || !_eligible(wallet)) return;
    _historyDebounce?.cancel();
    _historyDebounce = Timer(const Duration(seconds: 2), () {
      unawaited(
        _serial(() async {
          if (await _recordPaymentsFromHistory()) await _upload();
          notifyListeners();
        }),
      );
    });
  }

  @override
  void outgoingPaymentSent(
    CryptoWallet wallet, {
    required String txid,
    required int accountIndex,
    required BigInt fee,
    required List<TxRecipient> recipients,
    required String txKey,
  }) {
    // Without its key the record could never gain one (records are written
    // once); the history scan writes it instead, once the key is known.
    if (!_active || !_eligible(wallet) || txKey.isEmpty) return;
    unawaited(
      _serial(() async {
        if (_merged.hasPayment(txid)) return;
        final record = _paymentRecord(txid, accountIndex, fee, recipients, txKey);
        if (record == null) return;
        await _writeChange([(_) => record], payment: true);
        await _upload();
        notifyListeners();
      }).catchError((Object e) {
        log(LogLevel.warn, '[Backup] Payment record not written: $e');
      }),
    );
  }

  @override
  BackedUpPayment? outgoingPayment(CryptoWallet wallet, String txid) {
    if (!isOpen || !_eligible(wallet)) return null;
    final p = _merged.payment(txid);
    if (p == null) return null;
    return BackedUpPayment(
      recipients: [
        for (final d in p.destinations)
          if (_addressOf(d) case final address?) TxRecipient(address, d.amount),
      ],
      txKey: p.txKeyHex,
    );
  }

  // ----- Sync -----

  /// Lists every enabled location, merges what is new, applies remote
  /// address-book changes, records new payments, and uploads what each
  /// location lacks.
  Future<void> sync({bool reportRestore = false}) => _serial(() async {
    if (!_active) return;
    final failedBefore = _failed.length;
    final listings = <String, Set<String>>{};
    _lastError = null;

    // Whether every enabled location was read: an address book joins only
    // against the whole backup.
    var readAll = true;
    var syncing = false;
    for (final config in _locations) {
      final id = config.location.id;
      if (!await isLocationEnabled(id)) continue;
      syncing = true;
      try {
        listings[id] = await _ingest(config.location);
        final read = _locationStatus[id];
        if (read?.available != true || read?.lastError != null) readAll = false;
      } catch (e) {
        readAll = false;
        _setLocationError(id, e);
      }
    }
    await _checkDeviceIdClash();

    var contactsRestored = 0;
    try {
      contactsRestored = await _syncContacts(backupRead: readAll, syncing: syncing);
    } catch (e) {
      _lastError = 'Address book: $e';
      log(LogLevel.warn, '[Backup] Address book sync failed: $e');
    }
    try {
      await _recordPaymentsFromHistory();
    } catch (e) {
      log(LogLevel.warn, '[Backup] Payment scan failed: $e');
    }
    await _upload(listings: listings);

    _lastSync = _clock();
    if (reportRestore) {
      _lastRestore = RestoreReport(
        at: _lastSync!,
        filesRead: _merged.fileCount,
        payments: _merged.paymentCount,
        contactsRestored: contactsRestored,
        failed: _failed.sublist(failedBefore),
        gaps: _merged.gaps,
        missingTails: _merged.missingTails,
        conflictingPayments: _merged.conflictingPayments,
      );
    }
    notifyListeners();
  });

  /// Reads every file at [location] this device has not seen. Returns the
  /// names listed, for the upload step.
  Future<Set<String>> _ingest(BackupLocation location) async {
    final id = location.id;
    if (!await location.isAvailable()) {
      _locationStatus[id] = LocationStatus(id: id, enabled: true, available: false);
      return {};
    }
    final keys = _keys!;
    final folder = _folder!;
    final names = (await location.list(folder)).toSet();
    final known = _hashedNames.values.toSet();
    final rejected = _rejected[id] ??= {};

    Object? readError;
    for (final name in names) {
      if (known.contains(name) || rejected.contains(name)) continue;
      if (!BackupNames.isHashedName(name)) continue; // not ours
      final Uint8List? bytes;
      try {
        bytes = await location.read(folder, name);
      } on BackupFileTooLarge {
        // No backup file is this large: rejected like a malformed one, never
        // read into memory, and the rest are read.
        rejected.add(name);
        _failed.add(FailedFile(id, name, 'too large'));
        continue;
      } catch (e) {
        // Possibly passing (a download that timed out): skipped this time and
        // tried again at the next sync. The rest are still read, but the
        // location does not count as read in full (the error in its status),
        // so the address book does not join against it yet.
        readError ??= e;
        continue;
      }
      if (bytes == null) continue; // removed since the listing; not an error
      final BackupFileBody body;
      try {
        body = openBackupFile(keys, bytes);
      } on BackupFileException catch (e) {
        rejected.add(name);
        _failed.add(FailedFile(id, name, e.error.name));
        continue;
      }
      final plain = BackupNames.plainNameOf(body);
      if (BackupNames.hashed(keys, plain) != name) {
        // Names are locators only; the sealed content is what is trusted. It
        // is merged, and its rightly named copy uploaded; not fetched again.
        _failed.add(FailedFile(id, name, 'name does not match content'));
        rejected.add(name);
      }
      if (!_merged.containsFile(plain)) {
        await _local.create(folder, plain, bytes);
        _hashedNames[plain] = BackupNames.hashed(keys, plain);
        _merged.add(plain, body);
      }
    }
    _locationStatus[id] = LocationStatus(
      id: id,
      enabled: true,
      available: true,
      fileCount: names.length,
      bytes: location is FolderLocation ? await location.totalBytes() : null,
      lastUpload: _locationStatus[id]?.lastUpload,
      lastError: readError == null ? null : 'A backup file could not be read: $readError',
    );
    return names;
  }

  /// A file carrying this device's id at or past its next seq means another
  /// instance (a cloned or restored copy) is writing as this device. Start a
  /// new id so no seq is ever used twice.
  Future<void> _checkDeviceIdClash() async {
    final state = _state!;
    if (_merged.maxSeqOf(toHex(state.deviceId)) >= state.nextSeq) {
      log(
        LogLevel.warn,
        '[Backup] Another instance wrote as this device; starting a new device id.',
      );
      state
        ..deviceId = randomBytes(16)
        ..nextSeq = 1;
      await _saveState();
    }
  }

  /// The address-book merge. Only changes made while syncing travel (see the
  /// README).
  ///
  /// A device that has synced before merges three ways. The base is what the
  /// address book held at the end of the last sync, kept in the device state
  /// as fingerprints:
  /// - A contact that differs from what this device last had is a local edit,
  ///   and one missing from it a local deletion: either is written as a new
  ///   version, which then wins (it has the highest clock).
  /// - Everything else that differs from the merged state is a change made
  ///   elsewhere, and is applied to the address book.
  ///
  /// A device that joins (first sync, restore, or a location turned back on
  /// after none was) has no base of its own, so it cannot tell its edits from
  /// a stale copy: the backup's version wins for every contact it knows,
  /// deletions included, and only contacts it has never seen are written. It
  /// joins only once [backupRead] says every enabled location was read.
  ///
  /// With no location on ([syncing] false: a copy kept for saving files), the
  /// address book does not sync at all. Nothing is recorded, so no change
  /// made meanwhile can travel later, and the next location turned on joins.
  /// A file imported meanwhile is applied as a join applies the backup.
  ///
  /// Returns how many contacts were added or changed from the backup.
  Future<int> _syncContacts({required bool backupRead, required bool syncing}) async {
    final state = _state!;
    final imported = _importToApply;
    _importToApply = false;
    _contactsSyncing = syncing;
    if (!syncing) {
      await _leaveContactSync(state);
      final local = await _localContacts();
      if (local == null) return 0;
      if (!imported) {
        _addressBookSize = local.length;
        return 0;
      }
      final applied = await _applyMerged(local);
      _addressBookSize = (await _localContacts())?.length ?? local.length;
      return applied;
    }
    final joining = !state.contactsJoined;
    if (joining && !backupRead) return 0; // join against the whole backup, later
    final local = await _localContacts();
    if (local == null) return 0; // unreadable: change nothing, try next time
    final lastSeen = state.contactBase;

    final writes = <BackupRecord Function(int lamport)>[];
    final deviceId = state.deviceId;
    BackupRecord version(Contact c, int lamport) => ContactRecord(
      id: c.id,
      name: c.name,
      addresses: c.addresses,
      lamport: lamport,
      deviceId: deviceId,
    );
    if (joining) {
      for (final c in local.values) {
        if (!_merged.contactVersions.containsKey(c.id)) writes.add((l) => version(c, l));
      }
    } else {
      for (final c in local.values) {
        final fp = _fingerprint(c.name, c.addresses);
        final merged = _merged.contactVersions[c.id];
        final mergedFp = merged == null || merged.deleted
            ? null
            : _fingerprint(merged.name, merged.addresses);
        if (lastSeen[c.id] != fp && mergedFp != fp) writes.add((l) => version(c, l));
      }
      for (final id in lastSeen.keys) {
        if (local.containsKey(id)) continue;
        final merged = _merged.contactVersions[id];
        if (merged != null && merged.deleted) continue;
        writes.add(
          (lamport) => ContactRecord.deletion(id: id, lamport: lamport, deviceId: deviceId),
        );
      }
    }
    if (writes.isNotEmpty) await _writeChange(writes);
    final changes = _mergedChanges(local);
    final stored = await _storeChanges(changes);

    // The new base is what the address book now holds: the merged state,
    // except for changes that were not stored. For those it still holds what it
    // did, and so must the base: a contact the base has and the address book
    // lacks would be recorded as deleted here, and an older version as an edit
    // made here, undoing the change everywhere. Left out, they are applied
    // again by the next sync.
    final base = {for (final v in _merged.contacts) v.id: _fingerprint(v.name, v.addresses)};
    if (!stored) {
      for (final id in changes.keys) {
        final mine = local[id];
        if (mine == null) {
          base.remove(id);
        } else {
          base[id] = _fingerprint(mine.name, mine.addresses);
        }
      }
    }
    state
      ..contactBase = base
      ..contactsJoined = true;
    await _saveState();
    return stored ? changes.values.whereType<Contact>().length : 0;
  }

  /// Set by [importBundle] for the sync that follows it.
  bool _importToApply = false;

  /// Whether the last sync had a location to sync the address book with, and
  /// the address book's size when it had none ([contactCount]).
  bool _contactsSyncing = true;
  int _addressBookSize = 0;

  /// The address book, by id; null when it cannot be read.
  Future<Map<String, Contact>?> _localContacts() async {
    final stored = await _readContacts();
    if (stored == null) return null;
    return {
      for (final e in stored)
        if (Contact.fromJson(json.decode(e) as Map<String, dynamic>) case final c) c.id: c,
    };
  }

  /// No location left to sync with: the base goes, and the next sync with one
  /// joins.
  Future<void> _leaveContactSync(_DeviceState state) async {
    if (!state.contactsJoined && state.contactBase.isEmpty) return;
    state
      ..contactsJoined = false
      ..contactBase = {};
    await _saveState();
  }

  /// Applies to the address book ([local]) what the merged state says and it
  /// does not. Returns how many contacts were added or changed: none when the
  /// changes could not be stored.
  Future<int> _applyMerged(Map<String, Contact> local) async {
    final changes = _mergedChanges(local);
    return await _storeChanges(changes) ? changes.values.whereType<Contact>().length : 0;
  }

  /// Stores [changes] in the address book. False when they were not stored
  /// (it could not be read or written): it keeps what it had, and the next
  /// sync applies them again.
  Future<bool> _storeChanges(Map<String, Contact?> changes) async {
    if (changes.isEmpty) return true;
    try {
      await _applyContacts(changes);
      return true;
    } catch (e) {
      unawaited(log(LogLevel.warn, 'Address book changes from the backup not stored: $e'));
      return false;
    }
  }

  /// What the merged state says and the address book ([local]) does not: a
  /// contact's new version, or null where it was deleted.
  Map<String, Contact?> _mergedChanges(Map<String, Contact> local) {
    final changes = <String, Contact?>{};
    for (final v in _merged.contactVersions.values) {
      final mine = local[v.id];
      if (v.deleted) {
        if (mine != null) changes[v.id] = null;
        continue;
      }
      if (mine == null ||
          _fingerprint(mine.name, mine.addresses) != _fingerprint(v.name, v.addresses)) {
        changes[v.id] = Contact(id: v.id, name: v.name, addresses: v.addresses);
      }
    }
    return changes;
  }

  String _fingerprint(String name, Map<String, String> addresses) {
    final encoded = cborEncode({0: name, 1: Map<Object, Object?>.from(addresses)});
    return toHex(SHA256Digest().process(encoded).sublist(0, 16));
  }

  /// Records every outgoing Monero payment in history that this wallet built
  /// and that has no backup record yet, including sends from before the
  /// backup existed. Returns whether anything was written.
  ///
  /// Each destination carries the transaction key, so a payment needs its
  /// destinations to be recorded. A record is immutable, so it also waits for
  /// the key: a payment with no key is recorded only once it has 10
  /// confirmations, by when a key that was coming has arrived.
  Future<bool> _recordPaymentsFromHistory() async {
    if (!_active) return false;
    final writes = <BackupRecord Function(int)>[];
    final seen = <String>{};
    for (final w in _wallets.where(_eligible)) {
      for (final tx in w.txHistory) {
        if (tx.direction != txDirectionOutgoing) continue;
        if (tx.recipients.isEmpty) continue;
        if (tx.key.isEmpty && tx.confirmations < 10) continue;
        if (_merged.hasPayment(tx.hash) || !seen.add(tx.hash)) continue;
        final record = _paymentRecord(
          tx.hash,
          tx.accountIndex ?? 0,
          tx.feeBaseUnits,
          tx.recipients.where((r) => !r.isChange).toList(),
          tx.key,
        );
        if (record != null) writes.add((_) => record);
      }
    }
    if (writes.isEmpty) return false;
    await _writeChange(writes, payment: true);
    return true;
  }

  OutgoingPaymentRecord? _paymentRecord(
    String txid,
    int account,
    BigInt fee,
    List<TxRecipient> recipients,
    String txKeyHex,
  ) {
    final Uint8List txidBytes;
    try {
      txidBytes = fromHex(txid);
    } on FormatException {
      return null;
    }
    if (txidBytes.length != 32) return null;

    Uint8List? r;
    final additional = <Uint8List>[];
    if (txKeyHex.length >= 64 && txKeyHex.length % 64 == 0) {
      try {
        final all = fromHex(txKeyHex);
        r = Uint8List.fromList(all.sublist(0, 32));
        for (var i = 32; i < all.length; i += 32) {
          additional.add(Uint8List.fromList(all.sublist(i, i + 32)));
        }
      } on FormatException {
        r = null;
        additional.clear();
      }
    }

    // Each destination carries the key. For a legacy transaction that is `r`
    // and every additional key: which additional key is which destination's
    // output is not known without scanning the transaction.
    final destinations = <PaymentDestination>[];
    for (final recipient in recipients) {
      final a = MoneroAddress.tryParse(recipient.address);
      if (a == null || a.network != MoneroNetwork.mainnet) {
        log(LogLevel.warn, '[Backup] Skipping a destination that is not a mainnet address.');
        continue;
      }
      destinations.add(
        PaymentDestination(
          kind: a.kind.index,
          spendPublicKey: a.spendPublicKey,
          viewPublicKey: a.viewPublicKey,
          amount: recipient.amountBaseUnits,
          txKey: r,
          additionalTxKeys: r == null ? const [] : additional,
          paymentId: a.paymentId,
        ),
      );
    }
    // The key belongs to a destination, so a payment with none has nothing to
    // record.
    if (destinations.isEmpty) return null;
    return OutgoingPaymentRecord(
      txid: txidBytes,
      account: account,
      fee: fee,
      destinations: destinations,
    );
  }

  String? _addressOf(PaymentDestination d) {
    if (d.kind < 0 || d.kind >= MoneroAddressKind.values.length) return null;
    final kind = MoneroAddressKind.values[d.kind];
    if (kind == MoneroAddressKind.integrated && d.paymentId == null) return null;
    return MoneroAddress(
      network: MoneroNetwork.mainnet,
      kind: kind,
      spendPublicKey: d.spendPublicKey,
      viewPublicKey: d.viewPublicKey,
      paymentId: kind == MoneroAddressKind.integrated ? d.paymentId : null,
    ).encode();
  }

  /// Mainnet Monero only, in this version.
  bool _eligible(CryptoWallet w) => w.coinSymbol.toUpperCase() == 'XMR' && !w.isTestnet;

  // ----- Writing -----

  /// Writes [builders] as one or more change files: the seq is
  /// saved before the file is written, the file goes to the local copy
  /// (temporary name, flushed, renamed), and then to every location on the
  /// next upload. Each builder gets the file's Lamport clock.
  Future<void> _writeChange(
    List<BackupRecord Function(int lamport)> builders, {
    bool payment = false,
  }) async {
    var i = 0;
    while (i < builders.length) {
      final state = _state!;
      final lamport = max(state.lamport, _merged.maxLamport) + 1;
      final records = <BackupRecord>[];
      var size = 0;
      // Room for the body's own fields, generously.
      const fixed = 256;
      while (i < builders.length) {
        final r = builders[i](lamport);
        if (records.isNotEmpty && fixed + size + r.raw.length > maxBodyLength) break;
        if (fixed + r.raw.length > maxBodyLength) {
          log(LogLevel.warn, '[Backup] Skipping a record too large for one file.');
          i++;
          continue;
        }
        records.add(r);
        size += r.raw.length;
        i++;
      }
      if (records.isEmpty) continue;

      final seq = state.nextSeq;
      state
        ..nextSeq = seq + 1
        ..lamport = lamport;
      await _saveState();

      final body = BackupFileBody(
        deviceId: state.deviceId,
        seq: seq,
        kind: FileKind.change,
        lamport: lamport,
        created: _clock().millisecondsSinceEpoch ~/ 1000,
        seen: _merged.seenExcept(toHex(state.deviceId)),
        records: records,
      );
      final bytes = sealBackupFile(_keys!, body);
      final plain = BackupNames.change(state.deviceId, seq);
      await _local.create(_folder!, plain, bytes);
      _hashedNames[plain] = BackupNames.hashed(_keys!, plain);
      _merged.add(plain, body);
      if (payment) {
        final delayMs = paymentUploadDelay.inMilliseconds;
        _notBefore[plain] = _clock().add(
          Duration(milliseconds: delayMs <= 0 ? 0 : _random.nextInt(delayMs + 1)),
        );
      }
    }
  }

  /// Uploads every local file a location lacks (self-healing).
  /// [listings] reuses names already listed this sync.
  Future<void> _upload({Map<String, Set<String>> listings = const {}}) async {
    final folder = _folder;
    if (folder == null) return;
    final now = _clock();
    DateTime? nextDue;

    for (final config in _locations) {
      final location = config.location;
      final id = location.id;
      if (!await isLocationEnabled(id)) continue;
      try {
        if (!await location.isAvailable()) {
          _locationStatus[id] = LocationStatus(id: id, enabled: true, available: false);
          continue;
        }
        final there = listings[id] ?? (await location.list(folder)).toSet();
        var pending = 0;
        var uploaded = 0;
        for (final e in _hashedNames.entries) {
          if (there.contains(e.value)) continue;
          final due = _notBefore[e.key];
          if (config.delayPayments && due != null && due.isAfter(now)) {
            pending++;
            if (nextDue == null || due.isBefore(nextDue)) nextDue = due;
            continue;
          }
          final bytes = await _local.read(folder, e.key);
          if (bytes == null) continue;
          try {
            await location.create(folder, e.value, bytes);
          } on BackupNameConflict {
            // Different bytes under this file's name: another instance wrote
            // as this device. Never overwritten; the device id check starts a
            // new id once that instance's later files arrive.
            log(
              LogLevel.warn,
              '[Backup] Location $id holds a different file under one of our names.',
            );
            continue;
          }
          there.add(e.value);
          (_awaiting[id] ??= {}).add(e.value);
          uploaded++;
        }

        // After a restart, a file an earlier session handed over may still not
        // be uploaded, so every file there is checked once per session; one
        // confirmed uploaded is not asked about again.
        if (_uploadChecked.add(id)) (_awaiting[id] ??= {}).addAll(there);
        final awaiting = _awaiting[id] ?? {};
        for (final name in awaiting.toList()) {
          final up = await location.isUploaded(folder, name);
          if (up == null || up) awaiting.remove(name);
        }

        final previous = _locationStatus[id];
        _locationStatus[id] = LocationStatus(
          id: id,
          enabled: true,
          available: true,
          fileCount: there.length,
          pendingUploads: pending,
          awaitingConfirmation: awaiting.length,
          bytes: location is FolderLocation ? await location.totalBytes() : previous?.bytes,
          lastUpload: uploaded > 0 ? now : previous?.lastUpload,
          // What this sync's read found stays shown until a read finds none.
          lastError: previous?.lastError,
        );
      } catch (e) {
        _setLocationError(id, e);
      }
    }

    _delayTimer?.cancel();
    if (nextDue != null) {
      _delayTimer = Timer(nextDue.difference(now) + const Duration(seconds: 1), () {
        unawaited(
          _serial(() async {
            await _upload();
            notifyListeners();
          }),
        );
      });
    }
  }

  void _setLocationError(String id, Object e) {
    log(LogLevel.warn, '[Backup] Location $id: $e');
    final previous = _locationStatus[id];
    _locationStatus[id] = LocationStatus(
      id: id,
      enabled: true,
      available: previous?.available,
      fileCount: previous?.fileCount,
      lastUpload: previous?.lastUpload,
      lastError: '$e',
    );
  }

  // ----- Export and import -----

  /// Every file of this wallet's backup as one file, to save anywhere.
  ///
  /// With no location on, the address book is not recorded here
  /// ([_syncContacts]); the file carries it as it is now instead.
  Future<Uint8List> exportBundle() async {
    await sync();
    return _serial(() async {
      final folder = _requireOpen();
      final files = <Uint8List>[];
      for (final plain in _hashedNames.keys) {
        final bytes = await _local.read(folder, plain);
        if (bytes != null) files.add(bytes);
      }
      if (!await _anyLocationEnabled()) files.addAll(await _addressBookSnapshot());
      return BackupBundle.encode(files);
    });
  }

  /// Whether any location is on; the local copy is not one.
  Future<bool> _anyLocationEnabled() async {
    for (final c in _locations) {
      if (await isLocationEnabled(c.location.id)) return true;
    }
    return false;
  }

  /// How the address book differs from the backup's, as change files for
  /// [exportBundle] only: never written to the local copy, so they cannot
  /// reach a location this device later turns on. They carry a device id of
  /// their own, so this device's own sequence has no gap where they would be.
  Future<List<Uint8List>> _addressBookSnapshot() async {
    final local = await _localContacts();
    if (local == null) return const [];
    final state = _state!;
    final deviceId = randomBytes(16);
    // Kept, so the next file's snapshot is the newer one.
    final lamport = max(state.lamport, _merged.maxLamport) + 1;
    state.lamport = lamport;
    await _saveState();
    final records = <BackupRecord>[
      for (final c in local.values)
        if (_merged.contactVersions[c.id] case final v
            when v == null ||
                v.deleted ||
                _fingerprint(v.name, v.addresses) != _fingerprint(c.name, c.addresses))
          ContactRecord(
            id: c.id,
            name: c.name,
            addresses: c.addresses,
            lamport: lamport,
            deviceId: deviceId,
          ),
      for (final v in _merged.contactVersions.values)
        if (!v.deleted && !local.containsKey(v.id))
          ContactRecord.deletion(id: v.id, lamport: lamport, deviceId: deviceId),
    ];
    final files = <Uint8List>[];
    // Room for the body's own fields, generously, as in [_writeChange].
    const fixed = 256;
    var i = 0;
    while (i < records.length) {
      final chunk = <BackupRecord>[];
      var size = 0;
      while (i < records.length) {
        final r = records[i];
        if (chunk.isNotEmpty && fixed + size + r.raw.length > maxBodyLength) break;
        i++;
        if (fixed + r.raw.length > maxBodyLength) continue;
        chunk.add(r);
        size += r.raw.length;
      }
      if (chunk.isEmpty) continue;
      final body = BackupFileBody(
        deviceId: deviceId,
        seq: files.length + 1,
        kind: FileKind.change,
        lamport: lamport,
        created: _clock().millisecondsSinceEpoch ~/ 1000,
        seen: _merged.seenExcept(toHex(deviceId)),
        records: chunk,
      );
      files.add(sealBackupFile(_keys!, body));
    }
    return files;
  }

  /// Adds the files in a file made by [exportBundle] (on any device with the
  /// same seed), then syncs: the address book takes what it lacked, and every
  /// enabled location gets the files.
  ///
  /// Throws [FormatException] if [bundle] is not an export, or none of its
  /// files opens with this wallet's keys (a different seed).
  Future<ImportResult> importBundle(Uint8List bundle) async {
    final files = BackupBundle.decode(bundle);
    final result = await _serial(() async {
      final folder = _requireOpen();
      var added = 0;
      var present = 0;
      var failed = 0;
      for (final bytes in files) {
        final BackupFileBody body;
        try {
          body = openBackupFile(_keys!, bytes);
        } on BackupFileException catch (e) {
          failed++;
          _failed.add(FailedFile('import', '', e.error.name));
          continue;
        }
        final plain = BackupNames.plainNameOf(body);
        if (_merged.containsFile(plain)) {
          present++;
          continue;
        }
        await _local.create(folder, plain, bytes);
        _hashedNames[plain] = BackupNames.hashed(_keys!, plain);
        _merged.add(plain, body);
        added++;
      }
      return ImportResult(added: added, alreadyPresent: present, failed: failed);
    });
    if (result.added == 0 && result.alreadyPresent == 0 && result.failed > 0) {
      throw const FormatException('This backup file belongs to a different wallet.');
    }
    _importToApply = true;
    await sync(reportRestore: true);
    return result;
  }

  String _requireOpen() {
    final folder = _folder;
    if (!_active || folder == null) throw StateError('The backup is off or not open.');
    return folder;
  }

  // ----- Local copy and state -----

  late final FolderLocation _local = FolderLocation('local', _localRoot);

  Future<File> _stateFile() async => File('${(await _stateRoot()).path}/${_folder!}.state');

  Future<_DeviceState?> _loadState() async {
    final f = await _stateFile();
    if (!await f.exists()) return null;
    try {
      return _DeviceState.fromJson(json.decode(await f.readAsString()));
    } catch (_) {
      return null;
    }
  }

  /// Written before every file it numbers, so a crash never reuses a seq.
  Future<void> _saveState() async {
    final f = await _stateFile();
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.${toHex(randomBytes(4))}.tmp');
    final raf = await tmp.open(mode: FileMode.writeOnly);
    try {
      await raf.writeFrom(utf8.encode(json.encode(_state!.toJson())));
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(f.path);
  }

  /// Opens every file in the local copy. A file that fails is reported and
  /// left alone; it is never deleted.
  Future<void> _loadLocalCopy() async {
    final folder = _folder!;
    final keys = _keys!;
    for (final name in await _local.list(folder)) {
      if (!BackupNames.isPlainName(name)) continue;
      final bytes = await _local.read(folder, name);
      if (bytes == null) continue;
      try {
        final body = openBackupFile(keys, bytes);
        final plain = BackupNames.plainNameOf(body);
        _hashedNames[plain] = BackupNames.hashed(keys, plain);
        _merged.add(plain, body);
      } on BackupFileException catch (e) {
        _failed.add(FailedFile('local', name, e.error.name));
      }
    }
  }

  // ----- Plumbing -----

  /// Completes once every queued sync, write and upload has run.
  @visibleForTesting
  Future<void> idle() => _chain;

  @visibleForTesting
  String? get deviceIdHex => _state == null ? null : toHex(_state!.deviceId);

  @visibleForTesting
  String? get folderName => _folder;

  /// Back to off: the keys and wallets stay, everything being on loaded goes.
  void _deactivate() {
    _state = null;
    _merged = BackupState();
    _hashedNames.clear();
    _rejected.clear();
    _failed.clear();
    _notBefore.clear();
    _awaiting.clear();
    _uploadChecked.clear();
    _locationStatus.clear();
    _lastRestore = null;
    _lastSync = null;
    _lastError = null;
  }

  void _resetSession() {
    _keys?.wipe();
    _keys = null;
    _folder = null;
    _state = null;
    _merged = BackupState();
    _wallets = const [];
    _hashedNames.clear();
    _rejected.clear();
    _failed.clear();
    _notBefore.clear();
    _awaiting.clear();
    _uploadChecked.clear();
    _locationStatus.clear();
  }

  void _startTimers() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(sync()));
    if (observeLifecycle && !_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
  }

  void _stopTimers() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _delayTimer?.cancel();
    _delayTimer = null;
    _historyDebounce?.cancel();
    _historyDebounce = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && isOpen) unawaited(sync());
  }

  /// Runs [task] after every task before it, so syncs, writes and uploads
  /// never interleave.
  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _chain.then((_) => task());
    _chain = result.then(
      (_) {},
      onError: (Object e, StackTrace st) {
        log(LogLevel.warn, '[Backup] $e');
      },
    );
    return result;
  }

  @override
  void dispose() {
    _stopTimers();
    _keys?.wipe();
    super.dispose();
  }
}
