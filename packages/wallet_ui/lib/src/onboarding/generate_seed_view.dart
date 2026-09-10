import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_screen_header.dart';
import '../design/icon_circle_button.dart';
import '../design/seed_grid.dart';
import '../design/step_dots.dart';

/// Translated strings for [GenerateSeedView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class GenerateSeedLabels {
  final String titleCovered;
  final String titleRevealed;
  final String subtitleCovered;
  final String subtitleRevealed;
  final String reveal;
  final String screenshotNote;
  final String confirm;
  final String continueText;

  const GenerateSeedLabels({
    required this.titleCovered,
    required this.titleRevealed,
    required this.subtitleCovered,
    required this.subtitleRevealed,
    required this.reveal,
    required this.screenshotNote,
    required this.confirm,
    required this.continueText,
  });
}

/// Onboarding generate-seed step: a [StepDots] header with a hide action once
/// revealed, a title/subtitle that swap between covered and revealed states, the
/// shared [SeedGrid] (behind a tap-to-reveal gate), an optional [birthdayCard]
/// and an "I wrote it down" confirm check, plus a bottom continue button.
///
/// Presentational only: the view owns the transient reveal/confirm state; the app
/// supplies strings, the seed words and the navigation callback. [seedWords] is
/// null while the seed is still being generated — the view then shows a centered
/// spinner instead of the grid (Skylight). Continue unlocks only once revealed
/// and confirmed.
class GenerateSeedView extends StatefulWidget {
  final GenerateSeedLabels labels;
  final List<String>? seedWords;
  final Widget? birthdayCard;
  final bool continueLoading;
  final VoidCallback onContinue;
  final int stepCount;
  final int stepIndex;

  const GenerateSeedView({
    super.key,
    required this.labels,
    required this.seedWords,
    required this.onContinue,
    required this.stepCount,
    required this.stepIndex,
    this.birthdayCard,
    this.continueLoading = false,
  });

  @override
  State<GenerateSeedView> createState() => _GenerateSeedViewState();
}

class _GenerateSeedViewState extends State<GenerateSeedView> {
  bool _revealed = false;
  bool _confirmed = false;

  bool get _ready => widget.seedWords != null;
  bool get _canContinue => _ready && _revealed && _confirmed && !widget.continueLoading;

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: BrandSpacing.sm),
        BrandScreenHeader(
          onBack: () => Navigator.maybePop(context),
          center: StepDots(count: widget.stepCount, index: widget.stepIndex),
          action: _revealed
              ? IconCircleButton(
                  icon: Icons.visibility_off_outlined,
                  onPressed: () => setState(() => _revealed = false),
                )
              : null,
        ),
        const SizedBox(height: BrandSpacing.lg),
        Text(_revealed ? labels.titleRevealed : labels.titleCovered, style: BrandText.title),
        const SizedBox(height: BrandSpacing.sm),
        Text(
          _revealed ? labels.subtitleRevealed : labels.subtitleCovered,
          style: BrandText.bodyMuted,
        ),
        const SizedBox(height: BrandSpacing.xl),
        Expanded(
          child: !_ready
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    SeedGrid(
                      words: widget.seedWords!,
                      revealed: _revealed,
                      revealLabel: labels.reveal,
                      screenshotNote: labels.screenshotNote,
                      onReveal: () => setState(() => _revealed = true),
                    ),
                    if (_revealed) ...[
                      if (widget.birthdayCard != null) ...[
                        const SizedBox(height: BrandSpacing.lg),
                        widget.birthdayCard!,
                      ],
                      const SizedBox(height: BrandSpacing.lg),
                      _ConfirmCheck(
                        value: _confirmed,
                        label: labels.confirm,
                        onChanged: (v) => setState(() => _confirmed = v),
                      ),
                    ],
                  ],
                ),
        ),
        BrandButton(
          label: labels.continueText,
          loading: widget.continueLoading,
          onPressed: _canContinue ? widget.onContinue : null,
        ),
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

/// The "I wrote my seed down" acknowledgement — a full-row tappable checkbox.
class _ConfirmCheck extends StatelessWidget {
  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  const _ConfirmCheck({required this.value, required this.label, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BrandRadii.rTile,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: BrandSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              value ? Icons.check_box : Icons.check_box_outline_blank,
              color: value ? BrandColors.primary : BrandColors.inkFaint,
              size: 22,
            ),
            const SizedBox(width: BrandSpacing.md),
            Expanded(child: Text(label, style: BrandText.body)),
          ],
        ),
      ),
    );
  }
}
