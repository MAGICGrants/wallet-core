import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_card.dart';
import '../design/sheet.dart';
import 'coin_mark.dart';

/// Translated strings for the contact picker sheet. Injected so the sheet stays
/// localization-agnostic — each app passes its own generated l10n.
class ContactPickerLabels {
  final String title;

  /// Sub-line under the title (Spice describes the chain); null omits it
  /// (Skylight).
  final String? subtitle;
  final String searchHint;
  final String cancel;

  /// Shown when there are no contacts at all (empty query).
  final String noContacts;

  /// Shown when a non-empty search matches nothing.
  final String noResults;

  const ContactPickerLabels({
    required this.title,
    required this.searchHint,
    required this.cancel,
    required this.noContacts,
    required this.noResults,
    this.subtitle,
  });
}

/// One row in the contact picker. Presentational: the app maps its own contact
/// model to these. Selectable rows return their [value] from the sheet.
class ContactPickerEntry<T> {
  final T value;
  final String name;

  /// The address to show, already shortened. Null means the contact has no
  /// usable address on this chain — the row is greyed out and unselectable,
  /// showing [disabledReason] instead.
  final String? addressShort;

  /// Why the row is disabled (e.g. "No Ethereum address"). Rendered in place of
  /// the address when [addressShort] is null.
  final String? disabledReason;

  /// Optional coin badge shown before the address (Spice's per-chain mark).
  final String? badgeCoinSymbol;
  final String badgeIconAsset;

  const ContactPickerEntry({
    required this.value,
    required this.name,
    this.addressShort,
    this.disabledReason,
    this.badgeCoinSymbol,
    this.badgeIconAsset = '',
  });

  bool get enabled => addressShort != null;
}

/// Opens the contact picker as a brand bottom sheet, resolving to the chosen
/// entry's [value] (or null on dismiss/cancel).
///
/// Presentational only — [search] runs the app's own contact lookup for the
/// current query and returns the rows to show (already ordered as the app
/// wants, e.g. selectable-first). The sheet owns the search field + its
/// stable-height layout.
///
/// [headerIcon] is drawn beside the title (Spice: a [CoinMark]; Skylight: its
/// Monero glyph).
Future<T?> showContactPickerSheet<T>({
  required BuildContext context,
  required ContactPickerLabels labels,
  required Widget headerIcon,
  required List<ContactPickerEntry<T>> Function(String query) search,
}) {
  return showBrandSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ContactPickerSheet<T>(labels: labels, headerIcon: headerIcon, search: search),
  );
}

class _ContactPickerSheet<T> extends StatefulWidget {
  final ContactPickerLabels labels;
  final Widget headerIcon;
  final List<ContactPickerEntry<T>> Function(String query) search;

  const _ContactPickerSheet({required this.labels, required this.headerIcon, required this.search});

  @override
  State<_ContactPickerSheet<T>> createState() => _ContactPickerSheetState<T>();
}

class _ContactPickerSheetState<T> extends State<_ContactPickerSheet<T>> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    final mq = MediaQuery.of(context);
    // Fixed height so filtering the results — or getting none — never shrinks the
    // sheet. Capped to the space above the keyboard, and below the status bar
    // (viewPadding.top, since padding.top reads 0 inside a modal sheet).
    final available = mq.size.height - mq.viewInsets.bottom - mq.viewPadding.top - 40;
    final height = math.min(mq.size.height * 0.72, available);

    final results = widget.search(_query);

    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(
              mainAxisSize: MainAxisSize.max,
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
                          widget.headerIcon,
                          const SizedBox(width: 11),
                          Expanded(child: Text(labels.title, style: BrandText.sheetTitle)),
                        ],
                      ),
                      if (labels.subtitle != null) ...[
                        const SizedBox(height: 7),
                        Text(
                          labels.subtitle!,
                          style: BrandText.bodyMuted.copyWith(fontSize: 13, height: 1.5),
                        ),
                      ],
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 0, 22, 14),
                  child: BrandCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Icon(Icons.search, size: 18, color: BrandColors.inkFaint),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            onChanged: (q) => setState(() => _query = q),
                            textInputAction: TextInputAction.search,
                            style: TextStyle(fontSize: 13.5, color: BrandColors.ink),
                            decoration: InputDecoration(
                              isCollapsed: true,
                              contentPadding: const EdgeInsets.symmetric(vertical: 14),
                              border: InputBorder.none,
                              hintText: labels.searchHint,
                              hintStyle: TextStyle(fontSize: 13.5, color: BrandColors.inkFaint),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: results.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
                            child: Text(
                              _query.isEmpty ? labels.noContacts : labels.noResults,
                              style: BrandText.bodyMuted.copyWith(fontSize: 13),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          itemCount: results.length,
                          itemBuilder: (context, index) => _ContactPickRow<T>(
                            entry: results[index],
                            onTap: () => Navigator.of(context).pop(results[index].value),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 8),
                  child: BrandButton.ghost(
                    label: labels.cancel,
                    color: BrandColors.inkMuted,
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One contact in the picker. Selectable when it has an address; otherwise
/// greyed out, showing its disabled reason.
class _ContactPickRow<T> extends StatelessWidget {
  final ContactPickerEntry<T> entry;
  final VoidCallback onTap;

  const _ContactPickRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = entry.enabled;
    final initial = entry.name.isNotEmpty ? entry.name[0].toUpperCase() : '?';

    final row = Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: BrandColors.surfaceTinted)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: enabled ? BrandColors.primaryDeep : BrandColors.inkDisabled,
            ),
            child: Text(
              initial,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: BrandColors.onPrimary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.name,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    color: BrandColors.ink,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    if (entry.badgeCoinSymbol != null) ...[
                      CoinMark(
                        coinSymbol: entry.badgeCoinSymbol!,
                        iconAsset: entry.badgeIconAsset,
                        size: 18,
                      ),
                      const SizedBox(width: 7),
                    ],
                    Flexible(
                      child: Text(
                        enabled ? entry.addressShort! : (entry.disabledReason ?? ''),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: enabled ? 'Ubuntu Mono' : null,
                          fontSize: 11,
                          color: BrandColors.inkMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (enabled) ...[
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 20, color: BrandColors.inkDisabled),
          ],
        ],
      ),
    );

    if (!enabled) return Opacity(opacity: 0.45, child: row);
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: row);
  }
}
