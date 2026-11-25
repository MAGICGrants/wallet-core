import 'package:flutter/material.dart';
import 'package:wallet_infra/wallet_infra.dart' show SecureScreenMixin;

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_screen_header.dart';
import '../design/brand_text_field.dart';
import '../l10n/ui_strings.dart';

/// Translated strings for [CreatePasswordView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class CreatePasswordLabels {
  final String title;
  final String description;
  final String passwordHint;
  final String confirmPasswordHint;
  final String submit;
  final String fieldEmptyError;
  final String tooShortError;
  final String doNotMatchError;

  const CreatePasswordLabels({
    required this.title,
    required this.description,
    required this.passwordHint,
    required this.confirmPasswordHint,
    required this.submit,
    required this.fieldEmptyError,
    required this.tooShortError,
    required this.doNotMatchError,
  });
}

/// Onboarding "set a wallet password" screen: two obscured fields with a
/// reveal toggle, inline validation error, and a submit button. Presentational
/// only — it owns the obscure/error UI state and the shared rules (non-empty,
/// min 8, match), then calls [onSubmit] with the validated password. The app
/// performs the actual persistence + navigation.
class CreatePasswordView extends StatefulWidget {
  final CreatePasswordLabels labels;
  final bool loading;
  final ValueChanged<String> onSubmit;

  const CreatePasswordView({
    super.key,
    required this.labels,
    required this.onSubmit,
    this.loading = false,
  });

  @override
  State<CreatePasswordView> createState() => _CreatePasswordViewState();
}

// The new password is typed here, and shown in full by the eye buttons: no
// screenshots or recordings, and on Android 14+ only accessibility tools can
// read the screen (SecureScreenMixin), as on the PIN and seed screens.
class _CreatePasswordViewState extends State<CreatePasswordView> with SecureScreenMixin {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String? _validate() {
    final labels = widget.labels;
    final password = _passwordController.text;
    if (password.isEmpty || _confirmPasswordController.text.isEmpty) {
      return labels.fieldEmptyError;
    }
    if (password.length < 8) {
      return labels.tooShortError;
    }
    if (password != _confirmPasswordController.text) {
      return labels.doNotMatchError;
    }
    return null;
  }

  void _submit() {
    final validationError = _validate();
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }
    setState(() => _error = null);
    widget.onSubmit(_passwordController.text);
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    final strings = uiStringsOf(context);
    // The eye button says what pressing it does.
    String? eyeLabel(bool obscured) =>
        obscured ? strings?.a11yShowPassword : strings?.a11yHidePassword;

    return Scaffold(
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
                  const SizedBox(height: BrandSpacing.sm),
                  BrandScreenHeader(onBack: () => Navigator.maybePop(context)),
                  const Spacer(flex: 2),
                  Semantics(
                    container: true,
                    header: true,
                    namesRoute: true,
                    child: Text(labels.title, textAlign: TextAlign.center, style: BrandText.title),
                  ),
                  const SizedBox(height: BrandSpacing.sm),
                  Text(labels.description, textAlign: TextAlign.center, style: BrandText.bodyMuted),
                  const SizedBox(height: BrandSpacing.xl),
                  BrandTextField(
                    controller: _passwordController,
                    hint: labels.passwordHint,
                    // The hint goes once the field holds text; this stays.
                    semanticLabel: labels.passwordHint,
                    obscureText: _obscurePassword,
                    sensitive: true,
                    suffix: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: BrandColors.inkMuted,
                        semanticLabel: eyeLabel(_obscurePassword),
                      ),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  const SizedBox(height: BrandSpacing.md),
                  BrandTextField(
                    controller: _confirmPasswordController,
                    hint: labels.confirmPasswordHint,
                    semanticLabel: labels.confirmPasswordHint,
                    obscureText: _obscureConfirmPassword,
                    sensitive: true,
                    suffix: IconButton(
                      icon: Icon(
                        _obscureConfirmPassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: BrandColors.inkMuted,
                        semanticLabel: eyeLabel(_obscureConfirmPassword),
                      ),
                      onPressed: () =>
                          setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: BrandSpacing.sm),
                    // Spoken as it appears or changes.
                    Semantics(
                      container: true,
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: BrandText.caption.copyWith(color: BrandColors.error),
                      ),
                    ),
                  ],
                  const Spacer(flex: 3),
                  BrandButton(label: labels.submit, loading: widget.loading, onPressed: _submit),
                  const SizedBox(height: BrandSpacing.sm),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
