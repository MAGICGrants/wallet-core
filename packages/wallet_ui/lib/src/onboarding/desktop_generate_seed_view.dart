import 'dart:math' show max;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/click_cursor.dart';
import 'onboarding_scaffold.dart';

/// Desktop generate-seed onboarding step: the two-pane [DesktopOnboardingScaffold]
/// with a seed grid of up to 3 columns behind a tap-to-reveal gate, the wallet birthday,
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

  /// Footnote that the password guards the seed from here on; null where the
  /// wallet has no typed password, as on the iOS build running on a Mac.
  final String? passwordNote;
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
    final passwordNote = widget.passwordNote;
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
      notes: [if (passwordNote != null) OnboardingNote(Icons.lock_outline, passwordNote)],
      content: ListView(
        padding: EdgeInsets.zero,
        children: [
          _SeedGate(
            revealed: _revealed,
            revealLabel: widget.revealLabel,
            onReveal: () => setState(() => _revealed = true),
            grid: _SeedWords(words: widget.seedWords),
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

/// The numbered seed words, up to three to a row.
///
/// This is the screen the user copies the seed from, so every word is shown in
/// full. The grid uses fewer columns when the widest word would not fit on one
/// line at this width and text size, and a word too wide even for one column
/// wraps. Rows grow to fit their words.
class _SeedWords extends StatelessWidget {
  final List<String> words;
  const _SeedWords({required this.words});

  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = _columns(context, constraints.maxWidth);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var start = 0; start < words.length; start += columns) ...[
              if (start > 0) const SizedBox(height: _gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = start; i < start + columns; i++) ...[
                      if (i > start) const SizedBox(width: _gap),
                      // An empty slot keeps a short last row on the grid.
                      Expanded(
                        child: i < words.length
                            ? _SeedCell(index: i + 1, word: words[i])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// The most columns, up to three, that give every word a single line.
  int _columns(BuildContext context, double width) {
    final widest = words.fold(
      0.0,
      (widest, word) => max(widest, _SeedCell.wordWidth(context, word)),
    );
    // A pixel of slack, so rounding cannot push a word that just fits onto two lines.
    final needed = _SeedCell.chromeWidth(context) + widest + 1;
    var columns = 3;
    while (columns > 1 && (width - _gap * (columns - 1)) / columns < needed) {
      columns--;
    }
    return columns;
  }
}

class _SeedCell extends StatelessWidget {
  final int index;
  final String word;
  const _SeedCell({required this.index, required this.word});

  static const _padding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);
  static const double _borderWidth = 1;
  static const double _numberGap = 10;
  static const _numberStyle = TextStyle(fontFamily: 'Ubuntu Mono', fontSize: 12);
  static const _wordStyle = TextStyle(
    fontFamily: 'Ubuntu',
    fontSize: 14,
    fontWeight: FontWeight.w500,
  );

  /// The width [word] takes on one line of a cell.
  static double wordWidth(BuildContext context, String word) =>
      _textWidth(context, word, _wordStyle);

  /// A cell's width other than its word: padding, border, number and gap.
  static double chromeWidth(BuildContext context) =>
      _padding.horizontal + 2 * _borderWidth + _textWidth(context, '00', _numberStyle) + _numberGap;

  /// The width [text] takes on one line, styled and scaled as a [Text] here
  /// would lay it out.
  static double _textWidth(BuildContext context, String text, TextStyle style) {
    var effective = DefaultTextStyle.of(context).style.merge(style);
    if (MediaQuery.boldTextOf(context)) {
      effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: effective),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout();
    final width = painter.maxIntrinsicWidth;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: _padding,
      decoration: BoxDecoration(
        color: BrandColors.surfaceSunken,
        border: Border.all(color: BrandColors.border, width: _borderWidth),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Text(
            index.toString().padLeft(2, '0'),
            style: _numberStyle.copyWith(color: BrandColors.inkFaint),
          ),
          const SizedBox(width: _numberGap),
          // No ellipsis: a word that does not fit wraps, and is read in full.
          Expanded(
            child: Text(word, style: _wordStyle.copyWith(color: BrandColors.ink)),
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
                  style: TextStyle(
                    fontFamily: 'Ubuntu',
                    fontSize: 12.5,
                    color: BrandColors.inkMuted,
                  ),
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
