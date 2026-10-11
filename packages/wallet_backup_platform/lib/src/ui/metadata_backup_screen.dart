import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:wallet_backup/wallet_backup.dart';
import 'package:wallet_ui/wallet_ui.dart';

import '../icloud_location.dart';
import '../l10n/backup_localizations.dart';
import '../setup.dart';

/// Settings > Backup: where the metadata backup is saved, its state, and the
/// backup file.
///
/// iCloud (iOS) and Android backup are switches, both on by default. The
/// light-wallet server location is listed as coming soon. A backup file can be
/// saved for anywhere else and imported back.
class MetadataBackupScreen extends StatefulWidget {
  const MetadataBackupScreen({super.key});

  @override
  State<MetadataBackupScreen> createState() => _MetadataBackupScreenState();
}

class _MetadataBackupScreenState extends State<MetadataBackupScreen> {
  final Map<String, bool> _enabled = {};
  bool _busy = false;

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
    for (final c in service.locations) {
      _enabled[c.location.id] = await service.isLocationEnabled(c.location.id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggle(String id, bool value) async {
    setState(() => _enabled[id] = value);
    await _service?.setLocationEnabled(id, value);
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
    final saved = await MetadataBackupSetup.exportFile(
      sharePositionOrigin: shareAnchorRect(context),
    );
    if (saved && mounted) showBrandToast(context, i18n.backupExported);
  });

  Future<void> _import() => _run((i18n) async {
    final result = await MetadataBackupSetup.importFile();
    if (result == null || !mounted) return;
    showBrandToast(
      context,
      result.added == 0 ? i18n.backupImportNothingNew : i18n.backupImported(result.added),
    );
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

  String _locationStatus(BackupLocalizations i18n, String id) {
    final service = _service!;
    if (!(_enabled[id] ?? false)) return i18n.backupStatusOff;
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

    final appName = MetadataBackupSetup.config.appName;
    final lastSync = service.lastSync;
    final report = service.lastRestoreReport;
    final unrecorded = service.unrecordedOutgoingCount;
    final hasICloud = service.locations.any((c) => c.location.id == ICloudLocation.locationId);
    final autoId = MetadataBackupSetup.autoBackupLocationId;
    final hasAuto = service.locations.any((c) => c.location.id == autoId);
    final autoBytes = hasAuto ? service.statusOf(autoId).bytes ?? 0 : 0;

    return [
      BrandCard(
        padding: const EdgeInsets.all(BrandSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(i18n.backupIntro, style: BrandText.body),
            const SizedBox(height: BrandSpacing.md),
            Text(
              i18n.backupSummary(service.paymentCount, service.contactCount),
              style: BrandText.listTitle,
            ),
            if (lastSync != null)
              Text(
                i18n.backupLastChecked(
                  MaterialLocalizations.of(
                    context,
                  ).formatTimeOfDay(TimeOfDay.fromDateTime(lastSync)),
                ),
                style: BrandText.caption.copyWith(color: BrandColors.inkMuted),
              ),
          ],
        ),
      ),
      if (unrecorded > 0) _note(i18n.backupUnrecorded(unrecorded)),
      const SizedBox(height: 18),
      SettingsGroup(
        label: i18n.backupWhereSaved,
        tiles: [
          if (hasICloud)
            SettingsToggleTile(
              title: i18n.backupICloud,
              description:
                  '${i18n.backupICloudDescription}\n'
                  '${_locationStatus(i18n, ICloudLocation.locationId)}',
              value: _enabled[ICloudLocation.locationId] ?? false,
              onChanged: (v) => _toggle(ICloudLocation.locationId, v),
            ),
          if (hasAuto)
            SettingsToggleTile(
              title: i18n.backupAndroid,
              description:
                  '${i18n.backupAndroidDescription(appName)}\n${_locationStatus(i18n, autoId)}',
              value: _enabled[autoId] ?? false,
              onChanged: (v) => _toggle(autoId, v),
            ),
          SettingsNavTile(title: i18n.backupLws, value: i18n.backupComingSoon, onTap: () {}),
        ],
      ),
      if (autoBytes > MetadataBackupSetup.autoBackupWarnBytes) _note(i18n.backupAndroidLarge),
      if (hasICloud || hasAuto) _note(i18n.backupTorNote),
      const SizedBox(height: 18),
      SettingsGroup(
        label: i18n.backupFileSection,
        tiles: [
          SettingsLinkTile(
            title: i18n.backupExport,
            subtitle: i18n.backupExportSubtitle,
            onTap: _busy ? () {} : _export,
          ),
          SettingsLinkTile(
            title: i18n.backupImport,
            subtitle: i18n.backupImportSubtitle,
            onTap: _busy ? () {} : _import,
          ),
        ],
      ),
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
      if (hasICloud && Platform.isIOS) ...[
        const SizedBox(height: 18),
        SettingsGroup(
          tiles: [
            SettingsLinkTile(
              title: i18n.backupDeleteICloud,
              titleColor: BrandColors.error,
              onTap: _busy ? () {} : _deleteICloud,
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

/// After a restore from the seed: says what the backup brought back, or, when
/// nothing was found, offers to import a backup file.
///
/// Call it just before leaving the restore screen. It captures the navigator
/// and the toast overlay from [context] then, and waits up to [timeout] for the
/// restore's first sync (iCloud may have to download files first) before
/// showing anything over whatever screen is up by then.
void scheduleBackupRestorePrompt(
  BuildContext context, {
  Duration timeout = const Duration(seconds: 30),
}) {
  final service = MetadataBackupSetup.service;
  if (service == null) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final toast = BrandToast.of(context);
  final i18n = BackupLocalizations.of(context);

  unawaited(() async {
    final RestoreReport? report;
    try {
      report = await service.restoreResult().timeout(timeout);
    } on TimeoutException {
      return;
    }
    if (!navigator.mounted || !service.isOpen) return;

    if (report != null && (report.payments > 0 || report.contactsRestored > 0)) {
      toast.show(i18n.backupRestoreFound(report.payments, report.contactsRestored));
      return;
    }

    final import = await showConfirmSheet(
      context: navigator.context,
      icon: Icons.file_open_outlined,
      iconBg: BrandColors.surfaceTinted,
      iconColor: BrandColors.primaryDeep,
      title: i18n.backupNoneFoundTitle,
      body: i18n.backupNoneFoundBody,
      confirmLabel: i18n.backupImport,
      cancelLabel: i18n.backupSkip,
    );
    if (!import) return;
    try {
      final result = await MetadataBackupSetup.importFile();
      if (result == null) return;
      toast.show(
        result.added == 0 ? i18n.backupImportNothingNew : i18n.backupImported(result.added),
      );
    } on FormatException {
      toast.show(i18n.backupImportWrongWallet);
    } catch (e) {
      toast.show(i18n.backupFailed('$e'));
    }
  }());
}
