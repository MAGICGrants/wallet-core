import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart' show TorService, TorConnectionStatus;

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_text_field.dart';

/// Translated strings for [UnlockView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class UnlockLabels {
  final String title;
  final String passwordHint;
  final String unlockButton;

  /// Desktop caption above the password field; null hides it.
  final String? passwordLabel;

  const UnlockLabels({
    required this.title,
    required this.passwordHint,
    required this.unlockButton,
    this.passwordLabel,
  });
}

/// The app-lock screen: the app mark, a title, and either a biometric unlock
/// button (mobile) or a password field + unlock button (desktop). Wrapped in a
/// [PopScope] so the system back button can't reveal the screen behind a relock.
///
/// Presentational only — the app owns the biometric/password logic and supplies
/// the [logo], labels, controller and callbacks.
class UnlockView extends StatelessWidget {
  final Widget logo;
  final UnlockLabels labels;
  final bool isDesktop;
  final TextEditingController passwordController;
  final bool obscure;
  final VoidCallback onToggleObscure;
  final String? error;
  final bool loading;

  /// Mobile unlock button label (e.g. a resolved "Face ID"); falls back to
  /// [UnlockLabels.unlockButton].
  final String? biometricLabel;
  final IconData biometricIcon;
  final VoidCallback onUnlockPassword;
  final VoidCallback onUnlockBiometric;

  /// Desktop footer version line (e.g. "Spice Wallet 2.1.0 · build 4127"); null
  /// hides the bottom status bar.
  final String? version;

  const UnlockView({
    super.key,
    required this.logo,
    required this.labels,
    required this.isDesktop,
    required this.passwordController,
    required this.obscure,
    required this.onToggleObscure,
    required this.onUnlockPassword,
    required this.onUnlockBiometric,
    this.error,
    this.loading = false,
    this.biometricLabel,
    this.biometricIcon = Icons.lock_outline,
    this.version,
  });

  @override
  Widget build(BuildContext context) {
    final content = isDesktop ? _desktopContent() : _mobileContent();

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: BrandColors.paper,
        body: isDesktop && version != null
            ? Column(
                children: [
                  Expanded(child: content),
                  _statusBar(),
                ],
              )
            : content,
      ),
    );
  }

  // Desktop: logo, title, field and button as one vertically-centred group.
  Widget _desktopContent() {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: BrandSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: logo),
                const SizedBox(height: BrandSpacing.lg),
                Text(labels.title, textAlign: TextAlign.center, style: BrandText.title),
                const SizedBox(height: BrandSpacing.xl),
                if (labels.passwordLabel != null) ...[
                  Text(labels.passwordLabel!.toUpperCase(), style: BrandText.section),
                  const SizedBox(height: BrandSpacing.sm),
                ],
                BrandTextField(
                  controller: passwordController,
                  hint: labels.passwordHint,
                  obscureText: obscure,
                  onSubmitted: (_) => onUnlockPassword(),
                  suffix: IconButton(
                    icon: Icon(
                      obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      color: BrandColors.inkMuted,
                    ),
                    onPressed: onToggleObscure,
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: BrandSpacing.sm),
                  Text(error!, style: BrandText.caption.copyWith(color: BrandColors.error)),
                ],
                const SizedBox(height: BrandSpacing.lg),
                ValueListenableBuilder(
                  valueListenable: passwordController,
                  builder: (context, value, _) => BrandButton(
                    label: labels.unlockButton,
                    loading: loading,
                    onPressed: value.text.isEmpty ? null : onUnlockPassword,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Mobile: logo/title in the upper third, biometric button lower.
  Widget _mobileContent() {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: BrandSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(flex: 3),
                Center(child: logo),
                const SizedBox(height: BrandSpacing.xl),
                Text(labels.title, textAlign: TextAlign.center, style: BrandText.title),
                const Spacer(flex: 4),
                BrandButton(
                  label: biometricLabel ?? labels.unlockButton,
                  icon: biometricIcon,
                  onPressed: onUnlockBiometric,
                ),
                const SizedBox(height: BrandSpacing.sm),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusBar() {
    final (Color color, String text) = switch (TorService.sharedInstance.status) {
      TorConnectionStatus.connected => (BrandColors.purple, 'Tor · connected'),
      TorConnectionStatus.connecting => (BrandColors.warning, 'Tor · connecting'),
      TorConnectionStatus.disconnected => (BrandColors.inkFaint, 'Tor · off'),
    };
    return Container(
      decoration: BoxDecoration(
        color: BrandColors.surfaceSunken,
        border: Border(top: BorderSide(color: BrandColors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 9),
              Text(
                text,
                style: TextStyle(
                  fontFamily: 'Ubuntu',
                  fontSize: 12,
                  height: 1,
                  color: BrandColors.inkMuted,
                ),
              ),
            ],
          ),
          Text(
            version!,
            style: TextStyle(
              fontFamily: 'Ubuntu Mono',
              fontSize: 10.5,
              height: 1,
              color: BrandColors.inkFaint,
            ),
          ),
        ],
      ),
    );
  }
}
