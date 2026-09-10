import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_screen_header.dart';
import '../design/fiat_modes_view.dart';
import '../design/step_dots.dart';

/// Translated strings for [FiatSetupView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class FiatSetupLabels {
  final String title;
  final String subtitle;
  final String torOnly;
  final String torOnlyDesc;
  final String clearnet;
  final String clearnetDesc;
  final String disabled;
  final String disabledDesc;
  final String currencyLabel;
  final String continueText;

  const FiatSetupLabels({
    required this.title,
    required this.subtitle,
    required this.torOnly,
    required this.torOnlyDesc,
    required this.clearnet,
    required this.clearnetDesc,
    required this.disabled,
    required this.disabledDesc,
    required this.currencyLabel,
    required this.continueText,
  });
}

/// Onboarding "fiat price source" screen: a [StepDots] header, three
/// [ModeSelectCard]s (Tor-Only / Clearnet / Disabled) and — unless disabled — a
/// currency picker, plus a bottom continue button. Presentational only: mode is
/// an int index (0=torOnly, 1=clearnet, 2=disabled) so the view doesn't couple
/// to any fiat enum; the app supplies strings, currencies and callbacks.
class FiatSetupView extends StatelessWidget {
  final FiatSetupLabels labels;
  final List<FiatCurrencyOption> currencies;
  final int modeIndex;
  final String currency;

  /// Whether the Tor-only card is offered. Spice/Skylight hide it when global
  /// Tor is disabled (Tor-only fiat is unreachable then).
  final bool offerTorOnly;
  final ValueChanged<int> onModeChanged;
  final ValueChanged<String> onCurrencyChanged;
  final VoidCallback onContinue;
  final int stepCount;
  final int stepIndex;

  const FiatSetupView({
    super.key,
    required this.labels,
    required this.currencies,
    required this.modeIndex,
    required this.currency,
    required this.offerTorOnly,
    required this.onModeChanged,
    required this.onCurrencyChanged,
    required this.onContinue,
    required this.stepCount,
    required this.stepIndex,
  });

  @override
  Widget build(BuildContext context) {
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: BrandSpacing.sm),
        BrandScreenHeader(
          onBack: () => Navigator.maybePop(context),
          center: StepDots(count: stepCount, index: stepIndex),
        ),
        const SizedBox(height: BrandSpacing.lg),
        Text(labels.title, style: BrandText.title),
        const SizedBox(height: BrandSpacing.sm),
        Text(labels.subtitle, style: BrandText.bodyMuted),
        const SizedBox(height: BrandSpacing.xl),
        Expanded(
          child: ListView(
            children: [
              FiatModesView(
                torOnly: labels.torOnly,
                torOnlyDesc: labels.torOnlyDesc,
                clearnet: labels.clearnet,
                clearnetDesc: labels.clearnetDesc,
                disabled: labels.disabled,
                disabledDesc: labels.disabledDesc,
                offerTorOnly: offerTorOnly,
                modeIndex: modeIndex,
                onModeChanged: onModeChanged,
                currencyLabel: labels.currencyLabel,
                currencies: currencies,
                currency: currency,
                onCurrencyChanged: onCurrencyChanged,
              ),
            ],
          ),
        ),
        BrandButton(label: labels.continueText, onPressed: onContinue),
        const SizedBox(height: BrandSpacing.sm),
      ],
    );

    return Scaffold(
      backgroundColor: BrandColors.paper,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: BrandSpacing.xl),
              child: column,
            ),
          ),
        ),
      ),
    );
  }
}
