import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:wallet_backup/wallet_backup.dart';
import 'package:wallet_ui/wallet_ui.dart';

import '../icloud_location.dart';
import '../l10n/backup_localizations.dart';
import '../setup.dart';

/// Settings > Backup: the automatic places a backup can go, each a toggle
/// (iCloud on iOS, Android backup on Android, and the light-wallet server,
/// coming soon), and below them the manual backup file, which works at any
/// time and alongside them.
///
/// Opt-in, with no switch of its own: with every toggle off and no file ever
/// saved or imported, nothing is kept. Turning a place on, saving a file or
/// importing one starts the copy on this device (from which files are saved,
/// and where imported details live). Turning places off keeps that copy;
/// "Delete the copy on this device" removes it and stops everything.
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

  @override
  void initState() {
    super.initState();
    _loadSettings();
    final service = _service;
    if (service != null && service.isOpen) unawaited(service.sync());
  }

  Future<void> _loadSettings() async {
    final service = _service;
    if (service == null) return;
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
  /// this device; turning places off leaves that copy.
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
      }
      await _loadSettings();
    });
  }

  /// Runs [task] with the copy on this device started, as saving or importing
  /// a file needs. If it was not running and [task] does not complete (or
  /// returns false: cancelled, nothing saved), it is stopped again, so a
  /// cancelled save leaves nothing behind.
  Future<void> _withLocalCopy(Future<bool> Function() task) async {
    final service = _service!;
    final started = !service.enabled;
    var kept = false;
    try {
      if (started) await service.setEnabled(true);
      kept = await task();
    } finally {
      if (started && !kept) await service.setEnabled(false);
      await _loadSettings();
    }
  }

  /// Deletes the copy on this device, which also turns every place off.
  Future<void> _deleteLocal() async {
    final service = _service;
    if (service == null || _busy) return;
    final i18n = BackupLocalizations.of(context);
    final ok = await showConfirmSheet(
      context: context,
      icon: Icons.delete_outline,
      iconBg: BrandColors.errorBg,
      iconColor: BrandColors.error,
      title: i18n.backupDeleteLocalTitle,
      body: i18n.backupDeleteLocalBody,
      confirmLabel: i18n.backupDeleteConfirm,
      cancelLabel: i18n.backupCancel,
    );
    if (!ok || !mounted) return;
    await _run((i18n) async {
      await service.setEnabled(false);
      await _loadSettings();
      if (mounted) showBrandToast(context, i18n.backupDeletedLocal);
    });
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
    // Imported details live only in the copy on this device, so it stays.
    await _withLocalCopy(() async {
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
  Widget _deleteLink(String label, VoidCallback onPressed) => TextButton(
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(0, 36),
      alignment: Alignment.centerLeft,
      foregroundColor: BrandColors.error,
    ),
    onPressed: _busy ? null : onPressed,
    child: Text(label),
  );

  /// The status of a place that is on.
  String _locationStatus(BackupLocalizations i18n, String id) {
    final service = _service!;
    final s = service.statusOf(id);
    if (s.available == false) return i18n.backupStatusUnavailable;
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
      if (_on) ...[
        const SizedBox(height: 18),
        SettingsGroup(
          tiles: [
            SettingsLinkTile(
              title: i18n.backupDeleteLocal,
              titleColor: BrandColors.error,
              onTap: _busy ? () {} : _deleteLocal,
            ),
          ],
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
