import 'dart:ui';

import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/click_cursor.dart';
import 'onboarding_scaffold.dart';

/// Desktop generate-seed onboarding step: the two-pane [DesktopOnboardingScaffold]
/// with a 3-column seed grid behind a tap-to-reveal gate, the wallet birthday,
/// and an "I wrote it down" confirm check. Continue unlocks only once the seed is
/// both revealed and confirmed. Shared by both apps — [logo], [step]/[totalSteps]
/// and the copy differ per app and are injected.
class DesktopGenerateSeedView extends StatefulWidget {
  final Widget logo;
  final String title;
  final String description;
  final List<String> seedWords;
  final String birthdayLabel;
  final String birthdayReason;
  final String? birthdayValue;
  final String confirmLabel;
  final String passwordNote;
  final String revealLabel;
  final String continueText;
  final int step;
  final int totalSteps;
  final bool loading;
  final VoidCallback onContinue;
  final VoidCallback? onBack;

  const DesktopGenerateSeedView({
    super.key,
    required this.logo,
    required this.title,
    required this.description,
    required this.seedWords,
    required this.birthdayLabel,
    required this.birthdayReason,
    required this.confirmLabel,
    required this.passwordNote,
    required this.revealLabel,
    required this.continueText,
    required this.step,
    required this.totalSteps,
    required this.onContinue,
    this.birthdayValue,
    this.loading = false,
    this.onBack,
  });

  @override
  State<DesktopGenerateSeedView> createState() => _DesktopGenerateSeedViewState();
}

class _DesktopGenerateSeedViewState extends State<DesktopGenerateSeedView> {
  bool _revealed = false;
  bool _confirmed = false;

  Widget _blurUntilRevealed(Widget child) => _revealed
      ? child
      : ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8), child: child);

  @override
  Widget build(BuildContext context) {
    return DesktopOnboardingScaffold(
      logo: widget.logo,
      title: widget.title,
      description: widget.description,
      step: widget.step,
      totalSteps: widget.totalSteps,
      continueLabel: widget.continueText,
      // Continue unlocks only once the seed has been revealed and confirmed.
      continueEnabled: _revealed && _confirmed,
      loading: widget.loading,
      onBack: widget.onBack,
      onContinue: widget.onContinue,
      notes: [OnboardingNote(Icons.lock_outline, widget.passwordNote)],
      content: ListView(
        padding: EdgeInsets.zero,
        children: [
          _SeedGate(
            revealed: _revealed,
            revealLabel: widget.revealLabel,
            onReveal: () => setState(() => _revealed = true),
            grid: GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 4.4,
              children: [
                for (var i = 0; i < widget.seedWords.length; i++)
                  _SeedCell(index: i + 1, word: widget.seedWords[i]),
              ],
            ),
          ),
          // Birthday is blurred alongside the seed until revealed (the grid owns
          // the reveal pill); the confirmation appears only once revealed.
          if (widget.birthdayValue != null) ...[
            const SizedBox(height: 16),
            _blurUntilRevealed(
              _BirthdayCard(
                label: widget.birthdayLabel,
                reason: widget.birthdayReason,
                value: widget.birthdayValue!,
              ),
            ),
          ],
          if (_revealed) ...[
            const SizedBox(height: 18),
            InkWell(
              mouseCursor: WidgetStateMouseCursor.clickable,
              onTap: () => setState(() => _confirmed = !_confirmed),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    value: _confirmed,
                    onChanged: (v) => setState(() => _confirmed = v ?? false),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 11),
                      child: Text(
                        widget.confirmLabel,
                        style: TextStyle(
                          fontFamily: 'Ubuntu',
                          fontSize: 13,
                          height: 1.5,
                          color: BrandColors.inkMuted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Blurs the seed [grid] behind a tap-to-reveal affordance until the user
/// explicitly reveals it — mirrors the shared mobile SeedGrid gate.
class _SeedGate extends StatelessWidget {
  final Widget grid;
  final bool revealed;
  final String revealLabel;
  final VoidCallback onReveal;

  const _SeedGate({
    required this.grid,
    required this.revealed,
    required this.revealLabel,
    required this.onReveal,
  });

  @override
  Widget build(BuildContext context) {
    if (revealed) return grid;
    return Stack(
      alignment: Alignment.center,
      children: [
        ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8), child: grid),
        Tappable(
          onTap: onReveal,
          behavior: HitTestBehavior.opaque,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: BrandColors.inverseSurface,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.visibility_off_outlined,
                  color: BrandColors.onPrimary,
                  size: 24,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                decoration: BoxDecoration(
                  color: BrandColors.inverseSurface,
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Text(
                  revealLabel,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: BrandColors.onPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SeedCell extends StatelessWidget {
  final int index;
  final String word;
  const _SeedCell({required this.index, required this.word});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: BrandColors.surfaceSunken,
        border: Border.all(color: BrandColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text(
            index.toString().padLeft(2, '0'),
            style: TextStyle(fontFamily: 'Ubuntu Mono', fontSize: 12, color: BrandColors.inkFaint),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              word,
              style: TextStyle(
                fontFamily: 'Ubuntu',
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: BrandColors.ink,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _BirthdayCard extends StatelessWidget {
  final String label;
  final String reason;
  final String value;
  const _BirthdayCard({required this.label, required this.reason, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: BrandColors.card,
        border: Border.all(color: BrandColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Ubuntu',
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: BrandColors.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  reason,
                  style: TextStyle(fontFamily: 'Ubuntu', fontSize: 12.5, color: BrandColors.inkMuted),
                ),
              ],
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'Ubuntu',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: BrandColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}
