import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_screen_header.dart';
import '../design/option_card.dart';
import '../design/step_dots.dart';

/// Translated strings for [CreateWalletView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class CreateWalletLabels {
  final String title;
  final String subtitle;
  final String createNew;
  final String createNewDesc;
  final String restore;
  final String restoreDesc;

  const CreateWalletLabels({
    required this.title,
    required this.subtitle,
    required this.createNew,
    required this.createNewDesc,
    required this.restore,
    required this.restoreDesc,
  });
}

/// Onboarding wallet-choice screen: a [StepDots] header plus two option cards
/// ("Create New" / "Restore"). Presentational only — the app supplies strings,
/// step progress and the navigation callbacks. Identical layout in both apps.
class CreateWalletView extends StatelessWidget {
  final CreateWalletLabels labels;
  final int stepCount;
  final int stepIndex;
  final VoidCallback onCreateNew;
  final VoidCallback onRestore;

  const CreateWalletView({
    super.key,
    required this.labels,
    required this.stepCount,
    required this.stepIndex,
    required this.onCreateNew,
    required this.onRestore,
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
                  OptionCard(
                    icon: Icons.add,
                    title: labels.createNew,
                    description: labels.createNewDesc,
                    onTap: onCreateNew,
                  ),
                  const SizedBox(height: BrandSpacing.md),
                  OptionCard(
                    icon: Icons.refresh,
                    title: labels.restore,
                    description: labels.restoreDesc,
                    onTap: onRestore,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
