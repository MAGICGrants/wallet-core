import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_card.dart';
import '../design/brand_screen_header.dart';
import '../design/section_header.dart';

/// One labelled value in a [KeyRevealView] — an address, key, seed phrase or
/// height. [revealable] blurs the value behind a tap-to-reveal overlay (used
/// for secret keys / seeds).
class KeyRevealField {
  final String label;
  final String value;
  final bool revealable;

  const KeyRevealField({required this.label, required this.value, this.revealable = false});
}

/// A read-only screen of labelled value cards, each with a copy chip and an
/// optional blur-to-reveal — the shared style behind the LWS-keys and
/// secret-keys screens. Presentational: the view owns per-field reveal state;
/// the app supplies the values, [onCopy], and optionally [onBack] / a [footer].
class KeyRevealView extends StatefulWidget {
  final String title;
  final String? description;
  final List<KeyRevealField> fields;
  final String revealLabel;
  final String? warning;
  final Widget? headerIcon;
  final void Function(String value) onCopy;
  final VoidCallback? onBack;
  final Widget? footer;

  /// Onboarding shows the title big (below the header); settings shows it small
  /// in the header centre.
  final bool largeTitle;

  const KeyRevealView({
    super.key,
    required this.title,
    required this.fields,
    required this.revealLabel,
    required this.onCopy,
    this.description,
    this.warning,
    this.headerIcon,
    this.onBack,
    this.footer,
    this.largeTitle = false,
  });

  @override
  State<KeyRevealView> createState() => _KeyRevealViewState();
}

class _KeyRevealViewState extends State<KeyRevealView> {
  final _revealed = <int>{};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrandColors.paper,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: BrandScreenHeader(
                    onBack: widget.onBack,
                    center: widget.largeTitle
                        ? null
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (widget.headerIcon != null) ...[
                                widget.headerIcon!,
                                const SizedBox(width: 8),
                              ],
                              Text(widget.title, style: BrandText.appBar.copyWith(fontSize: 16)),
                            ],
                          ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.largeTitle)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                            child: Text(widget.title, style: BrandText.title),
                          ),
                        if (widget.description != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                            child: Text(
                              widget.description!,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.6,
                                color: BrandColors.inkMuted,
                              ),
                            ),
                          ),
                        for (var i = 0; i < widget.fields.length; i++)
                          _KeyField(
                            label: widget.fields[i].label,
                            value: widget.fields[i].value,
                            onCopy: () => widget.onCopy(widget.fields[i].value),
                            revealLabel: widget.revealLabel,
                            hidden: widget.fields[i].revealable && !_revealed.contains(i),
                            onReveal: widget.fields[i].revealable
                                ? () => setState(() => _revealed.add(i))
                                : null,
                          ),
                        if (widget.warning != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 26,
                                  height: 26,
                                  margin: const EdgeInsets.only(top: 1),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: BrandColors.inverseSurface,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    Icons.visibility_off_outlined,
                                    size: 14,
                                    color: BrandColors.onPrimary,
                                  ),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Text(
                                    widget.warning!,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      height: 1.5,
                                      color: BrandColors.inkMuted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (widget.footer != null)
                  Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 12), child: widget.footer!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled read-only value card with a copy chip. [hidden] blurs the value
/// behind a "tap to reveal" overlay.
class _KeyField extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onCopy;
  final bool hidden;
  final VoidCallback? onReveal;
  final String? revealLabel;

  const _KeyField({
    required this.label,
    required this.value,
    required this.onCopy,
    this.hidden = false,
    this.onReveal,
    this.revealLabel,
  });

  @override
  Widget build(BuildContext context) {
    final valueText = Text(
      value,
      style: TextStyle(
        fontFamily: 'Ubuntu Mono',
        fontSize: 12.5,
        height: 1.6,
        color: BrandColors.ink,
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(label: label, padding: const EdgeInsets.only(left: 4, bottom: 9)),
          BrandCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Stack(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: hidden
                          ? ImageFiltered(
                              imageFilter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                              child: valueText,
                            )
                          : valueText,
                    ),
                    const SizedBox(width: 11),
                    _CopyChip(onTap: onCopy),
                  ],
                ),
                if (hidden && onReveal != null)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onReveal,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
                          decoration: BoxDecoration(
                            color: BrandColors.inverseSurface,
                            borderRadius: BorderRadius.circular(100),
                          ),
                          child: Text(
                            revealLabel ?? '',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: BrandColors.onPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The 34×34 tan copy button used inside a key card.
class _CopyChip extends StatelessWidget {
  final VoidCallback onTap;

  const _CopyChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: BrandColors.surfaceSunken,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: BrandColors.border),
        ),
        child: Icon(Icons.copy_outlined, size: 15, color: BrandColors.primaryDeep),
      ),
    );
  }
}
