import 'package:flutter/material.dart';

import '../design/brand.dart';

/// The raised card every home section sits in: card fill, hairline border,
/// the large card radius and 16 padding, with its children spaced 12 apart.
class HomeCard extends StatelessWidget {
  final List<Widget> children;

  const HomeCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BrandColors.card,
        border: Border.all(color: BrandColors.border),
        borderRadius: BrandRadii.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: children,
      ),
    );
  }
}

/// A card's title row: a small coloured icon, the title, and an optional
/// trailing note (a count or a change) on the right.
class HomeCardTitle extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final Widget? trailing;

  const HomeCardTitle({
    super.key,
    required this.icon,
    required this.title,
    this.iconColor,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: iconColor ?? BrandColors.primaryDeep),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: BrandColors.ink),
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// A thin rounded progress track, [value] in 0..1.
class HomeProgressBar extends StatelessWidget {
  final double value;
  final Color color;
  final double height;

  const HomeProgressBar({super.key, required this.value, required this.color, this.height = 4});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BrandRadii.rPill,
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: BrandColors.surfaceTinted),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: value.clamp(0.0, 1.0),
              child: ColoredBox(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mono caption style used for counts, dates and changes inside home cards.
TextStyle get homeMonoCaption => TextStyle(
  fontFamily: 'Ubuntu Mono',
  fontSize: 13,
  height: 1.2,
  color: BrandColors.inkMuted,
  fontFeatures: const [FontFeature.tabularFigures()],
);
