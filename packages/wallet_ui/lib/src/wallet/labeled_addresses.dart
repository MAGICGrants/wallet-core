import 'package:flutter/material.dart';
import 'package:wallet_domain/wallet_domain.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_card.dart';
import '../design/brand_text_field.dart';
import '../design/click_cursor.dart';
import '../design/radio_dot.dart';
import '../design/section_header.dart';
import '../design/sheet.dart';
import '../l10n/wallet_ui_localizations.dart';
import 'format.dart';
import 'time_ago.dart';

/// A used receive address and the label the user gave it, if any.
typedef LabeledAddress = ({UsedReceiveAddress used, String? label});

/// How the coin whose addresses these are writes amounts.
typedef LabeledAddressCoin = ({String coinSymbol, int baseUnitDecimals, RotatingAddressKind kind});

/// Decimals of a received total: enough to tell two totals apart, few enough
/// that 12 Monero decimals (or 8 Bitcoin ones) never crowd the label out.
const _totalDecimals = 4;

/// [units] of [coin] as a row's total ("4.2150 XMR").
String labeledAddressTotal(BigInt units, LabeledAddressCoin coin) => formatAmount(
  displayAmount(units, coin.baseUnitDecimals),
  _totalDecimals,
  symbol: coin.coinSymbol,
);

/// "Subaddress #12" or "Address #12": what an unlabeled address is called.
String labeledAddressName(WalletUiLocalizations strings, RotatingAddressKind kind, int index) =>
    strings.labeledAddressTitle(kind.name, index);

/// Receive's Labeled tab: every used address, most recently used first, each
/// with its total and transaction count, labeled ones under their label and
/// the rest with a Label button. Hide Unlabeled (off until tapped) narrows it
/// to the labeled ones.
///
/// [entries] null is still loading. Presentational: the app loads the
/// addresses and labels and handles [onOpen] (the address's own screen) and
/// [onLabel] (the label sheet).
class LabeledAddressList extends StatefulWidget {
  const LabeledAddressList({
    super.key,
    required this.strings,
    required this.coin,
    required this.entries,
    required this.onOpen,
    required this.onLabel,
    this.now,
  });

  final WalletUiLocalizations strings;
  final LabeledAddressCoin coin;
  final List<LabeledAddress>? entries;
  final ValueChanged<LabeledAddress> onOpen;
  final ValueChanged<LabeledAddress> onLabel;

  /// What "Last used" counts from; the clock when null.
  final DateTime? now;

  @override
  State<LabeledAddressList> createState() => _LabeledAddressListState();
}

class _LabeledAddressListState extends State<LabeledAddressList> {
  var _hideUnlabeled = false;

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final kind = widget.coin.kind.name;
    final entries = widget.entries;
    if (entries == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Center(child: CircularProgressIndicator(color: BrandColors.primary)),
      );
    }
    if (entries.isEmpty) return _empty(strings, kind);

    final shown = _hideUnlabeled ? entries.where((e) => e.label != null).toList() : entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            strings.labeledCaption,
            style: BrandText.bodyMuted.copyWith(fontSize: 13, height: 1.5),
          ),
        ),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: SectionHeader(
                  label: _hideUnlabeled
                      ? strings.labeledOnlyHeader(kind, shown.length)
                      : strings.labeledUsedHeader(kind, entries.length),
                  padding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(width: 12),
              _HideUnlabeledToggle(
                label: strings.labeledHideUnlabeled,
                on: _hideUnlabeled,
                onTap: () => setState(() => _hideUnlabeled = !_hideUnlabeled),
              ),
            ],
          ),
        ),
        if (shown.isNotEmpty)
          BrandCard(
            padding: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, thickness: 1, indent: 62, color: BrandColors.surfaceTinted),
                  _row(shown[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _row(LabeledAddress entry) {
    final strings = widget.strings;
    final used = entry.used;
    final label = entry.label;
    final total = labeledAddressTotal(used.receivedBaseUnits, widget.coin);
    final count = strings.labeledTransactionCount(used.txCount);
    if (label != null) {
      return Semantics(
        button: true,
        child: Tappable(
          onTap: () => widget.onOpen(entry),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              children: [
                const AddressLabelTile(),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BrandText.listTitle,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '#${used.index} · ${shortenMiddle(used.address, head: 6, tail: 6)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BrandText.mono.copyWith(fontSize: 12, color: BrandColors.inkMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _Total(total: total, count: count),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right, size: 18, color: BrandColors.inkFaint),
              ],
            ),
          ),
        ),
      );
    }
    final lastUsed = strings.labeledLastUsed(
      timeAgo(strings, DateTime.fromMillisecondsSinceEpoch(used.lastUsed * 1000), now: widget.now),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              child: Tappable(
                onTap: () => widget.onOpen(entry),
                child: Row(
                  children: [
                    AddressIndexTile(index: used.index),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            labeledAddressName(strings, widget.coin.kind, used.index),
                            style: BrandText.listTitle,
                          ),
                          const SizedBox(height: 3),
                          _AmountLine(total: total, count: count),
                          const SizedBox(height: 2),
                          Text(lastUsed, style: BrandText.caption),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          BrandButton.secondary(
            label: strings.labeledLabelButton,
            icon: Icons.add,
            dense: true,
            expand: false,
            onPressed: () => widget.onLabel(entry),
          ),
        ],
      ),
    );
  }

  Widget _empty(WalletUiLocalizations strings, String kind) => BrandCard(
    radius: 20,
    padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
    child: Column(
      children: [
        Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: BrandColors.surfaceAccent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(Icons.sell_outlined, size: 24, color: BrandColors.primaryDeep),
        ),
        const SizedBox(height: 16),
        Text(
          strings.labeledEmptyTitle(kind),
          textAlign: TextAlign.center,
          style: BrandText.listTitle.copyWith(fontSize: 17, height: 1.3),
        ),
        const SizedBox(height: 8),
        Text(
          strings.labeledEmptyBody(kind),
          style: BrandText.bodyMuted.copyWith(fontSize: 13, height: 1.5),
        ),
      ],
    ),
  );
}

/// A row's total and transaction count, right-aligned. It shrinks to fit
/// rather than squeezing the label: the total is capped at four decimals, but
/// a large one in a narrow window would still not fit.
class _Total extends StatelessWidget {
  const _Total({required this.total, required this.count});

  final String total;
  final String count;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 132),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(total, style: BrandText.amount.copyWith(fontSize: 13.5)),
            const SizedBox(height: 3),
            Text(count, style: BrandText.caption),
          ],
        ),
      ),
    );
  }
}

/// "0.2500 XMR · 1 transaction" under an unlabeled address.
class _AmountLine extends StatelessWidget {
  const _AmountLine({required this.total, required this.count});

  final String total;
  final String count;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: total, style: BrandText.mono.copyWith(fontSize: 12)),
            TextSpan(text: ' · $count'),
          ],
        ),
        style: BrandText.caption,
      ),
    );
  }
}

/// The pill beside the list's heading that hides unlabeled addresses.
class _HideUnlabeledToggle extends StatelessWidget {
  const _HideUnlabeledToggle({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: on,
      child: Tappable(
        onTap: onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.fromLTRB(10, 0, 12, 0),
          decoration: BoxDecoration(
            color: BrandColors.card,
            borderRadius: BrandRadii.rPill,
            border: Border.all(color: BrandColors.borderStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 16,
                height: 16,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: on ? BrandColors.primaryDeep : null,
                  borderRadius: BorderRadius.circular(5),
                  border: on ? null : Border.all(color: BrandColors.inputBorder, width: 1.5),
                ),
                child: on ? const Icon(Icons.check, size: 11, color: BrandColors.onPrimary) : null,
              ),
              const SizedBox(width: 7),
              Text(label, style: TextStyle(fontSize: 12.5, color: BrandColors.ink)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The tag tile in front of a labeled address.
class AddressLabelTile extends StatelessWidget {
  const AddressLabelTile({super.key, this.size = 36});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: BrandColors.surfaceAccent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(Icons.sell_outlined, size: size * 0.47, color: BrandColors.primaryDeep),
    );
  }
}

/// The index tile in front of an unlabeled address: the number alone, as the
/// row title beside it already says "Subaddress #9".
class AddressIndexTile extends StatelessWidget {
  const AddressIndexTile({super.key, required this.index, this.size = 36});

  final int index;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: BrandColors.surfaceSunken,
        borderRadius: BorderRadius.circular(12),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '$index',
            style: BrandText.mono.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: BrandColors.inkMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the sheet that labels [used]. Resolves to the label to save ('' when
/// the user cleared it, which removes it), or null when cancelled.
Future<String?> showAddressLabelSheet({
  required BuildContext context,
  required WalletUiLocalizations strings,
  required LabeledAddressCoin coin,
  required UsedReceiveAddress used,
  String? initialLabel,
  DateTime? now,
}) {
  return showBrandSheet<String>(
    context: context,
    isScrollControlled: true,
    maxWidth: 460,
    builder: (context) => _AddressLabelSheet(
      strings: strings,
      coin: coin,
      used: used,
      initialLabel: initialLabel,
      now: now,
    ),
  );
}

class _AddressLabelSheet extends StatefulWidget {
  const _AddressLabelSheet({
    required this.strings,
    required this.coin,
    required this.used,
    required this.initialLabel,
    required this.now,
  });

  final WalletUiLocalizations strings;
  final LabeledAddressCoin coin;
  final UsedReceiveAddress used;
  final String? initialLabel;
  final DateTime? now;

  @override
  State<_AddressLabelSheet> createState() => _AddressLabelSheetState();
}

class _AddressLabelSheetState extends State<_AddressLabelSheet> {
  late final _controller = TextEditingController(text: widget.initialLabel ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final strings = widget.strings;
    final used = widget.used;
    // Desktop modal: the card owns the edge padding.
    final hpad = isDesktopModal ? 0.0 : 22.0;
    final lastUsed = strings.labeledLastUsed(
      timeAgo(strings, DateTime.fromMillisecondsSinceEpoch(used.lastUsed * 1000), now: widget.now),
    );

    // No keyboard padding here: showBrandSheet applies it once for the whole
    // sheet.
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight(context)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: isDesktopModal ? 0 : 8),
              child: const SheetHandle(),
            ),
            Padding(
              // Clear of the desktop modal's close button.
              padding: EdgeInsets.fromLTRB(hpad, 0, isDesktopModal ? 34 : hpad, 16),
              child: Row(
                children: [
                  SheetIcon(
                    icon: Icons.sell_outlined,
                    bg: BrandColors.surfaceAccent,
                    color: BrandColors.primaryDeep,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      strings.labelSheetTitle(widget.coin.kind.name, used.index),
                      style: BrandText.sheetTitle,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(hpad, 0, hpad, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BrandCard(
                      radius: 14,
                      color: BrandColors.paper,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          AddressIndexTile(index: used.index, size: 34),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  shortenMiddle(used.address, head: 8, tail: 8),
                                  style: BrandText.mono.copyWith(
                                    fontSize: 12,
                                    color: BrandColors.ink,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                _AmountLine(
                                  total: labeledAddressTotal(used.receivedBaseUnits, widget.coin),
                                  count: strings.labeledTransactionCount(used.txCount),
                                ),
                                const SizedBox(height: 2),
                                Text(lastUsed, style: BrandText.caption),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    SectionHeader(
                      label: strings.labelSheetField,
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                    ),
                    BrandTextField(
                      controller: _controller,
                      autofocus: true,
                      maxLength: maxAddressLabelLength,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _save(),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(hpad, 18, hpad, isDesktopModal ? 0 : 8),
              child: SheetActions(
                gap: 4,
                primary: BrandButton(label: strings.labelSheetSave, onPressed: _save),
                secondary: BrandButton.ghost(
                  label: strings.cancel,
                  color: BrandColors.inkMuted,
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// History's address filter: the labeled addresses to pick one from, most
/// recently used first, with a radio on the [selected] one. Each entry names
/// its coin, so one list can hold several (Spice).
class LabeledAddressPicker extends StatelessWidget {
  const LabeledAddressPicker({
    super.key,
    required this.strings,
    required this.entries,
    required this.selected,
    required this.onSelect,
  });

  final WalletUiLocalizations strings;
  final List<({String coinSymbol, String address, String label, int index})> entries;

  /// The address the filter holds now, or null.
  final String? selected;
  final void Function(String coinSymbol, String address) onSelect;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final coins = {for (final e in entries) e.coinSymbol};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          label: strings.historyFilterLabeledAddresses,
          padding: const EdgeInsets.only(bottom: 2),
        ),
        for (var i = 0; i < entries.length; i++)
          Semantics(
            button: true,
            selected: entries[i].address == selected,
            child: Tappable(
              onTap: () => onSelect(entries[i].coinSymbol, entries[i].address),
              child: Container(
                decoration: i == entries.length - 1
                    ? null
                    : BoxDecoration(
                        border: Border(bottom: BorderSide(color: BrandColors.surfaceTinted)),
                      ),
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    RadioDot(selected: entries[i].address == selected, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        entries[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: BrandColors.ink),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      coins.length > 1
                          ? '${entries[i].coinSymbol} #${entries[i].index}'
                          : '#${entries[i].index}',
                      style: BrandText.mono.copyWith(fontSize: 12, color: BrandColors.inkMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
