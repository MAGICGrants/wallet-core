import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../design/brand.dart';
import '../design/click_cursor.dart';
import '../design/brand_button.dart';
import '../design/radio_dot.dart';
import '../design/sheet.dart';

/// Translated strings for [showScanFromSheet]. Injected so the sheet stays
/// localization-agnostic — each app passes its own generated l10n. Month names
/// are derived from [locale] via [DateFormat]; only the fixed labels come in.
class ScanFromSheetLabels {
  final String title;
  final String description;
  final String pickMonth;
  final String notSure;
  final String notSureDesc;
  final String done;
  final String locale;

  const ScanFromSheetLabels({
    required this.title,
    required this.description,
    required this.pickMonth,
    required this.notSure,
    required this.notSureDesc,
    required this.done,
    required this.locale,
  });
}

/// A tappable restore-point card: a label + reason on the left, a formatted
/// value + chevron on the right, on a sunken surface. Presentational — the app
/// supplies the strings, the value's [valueStyle] and the [onTap] that opens
/// [showScanFromSheet].
class ScanFromCard extends StatelessWidget {
  final String label;
  final String reason;
  final String value;
  final TextStyle valueStyle;
  final VoidCallback onTap;

  const ScanFromCard({
    super.key,
    required this.label,
    required this.reason,
    required this.value,
    required this.valueStyle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const radius = BrandRadii.rField;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: BrandColors.surfaceSunken,
        borderRadius: radius,
        border: Border.all(color: BrandColors.border),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 15),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: BrandText.listTitle),
                        const SizedBox(height: 2),
                        Text(reason, style: BrandText.caption),
                      ],
                    ),
                  ),
                  const SizedBox(width: BrandSpacing.md),
                  Text(value, style: valueStyle),
                  const SizedBox(width: BrandSpacing.xs),
                  Icon(Icons.chevron_right, size: 18, color: BrandColors.inkFaint),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet for the restore point — pick a month/year, or "I'm not sure"
/// (scan from genesis). Returns the chosen [DateTime] on Done (null = "not
/// sure"), or null if the sheet was dismissed. Presentational: strings injected
/// via [labels].
Future<({DateTime? date})?> showScanFromSheet({
  required BuildContext context,
  required DateTime? initial,
  required ScanFromSheetLabels labels,
  bool chosen = false,
}) {
  return showBrandSheet<({DateTime? date})>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ScanFromSheet(initial: initial, labels: labels, chosen: chosen),
  );
}

class _ScanFromSheet extends StatefulWidget {
  final DateTime? initial;
  final ScanFromSheetLabels labels;

  /// Whether a restore point was already picked — with a null [initial], reopens
  /// on "I'm not sure" rather than the month picker.
  final bool chosen;

  const _ScanFromSheet({required this.initial, required this.labels, required this.chosen});

  @override
  State<_ScanFromSheet> createState() => _ScanFromSheetState();
}

class _ScanFromSheetState extends State<_ScanFromSheet> {
  late bool _pickMonth;
  late int _month;
  late int _year;

  @override
  void initState() {
    super.initState();
    _pickMonth = !(widget.chosen && widget.initial == null);
    final d = widget.initial ?? DateTime.now();
    _month = d.month;
    _year = d.year;
  }

  void _done() {
    Navigator.pop(context, (date: _pickMonth ? DateTime(_year, _month) : null));
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    final locale = labels.locale;
    final now = DateTime.now();
    // Desktop: centered modal card (no drag handle; the card owns the padding).
    final desktop = isDesktopModal;

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!desktop) const SheetHandle(),
        Text(labels.title, style: BrandText.sheetTitle),
        const SizedBox(height: BrandSpacing.sm),
        Text(labels.description, style: BrandText.bodyMuted),
        const SizedBox(height: BrandSpacing.lg),
        _SheetOption(
          selected: _pickMonth,
          title: labels.pickMonth,
          onTap: () => setState(() => _pickMonth = true),
          expanded: Row(
            children: [
              Expanded(
                child: _ScanDropdown<int>(
                  value: _month,
                  items: [for (var m = 1; m <= 12; m++) m],
                  label: (m) => DateFormat.MMMM(locale).format(DateTime(2000, m)),
                  onChanged: (m) => setState(() => _month = m),
                ),
              ),
              const SizedBox(width: BrandSpacing.sm),
              Expanded(
                child: _ScanDropdown<int>(
                  value: _year,
                  items: [for (var y = now.year; y >= 2014; y--) y],
                  label: (y) => '$y',
                  onChanged: (y) => setState(() => _year = y),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: BrandSpacing.md),
        _SheetOption(
          selected: !_pickMonth,
          title: labels.notSure,
          description: labels.notSureDesc,
          onTap: () => setState(() => _pickMonth = false),
        ),
        const SizedBox(height: BrandSpacing.lg),
        if (desktop)
          Align(
            alignment: Alignment.centerRight,
            child: BrandButton(label: labels.done, expand: false, onPressed: _done),
          )
        else
          BrandButton(label: labels.done, onPressed: _done),
      ],
    );

    // The dialog wrapper supplies the padded surface; the sheet needs its own.
    if (desktop) return content;

    // No keyboard padding here: showBrandSheet applies it once for the whole
    // sheet, and a second one lifts this clear off the keyboard.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          BrandSpacing.xl,
          BrandSpacing.md,
          BrandSpacing.xl,
          BrandSpacing.lg,
        ),
        child: content,
      ),
    );
  }
}

/// A radio card in the scan-from sheet (radio on the left), expanding when
/// selected.
class _SheetOption extends StatelessWidget {
  final bool selected;
  final String title;
  final String? description;
  final Widget? expanded;
  final VoidCallback onTap;

  const _SheetOption({
    required this.selected,
    required this.title,
    this.description,
    this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tappable(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: BrandMotion.transition,
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? BrandColors.card : BrandColors.surfaceSunken,
          borderRadius: BrandRadii.rField,
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BrandRadii.rField,
          border: Border.all(
            color: selected ? BrandColors.primary : BrandColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                RadioDot(selected: selected),
                const SizedBox(width: BrandSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: BrandText.listTitle),
                      if (description != null) ...[
                        const SizedBox(height: 2),
                        Text(description!, style: BrandText.caption),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (selected && expanded != null) ...[const SizedBox(height: 12), expanded!],
          ],
        ),
      ),
    );
  }
}

/// Tinted select used inside the scan-from sheet.
class _ScanDropdown<T> extends StatelessWidget {
  final T value;
  final List<T> items;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  const _ScanDropdown({
    required this.value,
    required this.items,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(
        color: BrandColors.surfaceSunken,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrandColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          icon: Icon(Icons.keyboard_arrow_down, color: BrandColors.inkFaint),
          borderRadius: BrandRadii.rField,
          dropdownColor: BrandColors.card,
          style: TextStyle(fontFamily: 'Ubuntu', fontSize: 14, color: BrandColors.ink),
          items: [for (final it in items) DropdownMenuItem<T>(value: it, child: Text(label(it)))],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}
