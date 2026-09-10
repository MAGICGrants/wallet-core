import 'package:flutter/material.dart';

import 'brand.dart';
import 'section_header.dart';

/// A titled settings group: an uppercase section label above a white card whose
/// rows are separated by hairlines (see design `brand/screens`).
class SettingsGroup extends StatelessWidget {
  final String? label;
  final List<Widget> tiles;

  const SettingsGroup({super.key, this.label, required this.tiles});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          SectionHeader(label: label!, padding: const EdgeInsets.only(left: 4, bottom: 9)),
        Material(
          color: BrandColors.card,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            side: BorderSide(color: BrandColors.border),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i != 0) Divider(height: 1, thickness: 1, color: BrandColors.surfaceTinted),
                tiles[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

TextStyle get _titleStyle => TextStyle(fontSize: 14.5, height: 1.3, color: BrandColors.ink);
TextStyle get _descStyle => TextStyle(fontSize: 11.5, height: 1.4, color: BrandColors.inkMuted);

/// Row that navigates, showing an optional current value + a chevron.
class SettingsNavTile extends StatelessWidget {
  final String title;
  final String? value;
  final bool valueMono;
  final VoidCallback onTap;

  const SettingsNavTile({
    super.key,
    required this.title,
    required this.onTap,
    this.value,
    this.valueMono = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
        child: Row(
          children: [
            // Title takes its intrinsic width; the value fills the rest and
            // right-aligns so it (and the chevron) sit flush at the edge.
            Text(title, style: _titleStyle),
            if (value != null)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    value!,
                    textAlign: TextAlign.end,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: valueMono ? 'Ubuntu Mono' : 'Ubuntu',
                      fontSize: 13.5,
                      color: BrandColors.inkMuted,
                    ),
                  ),
                ),
              )
            else
              const Spacer(),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 18, color: BrandColors.inkMuted),
          ],
        ),
      ),
    );
  }
}

/// Row with a primary "View"-style link on the right. The title stays ink;
/// only the link label is coloured. Set [titleColor] for destructive rows.
class SettingsLinkTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String? linkLabel;
  final VoidCallback onTap;
  final Color? color;
  final Color? titleColor;

  const SettingsLinkTile({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.linkLabel,
    this.color,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: _titleStyle.copyWith(color: titleColor)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 3),
                    Text(subtitle!, style: _descStyle),
                  ],
                ],
              ),
            ),
            if (linkLabel != null) ...[
              const SizedBox(width: 12),
              Text(
                linkLabel!,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: color ?? BrandColors.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Row with a title (+ optional description) and a brand toggle.
class SettingsToggleTile extends StatelessWidget {
  final String title;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// False until the initial (async) preference load settles, so the switch
  /// snaps to its stored position instead of animating on screen entry.
  final bool animate;

  const SettingsToggleTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.description,
    this.animate = true,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: _titleStyle),
                  if (description != null) ...[
                    const SizedBox(height: 4),
                    Text(description!, style: _descStyle),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            BrandSwitch(value: value, onChanged: onChanged, animate: animate),
          ],
        ),
      ),
    );
  }
}

/// Pill toggle — primary when on, matching the design switches.
class BrandSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool animate;

  const BrandSwitch({super.key, required this.value, required this.onChanged, this.animate = true});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: animate ? BrandMotion.transition : Duration.zero,
        width: 46,
        height: 28,
        padding: const EdgeInsets.all(3),
        alignment: value ? Alignment.centerRight : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: value ? BrandColors.primaryDeep : BrandColors.borderStrong,
          borderRadius: BorderRadius.circular(100),
        ),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: BrandColors.paper, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
