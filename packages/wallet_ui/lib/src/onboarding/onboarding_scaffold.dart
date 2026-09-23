import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/click_cursor.dart';

/// A footnote row in the dark left pane: small accent icon + muted line.
class OnboardingNote {
  final IconData icon;
  final String text;
  const OnboardingNote(this.icon, this.text);
}

/// Shared two-pane desktop onboarding layout: a dark explainer pane ([logo],
/// title, description, footnotes) on the left, and a stepped content pane
/// (Step N of M + progress dots, [content], Back/Continue) on the right.
/// Colours are the installed palette's tokens, so each app gets its own scheme;
/// [logo] is the app's mark (passed in, since it differs per app).
class DesktopOnboardingScaffold extends StatelessWidget {
  final Widget logo;
  final String title;
  final String description;
  final List<OnboardingNote> notes;
  final int step; // 1-based
  final int totalSteps;
  final Widget content;
  final VoidCallback? onBack;
  final VoidCallback? onContinue;
  final String backLabel;
  final String continueLabel;
  final bool continueEnabled;
  final bool loading;

  /// Hide the built-in Continue button when the [content] supplies its own
  /// primary action (e.g. a connection form with its own Save button).
  final bool showContinue;

  const DesktopOnboardingScaffold({
    super.key,
    required this.logo,
    required this.title,
    required this.description,
    required this.step,
    required this.totalSteps,
    required this.content,
    required this.continueLabel,
    this.notes = const [],
    this.onBack,
    this.onContinue,
    this.backLabel = 'Back',
    this.continueEnabled = true,
    this.loading = false,
    this.showContinue = true,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrandColors.paper,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The explainer pane is a Hero (like the app's desktop sidebar), so it
          // stays fixed across step transitions — only the right content animates.
          // The pane never moves; its copy cross-fades between steps (the default
          // flight swaps it abruptly at flight start, which reads as a flicker).
          //
          // No placeholderBuilder: it repaints the departing copy inside the
          // outgoing route, which the page transition is zooming/fading, so that
          // moving layer peeks past the shuttle. The opaque shuttle covers the
          // pane's slot for the whole flight, so nothing else needs to paint it.
          Hero(
            tag: 'onboarding-sidebar',
            flightShuttleBuilder: (flightContext, animation, direction, fromContext, toContext) {
              final fromChild = (fromContext.widget as Hero).child;
              final toChild = (toContext.widget as Hero).child;
              return AnimatedBuilder(
                animation: animation,
                builder: (context, _) {
                  // A pop runs the flight animation in reverse (1→0); normalise to
                  // 0→1 (from → to) so the fade goes the right way in both directions.
                  final t =
                      (direction == HeroFlightDirection.push
                              ? animation.value
                              : 1 - animation.value)
                          .clamp(0.0, 1.0);
                  return Stack(
                    fit: StackFit.passthrough,
                    children: [
                      // Opaque base so the pane never turns translucent mid-fade
                      // (both fading copies carry the ink fill; without this the
                      // sliding content would show through at ~50%).
                      Positioned.fill(child: ColoredBox(color: BrandColors.ink)),
                      Opacity(opacity: 1 - t, child: fromChild),
                      Opacity(opacity: t, child: toChild),
                    ],
                  );
                },
              );
            },
            child: _leftPane(),
          ),
          Expanded(child: _rightPane()),
        ],
      ),
    );
  }

  Widget _leftPane() {
    // Material so the copy styles correctly while lifted into the Hero overlay.
    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: 436,
        color: BrandColors.ink,
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 44),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            logo,
            const SizedBox(height: 30),
            Text(
              title,
              style: TextStyle(
                fontFamily: 'Ubuntu',
                fontSize: 30,
                height: 1.18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.36,
                color: BrandColors.surfaceTinted,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              description,
              style: TextStyle(
                fontFamily: 'Ubuntu',
                fontSize: 14,
                height: 1.7,
                color: BrandColors.inkDisabled,
              ),
            ),
            const Spacer(),
            for (final note in notes) ...[
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(note.icon, size: 17, color: BrandColors.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        note.text,
                        style: TextStyle(
                          fontFamily: 'Ubuntu',
                          fontSize: 13,
                          height: 1.6,
                          color: BrandColors.frameEdge,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The content + actions block grows with the window so the actions sit near
  /// the bottom, but only up to this height — past it (a maximized window on a
  /// large display) the block stays top-anchored so the actions don't strand far
  /// below the content.
  static const _contentMaxHeight = 860.0;

  Widget _rightPane() {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: _contentMaxHeight),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 64, vertical: 56),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _stepRow(),
              const SizedBox(height: 30),
              Expanded(child: content),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (onBack != null)
                    BrandButton(
                      label: backLabel,
                      onPressed: onBack,
                      variant: BrandButtonVariant.ghost,
                      expand: false,
                    ),
                  const Spacer(),
                  if (showContinue)
                    SizedBox(
                      width: 200,
                      child: BrandButton(
                        label: continueLabel,
                        loading: loading,
                        onPressed: continueEnabled ? onContinue : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepRow() {
    return Row(
      children: [
        Text(
          'Step $step of $totalSteps',
          style: TextStyle(
            fontFamily: 'Ubuntu Mono',
            fontSize: 10,
            height: 1,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            color: BrandColors.inkFaint,
          ),
        ),
        const SizedBox(width: 14),
        for (var i = 0; i < totalSteps; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: i == step - 1 ? 20 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == step - 1 ? BrandColors.primary : BrandColors.borderStrong,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
      ],
    );
  }
}

/// A selectable option card used by the onboarding choice screens (Tor, price
/// display, wallet setup): radio + accent icon + title + description.
class OnboardingRadioCard extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  final Widget? trailing;

  const OnboardingRadioCard({
    super.key,
    required this.selected,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final accent = selected ? BrandColors.primary : BrandColors.inkFaint;
    return Tappable(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: selected ? BrandColors.surfaceSunken : BrandColors.card,
          border: Border.all(
            color: selected ? BrandColors.primary : BrandColors.border,
            width: selected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _Radio(selected: selected),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(icon, size: 16, color: accent),
                      const SizedBox(width: 9),
                      Text(
                        title,
                        style: TextStyle(
                          fontFamily: 'Ubuntu',
                          fontSize: 15,
                          height: 1.3,
                          fontWeight: FontWeight.w500,
                          color: BrandColors.ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    description,
                    style: TextStyle(
                      fontFamily: 'Ubuntu',
                      fontSize: 13,
                      height: 1.6,
                      color: BrandColors.inkMuted,
                    ),
                  ),
                  if (trailing != null) ...[const SizedBox(height: 14), trailing!],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Radio extends StatelessWidget {
  final bool selected;
  const _Radio({required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 19,
      height: 19,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: BrandColors.card,
        border: Border.all(
          color: selected ? BrandColors.primary : BrandColors.frameEdge,
          width: selected ? 5.5 : 1.5,
        ),
      ),
    );
  }
}
