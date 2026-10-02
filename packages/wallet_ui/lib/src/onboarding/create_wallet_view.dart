import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_screen_header.dart';
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
                  _OptionCard(
                    icon: Icons.add,
                    title: labels.createNew,
                    description: labels.createNewDesc,
                    onTap: onCreateNew,
                  ),
                  const SizedBox(height: BrandSpacing.md),
                  _OptionCard(
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

/// Full-width choice card: icon tile + title + description + chevron.
class _OptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _OptionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: BrandColors.card,
        borderRadius: BrandRadii.rField,
        border: Border.all(color: BrandColors.border),
      ),
      child: ClipRRect(
        borderRadius: BrandRadii.rField,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: BrandColors.surfaceSunken,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: BrandColors.primary, size: 22),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: BrandColors.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(description, style: BrandText.caption),
                      ],
                    ),
                  ),
                  const SizedBox(width: BrandSpacing.sm),
                  Icon(Icons.chevron_right, color: BrandColors.inkFaint, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
