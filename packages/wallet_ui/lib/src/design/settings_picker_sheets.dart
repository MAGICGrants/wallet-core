import 'package:flutter/material.dart';

import 'brand.dart';
import 'brand_button.dart';
import 'mode_select_card.dart';
import 'radio_dot.dart';
import 'sheet.dart';

/// Chrome strings for the theme/language picker sheets, injected so the views
/// stay localization-agnostic (each app passes its own generated l10n).
class SettingsPickerLabels {
  final String title;
  final String subtitle;
  final String done;

  const SettingsPickerLabels({required this.title, required this.subtitle, required this.done});
}

/// Builds a sheet's chrome strings from the sheet's own [BuildContext].
///
/// A builder, not a value: the language picker changes the app's locale while
/// it is still on screen, and strings snapshotted before `show` would leave the
/// sheet stranded in the language the user just switched away from. Resolving
/// them against the sheet's context registers the dependency on `Localizations`
/// that makes the sheet follow the change.
typedef SettingsPickerLabelsBuilder = SettingsPickerLabels Function(BuildContext context);

/// Colours for a theme option's 38×38 preview tile. Per-app, since each app's
/// light/dark grounds differ (and a swatch must show its own theme regardless of
/// the theme currently in effect).
class ThemeSwatchSpec {
  final Color? ground;
  final Gradient? gradient;
  final Color barColor;
  final Color accentColor;

  const ThemeSwatchSpec({
    this.ground,
    this.gradient,
    required this.barColor,
    required this.accentColor,
  });
}

/// One selectable theme (value + label + description + preview swatch).
class ThemePickerOption {
  final String value;
  final String label;
  final String description;
  final ThemeSwatchSpec swatch;

  const ThemePickerOption({
    required this.value,
    required this.label,
    required this.description,
    required this.swatch,
  });
}

/// One selectable language (locale code + native and English display names).
class LanguagePickerOption {
  final String code;
  final String native;
  final String english;

  const LanguagePickerOption({required this.code, required this.native, required this.english});
}

/// Theme picker sheet — Light / Dark / System as [ModeSelectCard]s with a mini
/// preview swatch. Applies immediately via [onSelect]; the check follows the tap
/// locally so the sheet needn't watch the app's theme model. Done just closes.
Future<void> showThemePickerSheet(
  BuildContext context, {
  required SettingsPickerLabels labels,
  required List<ThemePickerOption> options,
  required String selected,
  required ValueChanged<String> onSelect,
  Color? iconBg,
  Color? iconColor,
}) {
  return showBrandSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ThemePickerSheet(
      labels: labels,
      options: options,
      selected: selected,
      onSelect: onSelect,
      iconBg: iconBg,
      iconColor: iconColor,
    ),
  );
}

/// Language picker sheet — the supported locales as native + English name rows
/// with a [RadioDot]. Applies immediately via [onSelect]. Done just closes.
///
/// [labels] is rebuilt against the sheet's context so the sheet re-renders in
/// the language the user just picked; the option names are deliberately not
/// localized (each locale is listed in its own language, plus English).
Future<void> showLanguagePickerSheet(
  BuildContext context, {
  required SettingsPickerLabelsBuilder labels,
  required List<LanguagePickerOption> options,
  required String selected,
  required ValueChanged<String> onSelect,
  Color? iconBg,
  Color? iconColor,
}) {
  return showBrandSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _LanguagePickerSheet(
      labels: labels,
      options: options,
      selected: selected,
      onSelect: onSelect,
      iconBg: iconBg,
      iconColor: iconColor,
    ),
  );
}

class _ThemePickerSheet extends StatefulWidget {
  final SettingsPickerLabels labels;
  final List<ThemePickerOption> options;
  final String selected;
  final ValueChanged<String> onSelect;
  final Color? iconBg;
  final Color? iconColor;

  const _ThemePickerSheet({
    required this.labels,
    required this.options,
    required this.selected,
    required this.onSelect,
    this.iconBg,
    this.iconColor,
  });

  @override
  State<_ThemePickerSheet> createState() => _ThemePickerSheetState();
}

class _ThemePickerSheetState extends State<_ThemePickerSheet> {
  late String _selected = widget.selected;

  @override
  Widget build(BuildContext context) {
    return _PickerSheet(
      icon: Icons.wb_sunny_outlined,
      labels: widget.labels,
      iconBg: widget.iconBg,
      iconColor: widget.iconColor,
      children: [
        for (final option in widget.options) ...[
          ModeSelectCard(
            title: option.label,
            description: option.description,
            selected: _selected == option.value,
            leading: _ThemeSwatch(spec: option.swatch),
            onTap: () {
              widget.onSelect(option.value);
              setState(() => _selected = option.value);
            },
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// The 38×38 rounded preview tile — ground colour + two bars hinting at text.
class _ThemeSwatch extends StatelessWidget {
  final ThemeSwatchSpec spec;

  const _ThemeSwatch({required this.spec});

  static const _r = BorderRadius.all(Radius.circular(2));

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: spec.ground,
        gradient: spec.gradient,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: BrandColors.borderStrong),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 4,
            decoration: BoxDecoration(color: spec.barColor, borderRadius: _r),
          ),
          const SizedBox(height: 4),
          FractionallySizedBox(
            widthFactor: 0.6,
            child: Container(
              height: 4,
              decoration: BoxDecoration(color: spec.accentColor, borderRadius: _r),
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguagePickerSheet extends StatefulWidget {
  final SettingsPickerLabelsBuilder labels;
  final List<LanguagePickerOption> options;
  final String selected;
  final ValueChanged<String> onSelect;
  final Color? iconBg;
  final Color? iconColor;

  const _LanguagePickerSheet({
    required this.labels,
    required this.options,
    required this.selected,
    required this.onSelect,
    this.iconBg,
    this.iconColor,
  });

  @override
  State<_LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends State<_LanguagePickerSheet> {
  late String _selected = widget.selected;

  @override
  Widget build(BuildContext context) {
    return _PickerSheet(
      icon: Icons.language,
      // Resolved here, in the sheet's own build, so switching the locale
      // rebuilds this sheet's title, subtitle and Done button with it.
      labels: widget.labels(context),
      iconBg: widget.iconBg,
      iconColor: widget.iconColor,
      children: [
        for (final option in widget.options)
          _LanguageRow(
            native: option.native,
            english: option.english,
            selected: _selected == option.code,
            onTap: () {
              widget.onSelect(option.code);
              setState(() => _selected = option.code);
            },
          ),
      ],
    );
  }
}

class _LanguageRow extends StatelessWidget {
  final String native;
  final String english;
  final bool selected;
  final VoidCallback onTap;

  const _LanguageRow({
    required this.native,
    required this.english,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: BrandColors.surfaceTinted)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    native,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                      color: BrandColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(english, style: BrandText.caption.copyWith(fontSize: 12.5)),
                ],
              ),
            ),
            const SizedBox(width: 13),
            RadioDot(selected: selected),
          ],
        ),
      ),
    );
  }
}

/// Shared chrome for the theme/language sheets: handle, icon tile + title +
/// subtitle, a scrollable body, and a Done button.
class _PickerSheet extends StatelessWidget {
  final IconData icon;
  final SettingsPickerLabels labels;
  final List<Widget> children;
  final Color? iconBg;
  final Color? iconColor;

  const _PickerSheet({
    required this.icon,
    required this.labels,
    required this.children,
    this.iconBg,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.82),
        child: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SheetIcon(
                          icon: icon,
                          bg: iconBg ?? BrandColors.surfaceAccent,
                          color: iconColor ?? BrandColors.primary,
                        ),
                        const SizedBox(width: 11),
                        Expanded(child: Text(labels.title, style: BrandText.sheetTitle)),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      labels.subtitle,
                      style: BrandText.bodyMuted.copyWith(fontSize: 13, height: 1.5),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
                child: BrandButton(
                  label: labels.done,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
