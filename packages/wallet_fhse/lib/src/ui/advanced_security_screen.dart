import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart' show SharedPreferencesService;
import 'package:wallet_ui/wallet_ui.dart';

import '../fhse_vault.dart' show FhseVault;
import '../l10n/fhse_localizations.dart';
import 'app_lock.dart' show confirmOwnerToLockLater;
import 'hmac_parity_screen.dart';
import 'platform_copy.dart';
import 'security_key_flow.dart';
import 'security_key_setup_screen.dart';
import 'security_keys_app.dart';

/// "Fully lock after" for [minutes], e.g. "30 minutes" or "24 hours".
String fullLockLabel(FhseLocalizations i18n, int minutes) =>
    minutes % 60 == 0 ? i18n.securityKeysHours(minutes ~/ 60) : i18n.securityKeysMinutes(minutes);

/// The setting's name and explanation. Mobile counts the time in the
/// background ("Fully lock after"); a desktop OS counts the time without use
/// ("Lock after"), which covers a window left open as well as one left behind.
({String label, String description}) fullLockCopy(FhseLocalizations i18n) {
  final appName = SecurityKeysUi.config.appName;
  return isDesktopAutoLockPlatform
      ? (label: i18n.desktopAutoLockLabel, description: i18n.desktopAutoLockDescription(appName))
      : (
          label: i18n.securityKeysFullLockLabel,
          description: i18n.securityKeysFullLockDescription(appName),
        );
}

/// Shows the [SecurityKeysPreferences.fullLockMinuteOptions], saves the one
/// picked and returns it; null when dismissed. A longer time is saved only
/// once [confirmLater], when given, passes ([confirmOwnerToLockLater]).
Future<int?> pickFullLockMinutes(
  BuildContext context, {
  required String title,
  required String description,
  Future<bool> Function(BuildContext context)? confirmLater,
}) async {
  final current = await SecurityKeysPreferences.fullLockMinutes();
  if (!context.mounted) return null;
  final i18n = FhseLocalizations.of(context);
  final picked = await showBrandSheet<int>(
    context: context,
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Text(title, style: BrandText.sheetTitle),
            const SizedBox(height: BrandSpacing.xs),
            Text(description, style: BrandText.bodyMuted),
            const SizedBox(height: BrandSpacing.lg),
            SettingsGroup(
              tiles: [
                for (final minutes in SecurityKeysPreferences.fullLockMinuteOptions)
                  InkWell(
                    onTap: () => Navigator.pop(sheetContext, minutes),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(fullLockLabel(i18n, minutes), style: BrandText.listTitle),
                          ),
                          RadioDot(selected: minutes == current),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  if (picked == null) return null;
  if (picked > current && confirmLater != null) {
    if (!context.mounted || !await confirmLater(context)) return null;
  }
  await SharedPreferencesService.set<int>(SecurityKeysPreferences.fullLockAfterMinutes, picked);
  return picked;
}

/// Settings > "Lock after" on a desktop OS, where it applies whether or not
/// security keys are on (see [DesktopAutoLock]). Not behind Advanced
/// security's check, so a longer time asks the owner first.
class DesktopAutoLockTile extends StatefulWidget {
  const DesktopAutoLockTile({super.key});

  @override
  State<DesktopAutoLockTile> createState() => _DesktopAutoLockTileState();
}

class _DesktopAutoLockTileState extends State<DesktopAutoLockTile> {
  int? _minutes;

  @override
  void initState() {
    super.initState();
    SecurityKeysPreferences.fullLockMinutes().then((m) {
      if (mounted) setState(() => _minutes = m);
    });
  }

  Future<void> _pick() async {
    final copy = fullLockCopy(FhseLocalizations.of(context));
    final picked = await pickFullLockMinutes(
      context,
      title: copy.label,
      description: copy.description,
      confirmLater: confirmOwnerToLockLater,
    );
    if (picked != null && mounted) setState(() => _minutes = picked);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = FhseLocalizations.of(context);
    final minutes = _minutes;
    return SettingsNavTile(
      title: i18n.desktopAutoLockLabel,
      value: minutes == null ? '' : fullLockLabel(i18n, minutes),
      onTap: _pick,
    );
  }
}

/// Settings > Advanced Security: YubiKeys guarding the wallet password.
///
/// Off by default: onboarding derives the wallet password from the seed (FHSE's
/// root) and keeps it in the keystore as before. Setting keys up takes it out
/// of the keystore; from then on a key and its PIN open the wallet, after App
/// Lock.
class AdvancedSecurityScreen extends StatefulWidget {
  const AdvancedSecurityScreen({super.key});

  @override
  State<AdvancedSecurityScreen> createState() => _AdvancedSecurityScreenState();
}

class _AdvancedSecurityScreenState extends State<AdvancedSecurityScreen> {
  SecurityKeysState? _state;
  bool _loadFailed = false;
  int _fullLockMinutes = SecurityKeysPreferences.fullLockDefaultMinutes;
  bool _turningOff = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final state = await securityKeysState();
      final minutes =
          await SharedPreferencesService.get<int>(SecurityKeysPreferences.fullLockAfterMinutes) ??
          SecurityKeysPreferences.fullLockDefaultMinutes;
      if (!mounted) return;
      setState(() {
        _state = state;
        _loadFailed = false;
        _fullLockMinutes = minutes;
      });
    } catch (_) {
      // A failure says so, with a way to try again, rather than spinning.
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _retry() async {
    setState(() => _loadFailed = false);
    await _load();
  }

  Future<void> _setUp({bool again = false}) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => SecurityKeySetupScreen(again: again)),
    );
    await _load();
  }

  Future<void> _addKey() async {
    // After an unlock with the recovery phrase there is no unlocked FHSE file
    // to add to; the keys are set up again instead.
    if (!FhseVault.hasSession) return _setUp(again: true);
    final count = _state?.keys.length ?? 0;
    await showAddSecurityKeySheet(
      context,
      number: count + 1,
      enroll: (verification, key, name) =>
          addSecurityKey(key: key, verification: verification, name: name),
      rename: renameSecurityKey,
      registeredKeys: registeredSecurityKeys,
    );
    // Reload even when the sheet reports nothing added: the key is added
    // before the name step, so a sheet dismissed there still added it.
    if (mounted) await _load();
  }

  Future<void> _removeKey() async {
    final i18n = FhseLocalizations.of(context);
    final ok = await showConfirmSheet(
      context: context,
      icon: Icons.key_off_outlined,
      iconBg: BrandColors.surfaceTinted,
      iconColor: BrandColors.primaryDeep,
      title: i18n.securityKeysRemoveTitle,
      body: i18n.securityKeysRemoveExplain,
      confirmLabel: i18n.securityKeysRemoveConfirm,
      cancelLabel: i18n.securityKeysCancel,
    );
    if (ok && mounted) await _setUp(again: true);
  }

  Future<void> _turnOff() async {
    final i18n = FhseLocalizations.of(context);
    final ok = await showConfirmSheet(
      context: context,
      icon: Icons.lock_open_outlined,
      iconBg: BrandColors.errorBg,
      iconColor: BrandColors.error,
      title: i18n.securityKeysTurnOff,
      body: i18n.turnOffBody,
      confirmLabel: i18n.securityKeysTurnOffConfirm,
      cancelLabel: i18n.securityKeysCancel,
    );
    if (!ok || !mounted) return;
    setState(() => _turningOff = true);
    try {
      await turnOffSecurityKeys(context);
      if (mounted) showBrandToast(context, i18n.securityKeysTurnedOff);
    } catch (e) {
      if (mounted) showBrandToast(context, securityKeyErrorMessage(i18n, e) ?? '');
    }
    if (mounted) setState(() => _turningOff = false);
    await _load();
  }

  Future<void> _pickFullLock() async {
    final copy = fullLockCopy(FhseLocalizations.of(context));
    final picked = await pickFullLockMinutes(
      context,
      title: copy.label,
      description: copy.description,
    );
    if (picked != null && mounted) setState(() => _fullLockMinutes = picked);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = FhseLocalizations.of(context);
    final state = _state;

    final List<Widget> content;
    if (_loadFailed) {
      content = [
        BrandCard(
          color: BrandColors.warningBg,
          borderColor: BrandColors.warningBg,
          padding: const EdgeInsets.all(BrandSpacing.lg),
          child: Text(i18n.securityKeysLoadFailed, style: BrandText.body),
        ),
        const SizedBox(height: BrandSpacing.xl),
        BrandButton(label: i18n.securityKeyTryAgain, onPressed: _retry),
      ];
    } else if (state == null) {
      content = [const Center(child: CircularProgressIndicator())];
    } else if (state.engaged && state.unreadable) {
      content = [
        BrandCard(
          color: BrandColors.warningBg,
          borderColor: BrandColors.warningBg,
          padding: const EdgeInsets.all(BrandSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(i18n.securityKeysUnreadableTitle, style: BrandText.listTitle),
              const SizedBox(height: BrandSpacing.sm),
              Text(i18n.securityKeysUnreadableBody, style: BrandText.body),
            ],
          ),
        ),
        const SizedBox(height: BrandSpacing.xl),
        BrandButton(
          label: i18n.securityKeysSetupAgainTitle,
          icon: Icons.key_outlined,
          onPressed: () => _setUp(again: true),
        ),
        const SizedBox(height: 18),
        SettingsGroup(
          tiles: [
            SettingsLinkTile(
              title: i18n.securityKeysTurnOff,
              titleColor: BrandColors.error,
              onTap: _turningOff ? () {} : _turnOff,
            ),
          ],
        ),
      ];
    } else if (!state.available && !state.engaged) {
      content = [
        BrandCard(
          padding: const EdgeInsets.all(BrandSpacing.lg),
          child: Text(
            i18n.securityKeysUnavailable(SecurityKeysUi.config.appName),
            style: BrandText.body,
          ),
        ),
      ];
    } else if (!state.engaged) {
      content = [
        BrandCard(
          padding: const EdgeInsets.all(BrandSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(i18n.securityKeysIntroTitle, style: BrandText.listTitle),
              const SizedBox(height: BrandSpacing.sm),
              Text(i18n.securityKeysIntroBody, style: BrandText.body),
              const SizedBox(height: BrandSpacing.md),
              Text(
                i18n.requirements,
                style: BrandText.caption.copyWith(color: BrandColors.inkMuted),
              ),
              const SizedBox(height: BrandSpacing.sm),
              Text(
                i18n.securityKeysSharedPhraseWarning,
                style: BrandText.caption.copyWith(color: BrandColors.inkMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: BrandSpacing.xl),
        BrandButton(
          label: i18n.securityKeysSetUpButton,
          icon: Icons.key_outlined,
          onPressed: _setUp,
        ),
      ];
    } else {
      content = [
        if (state.keys.length == 1) ...[
          BrandCard(
            color: BrandColors.warningBg,
            borderColor: BrandColors.warningBg,
            padding: const EdgeInsets.all(BrandSpacing.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 19, color: BrandColors.warning),
                const SizedBox(width: BrandSpacing.md),
                Expanded(child: Text(i18n.securityKeysOneKeyWarning, style: BrandText.body)),
              ],
            ),
          ),
          const SizedBox(height: BrandSpacing.xl),
        ],
        SettingsGroup(
          label: i18n.securityKeysYourKeys,
          tiles: [for (final key in state.keys) SecurityKeyTile(record: key)],
        ),
        const SizedBox(height: BrandSpacing.md),
        BrandButton.outline(label: i18n.securityKeysAddButton, icon: Icons.add, onPressed: _addKey),
        const SizedBox(height: 18),
        SettingsGroup(
          label: i18n.securityKeysLockSection,
          tiles: [
            SettingsNavTile(
              title: fullLockCopy(i18n).label,
              value: fullLockLabel(i18n, _fullLockMinutes),
              onTap: _pickFullLock,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, BrandSpacing.sm, 4, 0),
          child: Text(
            fullLockCopy(i18n).description,
            style: BrandText.caption.copyWith(color: BrandColors.inkMuted),
          ),
        ),
        const SizedBox(height: 18),
        SettingsGroup(
          label: i18n.securityKeysManageSection,
          tiles: [
            SettingsLinkTile(
              title: i18n.securityKeysRemoveTitle,
              subtitle: i18n.securityKeysRemoveSubtitle,
              linkLabel: i18n.securityKeysRemoveLink,
              onTap: _removeKey,
            ),
            SettingsLinkTile(
              title: i18n.securityKeysTurnOff,
              titleColor: BrandColors.error,
              onTap: _turningOff ? () {} : _turnOff,
            ),
          ],
        ),
        // Only where a lock leaves the wallet syncing (phones): a desktop's
        // "Lock after" closes it.
        if (!isDesktopAutoLockPlatform)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, BrandSpacing.md, 4, 0),
            child: Text(
              i18n.securityKeysBackgroundNote,
              style: BrandText.caption.copyWith(color: BrandColors.inkMuted),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, BrandSpacing.sm, 4, 0),
          child: Text(
            i18n.securityKeysSharedPhraseWarning,
            style: BrandText.caption.copyWith(color: BrandColors.inkMuted),
          ),
        ),
      ];
    }

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
                    center: Text(
                      i18n.advancedSecurityTitle,
                      style: BrandText.appBar.copyWith(fontSize: 16),
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ...content,
                        // Developer tooling (test/README.md); compiled out of release builds.
                        if (kDebugMode && state != null) ...[
                          const SizedBox(height: 18),
                          SettingsGroup(
                            label: 'Developer',
                            tiles: [
                              SettingsNavTile(
                                title: 'hmac-secret parity test',
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(builder: (_) => const HmacParityScreen()),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
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
