import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wallet_backup/wallet_backup.dart';
import 'package:wallet_ui/wallet_ui.dart';

import '../icloud_location.dart';
import '../l10n/backup_localizations.dart';
import '../setup.dart';
import '../sync_folder_location.dart';

/// After a restore from the seed: once the wallet's backup keys are ready,
/// asks whether to import wallet data ([ImportWalletDataScreen]).
///
/// Never for a legacy 25-word Monero seed, or a polyseed with an offset
/// passphrase: those have no backup, so the service derives no keys for them,
/// looks nowhere, and this shows nothing.
///
/// Call it just before leaving the restore screen. It captures the navigator
/// and the toast overlay from [context] then, and shows the screen over
/// whatever is up once the backup has opened. If the backup was already on
/// (its switches came back with the phone), it has read its locations by then,
/// so this only says what it found, unless that was nothing.
void scheduleImportWalletData(
  BuildContext context, {
  Duration timeout = const Duration(seconds: 30),
  @visibleForTesting MetadataBackupService? service,
}) {
  final backup = service ?? MetadataBackupSetup.service;
  if (backup == null) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final toast = BrandToast.of(context);
  final i18n = BackupLocalizations.of(context);

  unawaited(() async {
    final RestoreReport? report;
    try {
      report = await backup.restoreResult().timeout(timeout);
    } on TimeoutException {
      return;
    }
    if (!navigator.mounted) return;
    switch (backup.availability) {
      case BackupAvailability.open:
        break;
      // No backup for this seed: nothing to look for, nothing to ask.
      case BackupAvailability.legacySeed:
      case BackupAvailability.unsupportedPassphrase:
      case BackupAvailability.closed:
      case BackupAvailability.opening:
        return;
    }
    if (backup.enabled && report != null && (report.payments > 0 || report.contactsRestored > 0)) {
      toast.show(i18n.backupRestoreFound(report.payments, report.contactsRestored));
      return;
    }
    await navigator.push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => ImportWalletDataScreen(service: service),
      ),
    );
  }());
}

/// "Import Wallet Data", after a restore from the seed:
///
/// - **From iCloud / Android Backup**: looks there first without writing
///   anything ([MetadataBackupService.findBackups]). Only when a backup is
///   found does it turn the backup on, with the location(s) it was found in.
///   Otherwise a pop-up says so and the user is back on this screen, with
///   nothing turned on.
/// - **From a Sync Folder**: the user picks the folder, which is looked in
///   the same way. Only when a backup is found there does the backup go on,
///   with the sync folder; otherwise the folder is forgotten again.
/// - **From a Backup File**: imports a backup file: its contacts go into the
///   address book, and its payment details into the wallets (for Monero, the
///   wallet file), synced yet or not. Nothing else is kept, and every automatic
///   location stays off; the user turns them on in Settings > Backup.
/// - **Skip**: nothing changes. The backup stays off until turned on in
///   Settings > Backup, and a copy Android restored is neither read nor
///   deleted.
///
/// Desktop has no other automatic location, so it offers the sync folder, the
/// file and Skip.
class ImportWalletDataScreen extends StatefulWidget {
  const ImportWalletDataScreen({super.key, this.service, this.pickFile});

  /// For tests; [MetadataBackupSetup]'s service, app name and file picker
  /// otherwise.
  final MetadataBackupService? service;
  final Future<Uint8List?> Function()? pickFile;

  @override
  State<ImportWalletDataScreen> createState() => _ImportWalletDataScreenState();
}

enum _Step { choose, looking, reading, done }

class _ImportWalletDataScreenState extends State<ImportWalletDataScreen> {
  _Step _step = _Step.choose;
  String? _error;
  bool _fromFile = false;
  bool _nothingNew = false;
  int _payments = 0;
  int _contacts = 0;
  String? _turnedOnAt;

  /// Where [_Step.looking] looks, when not the platform's own locations.
  String? _lookingIn;

  MetadataBackupService get _service => widget.service ?? MetadataBackupSetup.service!;

  SyncFolderLocation? get _syncFolder =>
      _service.locations.map((c) => c.location).whereType<SyncFolderLocation>().firstOrNull;

  Future<void> _fromLocation(String where) async {
    final i18n = BackupLocalizations.of(context);
    setState(() {
      _step = _Step.looking;
      _lookingIn = null;
      _error = null;
    });
    var turnedOn = false;
    try {
      // The sync folder has its own choice: until one is picked, there is
      // nothing to look in.
      final probes = [
        for (final p in await _service.findBackups())
          if (p.id != SyncFolderLocation.locationId) p,
      ];
      final found = [
        for (final p in probes)
          if (p.found) p.id,
      ];
      if (found.isEmpty) {
        if (!mounted) return;
        setState(() => _step = _Step.choose);
        final unreachable = probes.any((p) => !p.available);
        await _notFound(unreachable ? i18n.importUnavailable(where) : i18n.importNotFound(where));
        return;
      }
      turnedOn = !_service.enabled;
      await _service.setEnabled(true, locations: found, reportRestore: true);
      final report = _service.lastRestoreReport;
      if (!mounted) return;
      setState(() {
        _step = _Step.done;
        _fromFile = false;
        _payments = report?.payments ?? 0;
        _contacts = report?.contactsRestored ?? 0;
        _turnedOnAt = _locationNames(i18n, _service, only: found);
      });
    } catch (e) {
      if (turnedOn) await _service.setEnabled(false);
      if (!mounted) return;
      setState(() {
        _step = _Step.choose;
        _error = i18n.backupFailed('$e');
      });
    }
  }

  Future<void> _fromSyncFolder(SyncFolderLocation folder) async {
    final i18n = BackupLocalizations.of(context);
    try {
      if (!await folder.choose()) return;
    } on SyncFolderException catch (e) {
      setState(
        () => _error = e.code == 'read_only'
            ? i18n.backupSyncFolderReadOnly
            : i18n.backupFailed('$e'),
      );
      return;
    }
    final where = folder.folderName ?? i18n.backupSyncFolder;
    if (!mounted) return;
    setState(() {
      _step = _Step.looking;
      _lookingIn = where;
      _error = null;
    });
    var turnedOn = false;
    try {
      final probe = (await _service.findBackups()).firstWhere((p) => p.id == folder.id);
      if (!probe.found) {
        await folder.forget();
        if (!mounted) return;
        setState(() => _step = _Step.choose);
        await _notFound(
          probe.available ? i18n.importNotFound(where) : i18n.importUnavailable(where),
        );
        return;
      }
      turnedOn = !_service.enabled;
      await _service.setEnabled(true, locations: [folder.id], reportRestore: true);
      final report = _service.lastRestoreReport;
      if (!mounted) return;
      setState(() {
        _step = _Step.done;
        _fromFile = false;
        _payments = report?.payments ?? 0;
        _contacts = report?.contactsRestored ?? 0;
        _turnedOnAt = where;
      });
    } catch (e) {
      if (turnedOn) await _service.setEnabled(false);
      await folder.forget();
      if (!mounted) return;
      setState(() {
        _step = _Step.choose;
        _error = i18n.backupFailed('$e');
      });
    }
  }

  Future<void> _fromBackupFile() async {
    final i18n = BackupLocalizations.of(context);
    final Uint8List? bytes;
    try {
      bytes = await (widget.pickFile ?? MetadataBackupSetup.pickFile)();
    } on FormatException {
      setState(() => _error = i18n.backupImportWrongWallet);
      return;
    }
    if (bytes == null || !mounted) return;
    setState(() {
      _step = _Step.reading;
      _error = null;
    });
    // On for the import alone: no location is turned on, so once its contacts
    // are in the address book and its payments in the wallets, nothing of it
    // is kept here.
    final wasOn = _service.enabled;
    try {
      if (!wasOn) await _service.setEnabled(true);
      final result = await _service.importBundle(bytes);
      final report = _service.lastRestoreReport;
      if (!wasOn) {
        await _service.carryImportIntoWallets();
        await _service.setEnabled(false);
      }
      if (!mounted) return;
      setState(() {
        _step = _Step.done;
        _fromFile = true;
        _nothingNew = result.added == 0;
        _payments = report?.payments ?? 0;
        _contacts = report?.contactsRestored ?? 0;
      });
    } catch (e) {
      if (!wasOn) await _service.setEnabled(false);
      if (!mounted) return;
      setState(() {
        _step = _Step.choose;
        _error = e is FormatException ? i18n.backupImportWrongWallet : i18n.backupFailed('$e');
      });
    }
  }

  Future<void> _notFound(String message) {
    final i18n = BackupLocalizations.of(context);
    return showNoticeSheet(
      context: context,
      icon: Icons.cloud_off_outlined,
      title: i18n.importNotFoundTitle,
      body: message,
      closeLabel: i18n.importOk,
    );
  }

  void _close() => Navigator.pop(context);

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, BrandSpacing.sm, 4, 0),
    child: Text(text, style: BrandText.caption.copyWith(color: BrandColors.inkMuted)),
  );

  /// The three ways on, as the create/restore screen lays out its two.
  List<Widget> _choices(BackupLocalizations i18n) {
    final where = _locationNames(i18n, _service);
    final syncFolder = _syncFolder;
    return [
      Text(i18n.importIntro, style: BrandText.bodyMuted),
      const SizedBox(height: BrandSpacing.xl),
      if (where != null) ...[
        OptionCard(
          icon: Icons.cloud_download_outlined,
          title: i18n.importFromLocation(where),
          description: i18n.importFromLocationNote(
            _locationNames(i18n, _service, short: true) ?? where,
          ),
          onTap: () => _fromLocation(where),
        ),
        const SizedBox(height: BrandSpacing.md),
      ],
      if (syncFolder != null) ...[
        OptionCard(
          icon: Icons.folder_open_outlined,
          title: i18n.importFromSyncFolder,
          description: i18n.importFromSyncFolderNote,
          onTap: () => _fromSyncFolder(syncFolder),
        ),
        const SizedBox(height: BrandSpacing.md),
      ],
      OptionCard(
        icon: Icons.description_outlined,
        title: i18n.importFromFile,
        description: i18n.importFromFileNote,
        onTap: _fromBackupFile,
      ),
      const SizedBox(height: BrandSpacing.md),
      OptionCard(
        icon: Icons.arrow_forward,
        title: i18n.importNo,
        description: i18n.importNoNote,
        onTap: _close,
      ),
      if (_error != null) ...[
        const SizedBox(height: BrandSpacing.md),
        Text(_error!, style: BrandText.body.copyWith(color: BrandColors.error)),
      ],
    ];
  }

  List<Widget> _working(String text) => [
    const SizedBox(height: BrandSpacing.xl),
    const Center(child: CircularProgressIndicator()),
    const SizedBox(height: BrandSpacing.lg),
    Text(text, style: BrandText.body, textAlign: TextAlign.center),
  ];

  List<Widget> _done(BackupLocalizations i18n) => [
    BrandCard(
      padding: const EdgeInsets.all(BrandSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(i18n.importDoneTitle, style: BrandText.listTitle),
          const SizedBox(height: BrandSpacing.xs),
          Text(
            _fromFile && _nothingNew
                ? i18n.backupImportNothingNew
                : i18n.backupRestoreFound(_payments, _contacts),
            style: BrandText.body,
          ),
        ],
      ),
    ),
    _note(i18n.importScanNote),
    _note(
      _fromFile || _turnedOnAt == null
          ? i18n.importFileBackupNote
          : i18n.importLocationOn(_turnedOnAt!),
    ),
    const SizedBox(height: BrandSpacing.xl),
    BrandButton(label: i18n.importDone, onPressed: _close),
  ];

  @override
  Widget build(BuildContext context) {
    final i18n = BackupLocalizations.of(context);
    final busy = _step == _Step.looking || _step == _Step.reading;
    final content = switch (_step) {
      _Step.choose => _choices(i18n),
      _Step.looking => _working(
        i18n.importLooking(_lookingIn ?? _locationNames(i18n, _service) ?? ''),
      ),
      _Step.reading => _working(i18n.importReading),
      _Step.done => _done(i18n),
    };
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        backgroundColor: BrandColors.paper,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: BrandScreenHeader(onBack: busy ? () {} : _close),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(i18n.importTitle, style: BrandText.title),
                          const SizedBox(height: BrandSpacing.sm),
                          ...content,
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The automatic locations by name ("iCloud", "Android Backup", or with
/// [short] "iCloud", "Android"), all of this platform's or those in [only];
/// null where there is none (desktop).
String? _locationNames(
  BackupLocalizations i18n,
  MetadataBackupService service, {
  Iterable<String>? only,
  bool short = false,
}) {
  final names = [
    for (final c in service.locations)
      if (only == null || only.contains(c.location.id))
        if (c.location.id == ICloudLocation.locationId)
          i18n.backupICloud
        else if (c.location.id == MetadataBackupSetup.autoBackupLocationId)
          short ? i18n.backupAndroidShort : i18n.backupAndroid,
  ];
  return names.isEmpty ? null : names.join(', ');
}
