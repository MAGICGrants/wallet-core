import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/icon_circle_button.dart';

/// Translated strings for [WelcomeView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class WelcomeLabels {
  final String getStarted;
  final String agreePrefix;
  final String termsLink;
  final String agreeMiddle;
  final String privacyLink;

  const WelcomeLabels({
    required this.getStarted,
    required this.agreePrefix,
    required this.termsLink,
    required this.agreeMiddle,
    required this.privacyLink,
  });
}

/// The onboarding entry screen: a centred logo + app name + description, a
/// "Get started" button, and a terms/privacy line. Presentational only — the
/// app supplies the [logo], [appName], strings and navigation callbacks.
class WelcomeView extends StatelessWidget {
  final Widget logo;
  final String appName;
  final String description;
  final WelcomeLabels labels;
  final VoidCallback onGetStarted;
  final VoidCallback onTerms;
  final VoidCallback onPrivacy;

  /// App-name colour; defaults to [BrandColors.primaryDeep].
  final Color? appNameColor;

  /// Gap between the logo and the app name; defaults to [BrandSpacing.xl].
  final double? logoBottomGap;

  /// Opens the language picker (welcome has no route to Settings). Null omits
  /// the button.
  final VoidCallback? onLanguage;

  const WelcomeView({
    super.key,
    required this.logo,
    required this.appName,
    required this.description,
    required this.labels,
    required this.onGetStarted,
    required this.onTerms,
    required this.onPrivacy,
    this.appNameColor,
    this.logoBottomGap,
    this.onLanguage,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrandColors.paper,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BrandSpacing.xl),
              child: Column(
                children: [
                  const SizedBox(height: BrandSpacing.sm),
                  if (onLanguage != null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [IconCircleButton(icon: Icons.language, onPressed: onLanguage!)],
                    ),
                  const Spacer(flex: 3),
                  logo,
                  SizedBox(height: logoBottomGap ?? BrandSpacing.xl),
                  Text(
                    appName,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      color: appNameColor ?? BrandColors.primaryDeep,
                    ),
                  ),
                  const SizedBox(height: BrandSpacing.md),
                  Text(description, textAlign: TextAlign.center, style: BrandText.bodyMuted),
                  const Spacer(flex: 4),
                  BrandButton(label: labels.getStarted, onPressed: onGetStarted),
                  const SizedBox(height: BrandSpacing.lg),
                  _TermsLine(labels: labels, onTerms: onTerms, onPrivacy: onPrivacy),
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

class _TermsLine extends StatelessWidget {
  final WelcomeLabels labels;
  final VoidCallback onTerms;
  final VoidCallback onPrivacy;

  const _TermsLine({required this.labels, required this.onTerms, required this.onPrivacy});

  @override
  Widget build(BuildContext context) {
    final link = BrandText.caption.copyWith(
      color: BrandColors.primaryDeep,
      fontWeight: FontWeight.w500,
    );
    return Text.rich(
      TextSpan(
        style: BrandText.caption,
        children: [
          TextSpan(text: labels.agreePrefix),
          TextSpan(
            text: labels.termsLink,
            style: link,
            recognizer: TapGestureRecognizer()..onTap = onTerms,
          ),
          TextSpan(text: labels.agreeMiddle),
          TextSpan(
            text: labels.privacyLink,
            style: link,
            recognizer: TapGestureRecognizer()..onTap = onPrivacy,
          ),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }
}
