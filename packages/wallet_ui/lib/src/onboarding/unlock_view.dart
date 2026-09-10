import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_text_field.dart';

/// Translated strings for [UnlockView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class UnlockLabels {
  final String title;
  final String passwordHint;
  final String unlockButton;

  const UnlockLabels({required this.title, required this.passwordHint, required this.unlockButton});
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
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: BrandColors.paper,
        body: SafeArea(
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
                    if (isDesktop) ...[
                      const SizedBox(height: BrandSpacing.xl),
                      BrandTextField(
                        controller: passwordController,
                        hint: labels.passwordHint,
                        obscureText: obscure,
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
                    ],
                    const Spacer(flex: 4),
                    if (isDesktop)
                      BrandButton(
                        label: labels.unlockButton,
                        loading: loading,
                        onPressed: onUnlockPassword,
                      )
                    else
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
        ),
      ),
    );
  }
}
