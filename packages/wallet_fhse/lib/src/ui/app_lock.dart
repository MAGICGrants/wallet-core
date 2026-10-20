import 'dart:io';

import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart'
    show
        BiometricAuth,
        BiometricAuthResult,
        BoundToAnotherPcException,
        SecureScreenMixin,
        WalletSecrets;
import 'package:wallet_ui/wallet_ui.dart';

import '../l10n/fhse_localizations.dart';
import 'security_key_flow.dart' show securityKeyErrorMessage;
import 'security_keys_app.dart';

/// App Lock's "Lock after" for [minutes]: "Immediately", "10 minutes", "1 hour".
String appLockLabel(FhseLocalizations i18n, int minutes) => minutes == 0
    ? i18n.appLockImmediately
    : minutes % 60 == 0
    ? i18n.securityKeysHours(minutes ~/ 60)
    : i18n.securityKeysMinutes(minutes);

/// App Lock, passed again now, however recently it last was: what every screen
/// or action that needs a passing App Lock asks for. Screens are routed through
/// [AppLockGate]; a sheet or an action calls this first. True once passed.
///
/// The platform decides what App Lock is, so callers never do: the device's
/// own prompt where the keystore holds the wallet password (face, fingerprint
/// or passcode on Android and iOS, Touch ID or the Mac's password on macOS;
/// [BiometricAuth.confirmOwner], which passes on a device with no lock),
/// asking with [reason]; the wallet password on Linux and Windows
/// ([WalletManager.checkTypedPassword]), with [passwordBody] under the title.
///
/// A phone or computer left unlocked must not be enough.
Future<bool> passAppLock(
  BuildContext context, {
  required String reason,
  String? passwordBody,
  @visibleForTesting Future<BiometricAuthResult> Function(String reason)? authenticate,
  @visibleForTesting bool? typesPassword,
}) async {
  final i18n = FhseLocalizations.of(context);
  if (!(typesPassword ?? !WalletSecrets.holdsWalletPassword)) {
    final result = await (authenticate ?? _confirmOwner)(reason);
    if (result == BiometricAuthResult.authenticated) return true;
    if (result == BiometricAuthResult.error && context.mounted) {
      showBrandToast(context, i18n.advancedSecurityAuthFailed);
    }
    return false;
  }
  final body = passwordBody ?? i18n.advancedSecurityPasswordBody(SecurityKeysUi.config.appName);
  final ok = await showBrandSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PasswordSheet(body: body),
  );
  return ok ?? false;
}

/// Before a lock is made to wait longer (App Lock's time, the desktop "Lock
/// after"): App Lock is passed again ([passAppLock]). A shorter time needs
/// nothing: it only locks sooner.
///
/// A phone or computer left unlocked must not be enough to make the next lock
/// come later.
Future<bool> confirmOwnerToLockLater(
  BuildContext context, {
  @visibleForTesting Future<BiometricAuthResult> Function(String reason)? authenticate,
  @visibleForTesting bool? typesPassword,
}) {
  final i18n = FhseLocalizations.of(context);
  final appName = SecurityKeysUi.config.appName;
  return passAppLock(
    context,
    reason: i18n.lockLaterAuthReason(appName),
    passwordBody: i18n.lockLaterPasswordBody(appName),
    authenticate: authenticate,
    typesPassword: typesPassword,
  );
}

Future<BiometricAuthResult> _confirmOwner(String reason) =>
    BiometricAuth.confirmOwner(reason: reason);

/// The wallet password, checked without changing what is unlocked
/// ([WalletManager.checkTypedPassword]). Pops true once it is right.
class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet({required this.body});

  final String body;

  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final _password = TextEditingController();
  bool _checking = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final typed = _password.text;
    if (typed.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    final i18n = FhseLocalizations.of(context);
    bool ok;
    String? failure;
    try {
      ok = await SecurityKeysUi.config.walletManagerOf(context).checkTypedPassword(typed);
    } on BoundToAnotherPcException {
      ok = false;
      failure = i18n.unlockBoundToAnotherPc;
    } catch (e) {
      ok = false;
      failure = i18n.securityKeysErrorGeneric(e.runtimeType.toString());
    }
    if (!mounted) return;
    _password.clear();
    if (ok) {
      Navigator.pop(context, true);
      return;
    }
    setState(() {
      _checking = false;
      _error = failure ?? i18n.advancedSecurityPasswordWrong;
    });
  }

  @override
  Widget build(BuildContext context) {
    final i18n = FhseLocalizations.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, 10, 22, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Text(i18n.advancedSecurityPasswordTitle, style: BrandText.sheetTitle),
            const SizedBox(height: BrandSpacing.xs),
            Text(widget.body, style: BrandText.bodyMuted),
            const SizedBox(height: BrandSpacing.lg),
            BrandTextField(
              controller: _password,
              label: i18n.advancedSecurityPasswordLabel,
              obscureText: _obscure,
              keyboardType: TextInputType.visiblePassword,
              onSubmitted: (_) => _check(),
              suffix: IconButton(
                icon: Icon(
                  _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  color: BrandColors.inkMuted,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: BrandSpacing.sm),
              Text(_error!, style: BrandText.caption.copyWith(color: BrandColors.error)),
            ],
            const SizedBox(height: BrandSpacing.lg),
            BrandButton(
              label: i18n.advancedSecurityContinue,
              loading: _checking,
              onPressed: _checking ? null : _check,
            ),
          ],
        ),
      ),
    );
  }
}

/// Settings > App Lock: how long the app may be away before App Lock asks
/// again ([AppLockPreferences]). Always on; the time can be shortened freely,
/// and lengthened once the owner confirms ([confirmOwnerToLockLater]).
///
/// Where App Lock is the device's own prompt and the device has no lock at all,
/// App Lock has nothing to ask, and the row says so.
class AppLockTile extends StatefulWidget {
  const AppLockTile({
    super.key,
    @visibleForTesting this.deviceHasLock,
    @visibleForTesting this.confirmLater,
  });

  final Future<bool> Function()? deviceHasLock;
  final Future<bool> Function(BuildContext context)? confirmLater;

  @override
  State<AppLockTile> createState() => _AppLockTileState();
}

class _AppLockTileState extends State<AppLockTile> {
  int? _minutes;
  bool _noDeviceLock = false;

  @override
  void initState() {
    super.initState();
    AppLockPreferences.minutes().then((m) {
      if (mounted) setState(() => _minutes = m);
    });
    if (WalletSecrets.holdsWalletPassword || widget.deviceHasLock != null) {
      (widget.deviceHasLock ?? BiometricAuth.isAvailable)().then((has) {
        if (mounted) setState(() => _noDeviceLock = !has);
      });
    }
  }

  String _description(FhseLocalizations i18n) {
    final appName = SecurityKeysUi.config.appName;
    if (!WalletSecrets.holdsWalletPassword) return i18n.appLockDescriptionPassword(appName);
    if (Platform.isMacOS) return i18n.appLockDescriptionMac(appName);
    return i18n.appLockDescriptionPhone(appName);
  }

  Future<void> _pick() async {
    final i18n = FhseLocalizations.of(context);
    final current = _minutes ?? await AppLockPreferences.minutes();
    if (!mounted) return;
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
              Text(i18n.appLockLabel, style: BrandText.sheetTitle),
              const SizedBox(height: BrandSpacing.xs),
              Text(_description(i18n), style: BrandText.bodyMuted),
              const SizedBox(height: BrandSpacing.lg),
              SettingsGroup(
                tiles: [
                  for (final minutes in AppLockPreferences.minuteOptions)
                    InkWell(
                      onTap: () => Navigator.pop(sheetContext, minutes),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(appLockLabel(i18n, minutes), style: BrandText.listTitle),
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
    if (picked == null || picked == current || !mounted) return;
    if (picked > current) {
      final confirmed = await (widget.confirmLater ?? confirmOwnerToLockLater)(context);
      if (!confirmed || !mounted) return;
    }
    await AppLockPreferences.setMinutes(picked);
    if (mounted) setState(() => _minutes = picked);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = FhseLocalizations.of(context);
    final minutes = _minutes;
    final tile = SettingsNavTile(
      title: i18n.appLockLabel,
      value: minutes == null ? '' : appLockLabel(i18n, minutes),
      onTap: _pick,
    );
    if (!_noDeviceLock) return tile;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile,
        Padding(
          padding: const EdgeInsets.fromLTRB(15, 0, 15, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: BrandColors.warning),
              const SizedBox(width: BrandSpacing.sm),
              Expanded(
                child: Text(
                  i18n.appLockNoDeviceLock(SecurityKeysUi.config.appName),
                  style: BrandText.caption.copyWith(color: BrandColors.warning),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// App Lock's "Use recovery phrase", offered when the device cannot confirm
/// its owner: the sheet, through [unlockAppLockWithRecoveryPhrase]. Returns
/// true once the wallet is open; the caller marks the session unlocked and
/// moves on.
Future<bool> showAppLockRecoveryPhrase(BuildContext context) async {
  final i18n = FhseLocalizations.of(context);
  var keysRecovered = false;
  final opened = await showRecoveryPhraseSheet(
    context,
    body: i18n.appLockUseRecoveryPhraseBody(SecurityKeysUi.config.appName),
    unlock: (sheetContext, phrase) async {
      keysRecovered = await unlockAppLockWithRecoveryPhrase(sheetContext, phrase);
    },
  );
  if (opened && keysRecovered && context.mounted) {
    showBrandToast(context, i18n.securityKeyRecoveredToast);
  }
  return opened;
}

/// Asks for the recovery phrase and opens the wallet with it through [unlock],
/// which throws on a phrase that is not this wallet's. Returns true once it is
/// open; the caller then marks the session unlocked and moves on.
///
/// The way past App Lock when the device cannot confirm its owner
/// ([unlockAppLockWithRecoveryPhrase]), and past security keys when they are
/// lost ([unlockWithRecoveryPhrase]).
Future<bool> showRecoveryPhraseSheet(
  BuildContext context, {
  required Future<void> Function(BuildContext context, String phrase) unlock,
  String? body,
}) async {
  final opened = await showBrandSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _RecoveryPhraseSheet(unlock: unlock, body: body),
  );
  return opened ?? false;
}

class _RecoveryPhraseSheet extends StatefulWidget {
  const _RecoveryPhraseSheet({required this.unlock, this.body});

  final Future<void> Function(BuildContext context, String phrase) unlock;
  final String? body;

  @override
  State<_RecoveryPhraseSheet> createState() => _RecoveryPhraseSheetState();
}

/// Screen-protected while it is up (Android and iOS: no screenshots or
/// recording, blurred in the app switcher); the desktop OSes have no dependable
/// equivalent.
class _RecoveryPhraseSheetState extends State<_RecoveryPhraseSheet>
    with SecureScreenMixin<_RecoveryPhraseSheet> {
  final _phrase = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final i18n = FhseLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.unlock(context, _phrase.text);
      if (!mounted) return;
      _phrase.clear();
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is Exception && e.toString().contains('Invalid mnemonic')
              ? i18n.securityKeyRecoveryWrongPhrase
              : securityKeyErrorMessage(i18n, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = FhseLocalizations.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Text(i18n.securityKeyUseRecoveryPhrase, style: BrandText.sheetTitle),
            if (widget.body != null) ...[
              const SizedBox(height: BrandSpacing.xs),
              Text(widget.body!, style: BrandText.bodyMuted),
            ],
            const SizedBox(height: BrandSpacing.lg),
            BrandTextField(
              controller: _phrase,
              hint: i18n.securityKeyRecoveryPhraseHint,
              maxLines: 4,
              keyboardType: TextInputType.visiblePassword,
              sensitive: true,
            ),
            if (_error != null) ...[
              const SizedBox(height: BrandSpacing.sm),
              Text(_error!, style: BrandText.caption.copyWith(color: BrandColors.error)),
            ],
            const SizedBox(height: BrandSpacing.lg),
            BrandButton(
              label: i18n.securityKeyUnlockButton,
              loading: _busy,
              onPressed: _busy ? null : _unlock,
            ),
          ],
        ),
      ),
    );
  }
}
