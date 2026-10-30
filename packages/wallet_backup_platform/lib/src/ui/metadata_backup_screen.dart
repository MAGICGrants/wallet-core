import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wallet_backup/wallet_backup.dart';
import 'package:wallet_ui/wallet_ui.dart';

import '../icloud_location.dart';
import '../l10n/backup_localizations.dart';
import '../setup.dart';
import '../sync_folder_location.dart';

/// Settings > Backup: the automatic places a backup can go, each a toggle
/// (iCloud on iOS, Android backup on Android, a sync folder everywhere, and
/// the light-wallet server, coming soon), and below them the manual backup
/// file, which works at any time and alongside them.
///
/// The sync folder is chosen when it is turned on (a cancelled pick leaves it
/// off), can be changed while on, and is forgotten when turned off; its files
/// stay in the folder.
///
/// Opt-in, with no switch of its own. The copy on this device is kept only
/// while a place is on, since that copy is what syncs: turning the last one off
/// deletes it (never the places' own copies, the wallets or the address book).
/// With none on, saving a file builds the backup from the wallets and the
/// address book and keeps nothing afterwards; importing one applies it to the
/// address book and to the wallets (for Monero, the wallet file keeps its
/// payment details), and keeps nothing either.
class MetadataBackupScreen extends StatefulWidget {
  const MetadataBackupScreen({super.key, this.exportFile, this.pickFile});

  /// Saves a backup file (share sheet or save dialog); true when saved. For
  /// tests: the default is [MetadataBackupSetup.exportFile].
  final Future<bool> Function()? exportFile;

  /// Picks a backup file; null when cancelled. For tests: the default is
  /// [MetadataBackupSetup.pickFile].
  final Future<Uint8List?> Function()? pickFile;

  @override
  State<MetadataBackupScreen> createState() => _MetadataBackupScreenState();
}

class _MetadataBackupScreenState extends State<MetadataBackupScreen> {
  final Map<String, bool> _enabled = {};
  bool _on = false;
  bool _busy = false;

  /// This wallet's files in Android backup while it is off, left by turning
  /// it off or put back by Android with the app's files: kept until deleted
  /// here, and read by turning it on.
  bool _autoLeftover = false;

  MetadataBackupService? get _service => MetadataBackupSetup.service;

  /// Whether the user can pick a folder on a network drive (NAS) here: a
  /// desktop OS mounts one like any other folder.
  ///
  /// ", or pick a location on a network drive (NAS)." should be included in
  /// the sync folder's description (backupSyncFolderDescriptionNas) for any OS
  /// for which the user can pick a NAS location.
  static bool get _canPickNas => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  SyncFolderLocation? get _syncFolder =>
      _service?.locations.map((c) => c.location).whereType<SyncFolderLocation>().firstOrNull;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final service = _service;
    // A copy kept with no place on, as earlier versions did after saving or
    // importing a file: what it imported goes into the wallets, then it goes.
    if (service != null &&
        service.isOpen &&
        await service.isEnabled() &&
        !await _anyLocationOn(service)) {
      await service.carryImportIntoWallets();
      await service.setEnabled(false);
    }
    await _loadSettings();
    if (service != null && service.isOpen) unawaited(service.sync());
  }

  Future<void> _loadSettings() async {
    final service = _service;
    if (service == null) return;
    await _syncFolder?.load();
    _on = await service.isEnabled();
    for (final c in service.locations) {
      _enabled[c.location.id] = await service.isLocationEnabled(c.location.id);
    }
    final autoId = MetadataBackupSetup.autoBackupLocationId;
    _autoLeftover =
        service.locations.any((c) => c.location.id == autoId) &&
        !(_enabled[autoId] ?? false) &&
        await service.filesIn(autoId) > 0;
    if (mounted) setState(() {});
  }

  /// An automatic place on or off. The first one turned on starts the copy on
  /// this device; turning the last one off deletes it.
  Future<void> _setLocation(String id, bool value) async {
    final service = _service;
    if (service == null) return;
    await _run((_) async {
      setState(() => _enabled[id] = value);
      // The service's own state, not this screen's last read of it.
      if (value && !service.enabled) {
        await service.setEnabled(true, locations: [id]);
      } else {
        await service.setLocationEnabled(id, value);
        if (!value && !await _anyLocationOn(service)) await service.setEnabled(false);
      }
      await _loadSettings();
    });
  }

  /// The sync folder on: the user picks the folder first, and nothing changes
  /// if they cancel. Off: nothing more is written there, and the folder is
  /// forgotten (its access given up); its files stay.
  Future<void> _setSyncFolder(SyncFolderLocation folder, bool value) async {
    if (!value) {
      await _setLocation(folder.id, false);
      await folder.forget();
      if (mounted) setState(() {});
      return;
    }
    if (await _chooseFolder(folder)) await _setLocation(folder.id, true);
  }

  /// Another folder, while the sync folder is on: read in full, and given
  /// every file it lacks. The old folder keeps its files.
  Future<void> _changeFolder(SyncFolderLocation folder) async {
    if (!await _chooseFolder(folder)) return;
    await _service?.locationChanged(folder.id);
    if (mounted) setState(() {});
  }

  /// The platform's folder picker. True when a folder was chosen.
  Future<bool> _chooseFolder(SyncFolderLocation folder) async {
    if (_busy) return false;
    final i18n = BackupLocalizations.of(context);
    setState(() => _busy = true);
    try {
      return await folder.choose();
    } on SyncFolderException catch (e) {
      if (mounted) {
        showBrandToast(
          context,
          e.code == 'read_only' ? i18n.backupSyncFolderReadOnly : i18n.backupFailed('$e'),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<bool> _anyLocationOn(MetadataBackupService service) async {
    for (final c in service.locations) {
      if (await service.isLocationEnabled(c.location.id)) return true;
    }
    return false;
  }

  /// Runs [task] with the copy on this device started, as saving or importing
  /// a file needs. With no place on, the copy is deleted again afterwards,
  /// whatever [task] did: the saved file is the only thing left. An import
  /// ([imported]) first carries what it brought into the wallets.
  Future<void> _withLocalCopy(Future<bool> Function() task, {bool imported = false}) async {
    final service = _service!;
    try {
      if (!service.enabled) await service.setEnabled(true);
      await task();
    } finally {
      if (!await _anyLocationOn(service)) {
        if (imported) await service.carryImportIntoWallets();
        await service.setEnabled(false);
      }
      await _loadSettings();
    }
  }

  Future<void> _run(Future<void> Function(BackupLocalizations i18n) task) async {
    if (_busy) return;
    final i18n = BackupLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await task(i18n);
    } on FormatException {
      if (mounted) showBrandToast(context, i18n.backupImportWrongWallet);
    } catch (e) {
      if (mounted) showBrandToast(context, i18n.backupFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() => _run((i18n) async {
    final origin = shareAnchorRect(context);
    await _withLocalCopy(() async {
      final saved =
          await (widget.exportFile ??
              () => MetadataBackupSetup.exportFile(sharePositionOrigin: origin))();
      if (saved && mounted) showBrandToast(context, i18n.backupExported);
      return saved;
    });
  });

  Future<void> _import() => _run((i18n) async {
    final bytes = await (widget.pickFile ?? MetadataBackupSetup.pickFile)();
    if (bytes == null) return;
    await _withLocalCopy(imported: true, () async {
      final result = await _service!.importBundle(bytes);
      if (mounted) {
        showBrandToast(
          context,
          result.added == 0 ? i18n.backupImportNothingNew : i18n.backupImported(result.added),
        );
      }
      return true;
    });
  });

  Future<void> _deleteICloud() async {
    final i18n = BackupLocalizations.of(context);
    final ok = await showConfirmSheet(
      context: context,
      icon: Icons.cloud_off_outlined,
      iconBg: BrandColors.errorBg,
      iconColor: BrandColors.error,
      title: i18n.backupDeleteICloud,
      body: i18n.backupDeleteICloudBody,
      confirmLabel: i18n.backupDeleteConfirm,
      cancelLabel: i18n.backupCancel,
    );
    if (!ok || !mounted) return;
    await _run((i18n) async {
      await _service?.deleteFromLocation(ICloudLocation.locationId);
      if (mounted) showBrandToast(context, i18n.backupDeleted);
    });
  }

  Future<void> _deleteAndroid() async {
    final i18n = BackupLocalizations.of(context);
    final ok = await showConfirmSheet(
      context: context,
      icon: Icons.delete_outline,
      iconBg: BrandColors.errorBg,
      iconColor: BrandColors.error,
      title: i18n.backupDeleteAndroid,
      body: i18n.backupDeleteAndroidBody,
      confirmLabel: i18n.backupDeleteConfirm,
      cancelLabel: i18n.backupCancel,
    );
    if (!ok || !mounted) return;
    await _run((i18n) async {
      await _service?.deleteFromLocation(MetadataBackupSetup.autoBackupLocationId);
      await _loadSettings();
      if (mounted) showBrandToast(context, i18n.backupDeletedAndroid);
    });
  }

  /// A red link inside a place's card, for deleting its copy.
  Widget _deleteLink(String label, VoidCallback onPressed) =>
      _link(label, onPressed, color: BrandColors.error);

  /// A link inside a place's card.
  Widget _link(String label, VoidCallback onPressed, {Color? color}) => TextButton(
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(0, 36),
      alignment: Alignment.centerLeft,
      foregroundColor: color ?? BrandColors.primaryDeep,
    ),
    onPressed: _busy ? null : onPressed,
    child: Text(label),
  );

  /// The status of a place that is on.
  String _locationStatus(BackupLocalizations i18n, String id) {
    final service = _service!;
    final s = service.statusOf(id);
    if (s.available == false) {
      return id == SyncFolderLocation.locationId
          ? i18n.backupSyncFolderUnavailable
          : i18n.backupStatusUnavailable;
    }
    if (s.lastError != null) return i18n.backupStatusError;
    if (s.pendingUploads > 0) return i18n.backupStatusPending(s.pendingUploads);
    if (s.awaitingConfirmation > 0) return i18n.backupStatusAwaiting;
    return i18n.backupStatusUpToDate;
  }

  Widget _note(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, BrandSpacing.sm, 4, 0),
    child: Text(text, style: BrandText.caption.copyWith(color: BrandColors.inkMuted)),
  );

  Widget _card(String text, {Color? color}) => BrandCard(
    color: color,
    borderColor: color,
    padding: const EdgeInsets.all(BrandSpacing.lg),
    child: Text(text, style: BrandText.body),
  );

  List<Widget> _content(BackupLocalizations i18n) {
    final service = _service;
    if (service == null) return [_card(i18n.backupLocked)];
    switch (service.availability) {
      case BackupAvailability.legacySeed:
        return [_card(i18n.backupLegacySeed, color: BrandColors.warningBg)];
      case BackupAvailability.unsupportedPassphrase:
        return [_card(i18n.backupUnsupportedPassphrase, color: BrandColors.warningBg)];
      case BackupAvailability.closed:
        return [_card(i18n.backupLocked)];
      case BackupAvailability.opening:
        return [_card(i18n.backupOpening)];
      case BackupAvailability.open:
        break;
    }

    final lastSync = service.lastSync;
    final report = service.lastRestoreReport;
    final unrecorded = service.unrecordedOutgoingCount;
    final hasICloud = service.locations.any((c) => c.location.id == ICloudLocation.locationId);
    final iCloudOn = _enabled[ICloudLocation.locationId] ?? false;
    // A copy made while it was on stays in iCloud until deleted. Not offered
    // while it is on: the next sync would put everything back.
    final canDeleteICloud = Platform.isIOS && hasICloud && !iCloudOn;
    final autoId = MetadataBackupSetup.autoBackupLocationId;
    final hasAuto = service.locations.any((c) => c.location.id == autoId);
    final autoBytes = hasAuto ? service.statusOf(autoId).bytes ?? 0 : 0;
    final syncFolder = _syncFolder;
    final syncOn = syncFolder != null && (_enabled[syncFolder.id] ?? false);

    Widget status(String id) =>
        Text(_locationStatus(i18n, id), style: BrandText.caption.copyWith(color: BrandColors.ink));

    return [
      Text(i18n.backupEnable, style: BrandText.title),
      const SizedBox(height: BrandSpacing.lg),
      // It does not replace the recovery phrase.
      BrandCard(
        color: BrandColors.warningBg,
        borderColor: BrandColors.warningBg,
        padding: const EdgeInsets.all(BrandSpacing.lg),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: i18n.backupSeedWarningBold,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              TextSpan(text: ' ${i18n.backupSeedWarning}'),
            ],
          ),
          style: BrandText.body,
        ),
      ),
      if (_on) ...[
        const SizedBox(height: BrandSpacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                i18n.backupSummary(service.paymentCount, service.contactCount),
                style: BrandText.listTitle,
              ),
              if (lastSync != null)
                Text(
                  i18n.backupLastChecked(
                    MaterialLocalizations.of(context)
                        .formatTimeOfDay(TimeOfDay.fromDateTime(lastSync)),
                  ),
                  style: BrandText.caption.copyWith(color: BrandColors.inkMuted),
                ),
            ],
          ),
        ),
        if (unrecorded > 0) _note(i18n.backupUnrecorded(unrecorded)),
      ],
      const SizedBox(height: 18),
      SectionHeader(label: i18n.backupAutomaticSection),
      const SizedBox(height: BrandSpacing.md),
      if (hasICloud) ...[
        OptionCard(
          icon: Icons.cloud_outlined,
          title: i18n.backupICloud,
          description: i18n.backupICloudDescription,
          trailing: BrandSwitch(
            value: iCloudOn,
            onChanged: (v) => _setLocation(ICloudLocation.locationId, v),
          ),
          child: iCloudOn || canDeleteICloud
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (iCloudOn) status(ICloudLocation.locationId),
                    if (canDeleteICloud) _deleteLink(i18n.backupDeleteICloud, _deleteICloud),
                  ],
                )
              : null,
        ),
        const SizedBox(height: BrandSpacing.md),
      ],
      if (hasAuto) ...[
        OptionCard(
          icon: Icons.backup_outlined,
          title: i18n.backupAndroid,
          description: i18n.backupAndroidDescription,
          trailing: BrandSwitch(
            value: _enabled[autoId] ?? false,
            onChanged: (v) => _setLocation(autoId, v),
          ),
          child: (_enabled[autoId] ?? false)
              ? status(autoId)
              // Files in Android backup while it is off: they stay, and
              // Android keeps carrying them, until deleted here.
              : _autoLeftover
              ? _deleteLink(i18n.backupDeleteAndroid, _deleteAndroid)
              : null,
        ),
        const SizedBox(height: BrandSpacing.md),
      ],
      if (syncFolder != null) ...[
        OptionCard(
          icon: Icons.folder_outlined,
          title: i18n.backupSyncFolder,
          description: _canPickNas
              ? i18n.backupSyncFolderDescriptionNas
              : i18n.backupSyncFolderDescription,
          trailing: BrandSwitch(value: syncOn, onChanged: (v) => _setSyncFolder(syncFolder, v)),
          child: syncOn
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.folder_outlined, size: 14, color: BrandColors.inkMuted),
                        const SizedBox(width: BrandSpacing.xs),
                        Expanded(
                          child: Text(
                            syncFolder.folderName ?? '',
                            style: BrandText.caption.copyWith(color: BrandColors.ink),
                          ),
                        ),
                      ],
                    ),
                    status(syncFolder.id),
                    _link(i18n.backupSyncFolderChange, () => _changeFolder(syncFolder)),
                  ],
                )
              : null,
        ),
        const SizedBox(height: BrandSpacing.md),
      ],
      OptionCard(
        icon: Icons.dns_outlined,
        title: i18n.backupLws,
        description: i18n.backupComingSoon,
        enabled: false,
      ),
      if (autoBytes > MetadataBackupSetup.autoBackupWarnBytes) _note(i18n.backupAndroidLarge),
      const SizedBox(height: 18),
      SectionHeader(label: i18n.backupManualSection),
      const SizedBox(height: BrandSpacing.md),
      OptionCard(
        icon: Icons.description_outlined,
        title: i18n.backupFileSection,
        description: i18n.backupFileDescription,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BrandButton(label: i18n.backupExport, onPressed: _busy ? null : _export),
            const SizedBox(height: BrandSpacing.sm),
            // Not disabled while busy: [_run] ignores the tap then.
            BrandButton.ghost(
              label: i18n.backupImport,
              color: BrandColors.primary,
              onPressed: _import,
            ),
          ],
        ),
      ),
      _note(i18n.backupSecurityNote),
      if (report != null) ...[
        const SizedBox(height: 18),
        BrandCard(
          padding: const EdgeInsets.all(BrandSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(i18n.backupRestoreTitle, style: BrandText.listTitle),
              const SizedBox(height: BrandSpacing.xs),
              Text(
                i18n.backupRestoreSummary(report.payments, report.contactsRestored),
                style: BrandText.body,
              ),
              if (report.failed.isNotEmpty)
                Text(i18n.backupRestoreUnreadable(report.failed.length), style: BrandText.body),
              if (report.gaps.isNotEmpty || report.missingTails.isNotEmpty)
                Text(i18n.backupRestoreGaps, style: BrandText.body),
              if (report.conflictingPayments.isNotEmpty)
                Text(
                  i18n.backupRestoreConflicts(report.conflictingPayments.length),
                  style: BrandText.body,
                ),
            ],
          ),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final i18n = BackupLocalizations.of(context);
    final service = _service;
    return Scaffold(
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
                  child: BrandScreenHeader(
                    onBack: () => Navigator.pop(context),
                    center: Text(i18n.backupTitle, style: BrandText.appBar.copyWith(fontSize: 16)),
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: service ?? ChangeNotifier(),
                    builder: (context, _) => SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _content(i18n),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
