import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart'
    show BiometricAuth, BiometricAuthResult, BoundToAnotherPcException, WalletSecrets;
import 'package:wallet_ui/wallet_ui.dart';

import '../l10n/fhse_localizations.dart';
import 'advanced_security_screen.dart';
import 'security_keys_app.dart';

/// Settings > Advanced Security, behind a fresh check that it is the owner,
/// every time it opens: the device's own authentication (what App Lock uses:
/// fingerprint, face, or the passcode or the Mac's password) on Android, iOS
/// and macOS, however recently App Lock was passed, and the wallet password on
/// Linux and Windows.
///
/// The screen can turn security keys off, set them up again, add one, or
/// lengthen the lock, so a phone or computer left unlocked must not be enough.
/// (Opening the app already needed a key; this guards the screen that can
/// remove that need.) Apps route `/advanced_security` here.
///
/// A device with no lock at all (no passcode, no biometrics) has nothing to
/// ask, App Lock included, so the screen opens.
class GuardedAdvancedSecurityScreen extends StatefulWidget {
  const GuardedAdvancedSecurityScreen({
    super.key,
    this.child = const AdvancedSecurityScreen(),
    @visibleForTesting this.authenticate,
    @visibleForTesting this.deviceCanAuthenticate,
    @visibleForTesting this.typesPassword,
  });

  final Widget child;
  final Future<BiometricAuthResult> Function(String reason)? authenticate;
  final Future<bool> Function()? deviceCanAuthenticate;

  /// Linux and Windows: the user types the wallet password. Defaults to the
  /// platform's ([WalletSecrets.holdsWalletPassword] false).
  final bool? typesPassword;

  @override
  State<GuardedAdvancedSecurityScreen> createState() => _GuardedAdvancedSecurityScreenState();
}

class _GuardedAdvancedSecurityScreenState extends State<GuardedAdvancedSecurityScreen> {
  final _password = TextEditingController();
  bool _passed = false;
  bool _checking = false;
  bool _obscure = true;
  String? _error;
  bool _started = false;

  bool get _typesPassword => widget.typesPassword ?? !WalletSecrets.holdsWalletPassword;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!_typesPassword) {
      final reason = FhseLocalizations.of(context).advancedSecurityAuthReason;
      WidgetsBinding.instance.addPostFrameCallback((_) => _askDevice(reason));
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _askDevice(String reason) async {
    final result = await (widget.authenticate ?? _deviceAuth)(reason);
    if (!mounted) return;
    if (result == BiometricAuthResult.authenticated) {
      setState(() => _passed = true);
      return;
    }
    if (result == BiometricAuthResult.error &&
        !await (widget.deviceCanAuthenticate ?? BiometricAuth.isAvailable)()) {
      // No lock set up on this device: nothing stronger to ask for.
      if (mounted) setState(() => _passed = true);
      return;
    }
    if (!mounted) return;
    if (result == BiometricAuthResult.error) {
      showBrandToast(context, FhseLocalizations.of(context).advancedSecurityAuthFailed);
    }
    Navigator.of(context).maybePop();
  }

  static Future<BiometricAuthResult> _deviceAuth(String reason) =>
      BiometricAuth.authenticate(reason: reason);

  Future<void> _checkPassword() async {
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
    setState(() {
      _checking = false;
      if (ok) {
        _passed = true;
      } else {
        _error = failure ?? i18n.advancedSecurityPasswordWrong;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_passed) return widget.child;
    // Opaque until passed, so nothing of the screen shows behind the prompt.
    if (!_typesPassword) {
      return ColoredBox(color: BrandColors.paper, child: const SizedBox.expand());
    }

    final i18n = FhseLocalizations.of(context);
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
                        Text(i18n.advancedSecurityPasswordTitle, style: BrandText.listTitle),
                        const SizedBox(height: BrandSpacing.sm),
                        Text(
                          i18n.advancedSecurityPasswordBody(SecurityKeysUi.config.appName),
                          style: BrandText.body,
                        ),
                        const SizedBox(height: BrandSpacing.lg),
                        BrandTextField(
                          controller: _password,
                          label: i18n.advancedSecurityPasswordLabel,
                          obscureText: _obscure,
                          keyboardType: TextInputType.visiblePassword,
                          onSubmitted: (_) => _checkPassword(),
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
                          Text(_error!, style: BrandText.body.copyWith(color: BrandColors.error)),
                        ],
                        const SizedBox(height: BrandSpacing.lg),
                        BrandButton(
                          label: i18n.advancedSecurityContinue,
                          loading: _checking,
                          onPressed: _checking ? () {} : _checkPassword,
                        ),
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
