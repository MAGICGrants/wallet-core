import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/brand.dart';
import '../design/click_cursor.dart';
import '../design/brand_button.dart';
import '../design/brand_card.dart';
import '../design/brand_screen_header.dart';
import '../design/brand_segmented.dart';
import '../design/mini_action_button.dart';
import '../design/section_header.dart';
import 'amount_entry_controller.dart';
import 'format.dart';

/// Translated strings for [SendView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class SendLabels {
  final String title;
  final String toLabel;
  final String amount;
  final String priorityHeading;
  final String networkFee;
  final String sendButton;
  final String cancel;
  final String pasteButton;
  final String scanButton;
  final String contactsButton;
  final String maxButton;
  final String addressHint;
  final List<String> priorityLabels;

  /// Screen-reader label for the unit chip that swaps coin and fiat entry.
  final String switchUnit;

  const SendLabels({
    required this.title,
    required this.toLabel,
    required this.amount,
    required this.priorityHeading,
    required this.networkFee,
    required this.sendButton,
    required this.cancel,
    required this.pasteButton,
    required this.scanButton,
    required this.contactsButton,
    required this.maxButton,
    required this.addressHint,
    required this.priorityLabels,
    required this.switchUnit,
  });
}

/// The send screen body: a header; an optional asset/"From" section (Spice's
/// multicoin dropdown, injected as [assetSection]); a "To" card (multi-line
/// address field, OpenAlias spinner, paste/scan/contacts, selected-contact
/// chip, inline error); an "Amount" card (amount field + unit swap + MAX, the
/// converted amount, available + rate); a "Priority" section (segmented +
/// per-priority network fee); and a Cancel/Send row.
///
/// Presentational only — the app owns every controller, all validation, fee
/// calculation, OpenAlias resolution, contact resolution, and the send/confirm
/// flow. The view renders injected state and calls back. The amount card reads
/// everything it shows from [amount], so both apps render fiat identically.
class SendView extends StatelessWidget {
  final SendLabels labels;
  final VoidCallback onBack;

  /// Spice's "From" asset dropdown widget (with its own section label), or null
  /// to omit the section entirely (Skylight, single-coin).
  final Widget? assetSection;

  // To card.
  final TextEditingController addressController;
  final FocusNode? addressFocusNode;
  final String addressError;

  /// Spinner in the address field while an OpenAlias lookup is in flight.
  final bool openAliasResolving;
  final VoidCallback onPaste;

  /// Mobile QR scan; null hides the Scan affordance (desktop).
  final VoidCallback? onScan;
  final VoidCallback onPickContact;

  /// Selected-contact chip. When [contactName] is non-null the To card is
  /// replaced by the chip (avatar initial + name + short address + clear).
  final String? contactName;
  final String? contactAddressShort;
  final VoidCallback? onClearContact;

  // Amount card.
  final AmountEntryController amount;
  final String amountError;
  final VoidCallback onMax;

  /// Available-balance line (Skylight: `x available`, tappable for MAX), left
  /// of the rate. Null on Spice, where available lives on the "From" card and
  /// the bottom line is just the rate.
  final String? availableText;

  /// Optional leading widget on the available line (Skylight's Monero glyph).
  final Widget? availableLeading;

  /// Tapping the available line sets MAX (Skylight); null makes it inert.
  final VoidCallback? onAvailableTap;

  // Priority.
  final int selectedPriority;
  final ValueChanged<int> onSelectPriority;

  /// The rendered network-fee value (spinner / dash / `~amount · fiat`).
  final Widget feeValue;

  // Send / cancel.
  final VoidCallback onCancel;
  final VoidCallback? onSend;

  /// Send-button icon; null for none (Spice). Skylight uses an outward arrow.
  final IconData? sendIcon;
  final bool sendLoading;

  const SendView({
    super.key,
    required this.labels,
    required this.onBack,
    required this.addressController,
    required this.addressError,
    required this.openAliasResolving,
    required this.onPaste,
    required this.onPickContact,
    required this.amount,
    required this.amountError,
    required this.onMax,
    required this.selectedPriority,
    required this.onSelectPriority,
    required this.feeValue,
    required this.onCancel,
    required this.onSend,
    this.assetSection,
    this.addressFocusNode,
    this.onScan,
    this.contactName,
    this.contactAddressShort,
    this.onClearContact,
    this.availableText,
    this.availableLeading,
    this.onAvailableTap,
    this.sendIcon,
    this.sendLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrandColors.paper,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: BrandScreenHeader(
                    onBack: onBack,
                    center: Text(labels.title, style: BrandText.appBar.copyWith(fontSize: 16)),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 26, 16, 16),
                    children: [
                      if (assetSection != null) ...[assetSection!, const SizedBox(height: 14)],
                      _sectionLabel(labels.toLabel),
                      _toCard(),
                      if (addressError.isNotEmpty) _errorText(addressError),
                      const SizedBox(height: 14),
                      _sectionLabel(labels.amount),
                      ListenableBuilder(listenable: amount, builder: (_, _) => _amountSection()),
                      const SizedBox(height: 14),
                      _sectionLabel(labels.priorityHeading),
                      _prioritySection(),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      BrandButton.ghost(
                        label: labels.cancel,
                        color: BrandColors.inkMuted,
                        expand: false,
                        onPressed: onCancel,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: BrandButton(
                          label: labels.sendButton,
                          icon: sendIcon,
                          loading: sendLoading,
                          onPressed: onSend,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) =>
      SectionHeader(label: text, padding: const EdgeInsets.only(left: 4, bottom: 8));

  Widget _errorText(String text) => Padding(
    padding: const EdgeInsets.only(top: 6, left: 4),
    child: Text(text, style: BrandText.caption.copyWith(color: BrandColors.error)),
  );

  Widget _toCard() {
    if (contactName != null) {
      return BrandCard(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: BrandColors.primaryDeep, shape: BoxShape.circle),
              child: Text(
                contactName!.isNotEmpty ? contactName![0].toUpperCase() : '?',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: BrandColors.onPrimary,
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contactName!,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: BrandColors.ink,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    contactAddressShort ?? '',
                    style: TextStyle(
                      fontFamily: 'Ubuntu Mono',
                      fontSize: 11,
                      color: BrandColors.inkMuted,
                    ),
                  ),
                ],
              ),
            ),
            Tappable(
              behavior: HitTestBehavior.opaque,
              onTap: onClearContact,
              child: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: BrandColors.surfaceSunken,
                  shape: BoxShape.circle,
                  border: Border.all(color: BrandColors.border),
                ),
                child: Icon(Icons.close, size: 15, color: BrandColors.ink),
              ),
            ),
          ],
        ),
      );
    }

    final isMobile = Platform.isAndroid || Platform.isIOS;
    return BrandCard(
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
      borderColor: addressError.isNotEmpty ? BrandColors.error : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: addressController,
            focusNode: addressFocusNode,
            maxLines: null,
            textInputAction: TextInputAction.done,
            style: TextStyle(
              fontFamily: 'Ubuntu Mono',
              fontSize: 13.5,
              height: 1.5,
              color: BrandColors.ink,
            ),
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: labels.addressHint,
              hintStyle: TextStyle(
                fontFamily: 'Ubuntu Mono',
                fontSize: 13.5,
                height: 1.5,
                color: BrandColors.inkMuted,
              ),
              suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
              suffixIcon: openAliasResolving
                  ? Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: BrandColors.primary,
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: BrandColors.surfaceTinted),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: MiniActionButton(
                  icon: Icons.content_paste_outlined,
                  label: labels.pasteButton,
                  onTap: onPaste,
                ),
              ),
              if (isMobile && onScan != null) ...[
                const SizedBox(width: 7),
                Expanded(
                  child: MiniActionButton(
                    icon: Icons.qr_code_scanner,
                    label: labels.scanButton,
                    onTap: onScan!,
                  ),
                ),
              ],
              const SizedBox(width: 7),
              Expanded(
                child: MiniActionButton(
                  icon: Icons.person_outline,
                  label: labels.contactsButton,
                  onTap: onPickContact,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _amountSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [_amountCard(), if (amountError.isNotEmpty) _errorText(amountError)],
    );
  }

  Widget _amountCard() {
    final quote = amount.quote;
    final fiatEntry = amount.unit == AmountUnit.fiat && quote != null;
    final converted = _convertedText();
    final rate = quote == null
        ? null
        : '1 ${amount.coinSymbol} ≈ ${formatFiat(quote.rate, quote.currency)}';
    final fiatDecimals = quote?.currency.decimals ?? 0;

    return BrandCard(
      padding: const EdgeInsets.fromLTRB(14, 15, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _AmountField(
                  amount: amount,
                  prefix: fiatEntry ? quote.currency.symbol : '',
                  hint: fiatEntry
                      ? (fiatDecimals == 0 ? '0' : '0.${'0' * fiatDecimals}')
                      : '0.000000',
                  decimals: fiatEntry ? fiatDecimals : amount.coinDecimals,
                ),
              ),
              const SizedBox(width: 10),
              if (quote != null)
                _unitChip(fiatEntry ? quote.currency.code : amount.coinSymbol)
              else
                Text(amount.coinSymbol, style: _unitStyle),
              const SizedBox(width: 10),
              Tappable(
                behavior: HitTestBehavior.opaque,
                onTap: onMax,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
                  decoration: BoxDecoration(
                    color: BrandColors.surfaceAccent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    labels.maxButton,
                    style: TextStyle(
                      fontFamily: 'Ubuntu Mono',
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: BrandColors.primaryDeep,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (converted != null) ...[
            const SizedBox(height: 9),
            // Tapping the other unit swaps to it, like the chip.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: amount.swap,
              child: SizedBox(
                width: double.infinity,
                height: 17,
                child: converted.isEmpty
                    ? null
                    : FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          converted,
                          maxLines: 1,
                          style: TextStyle(
                            fontFamily: 'Ubuntu Mono',
                            fontSize: 13,
                            color: BrandColors.inkMuted,
                          ),
                        ),
                      ),
              ),
            ),
          ],
          if (availableText != null || rate != null) ...[
            const SizedBox(height: 11),
            Container(height: 1, color: BrandColors.surfaceTinted),
            const SizedBox(height: 11),
            _amountBottomLine(rate),
          ],
        ],
      ),
    );
  }

  TextStyle get _unitStyle => TextStyle(
    fontFamily: 'Ubuntu Mono',
    fontSize: 13,
    fontWeight: FontWeight.w700,
    color: BrandColors.inkMuted,
  );

  /// The unit being typed, tappable to swap to the other one.
  Widget _unitChip(String label) {
    return Semantics(
      button: true,
      label: labels.switchUnit,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: amount.swap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
          decoration: BoxDecoration(
            color: BrandColors.surfaceSunken,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: BrandColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: _unitStyle),
              const SizedBox(width: 4),
              Icon(Icons.swap_vert, size: 15, color: BrandColors.inkMuted),
            ],
          ),
        ),
      ),
    );
  }

  /// The amount in the unit not being typed: `≈ $150.00` under a coin amount,
  /// the exact coin amount under a fiat one. Empty while the field is; null
  /// without a rate, when there is nothing to convert to.
  String? _convertedText() {
    final quote = amount.quote;
    if (quote == null) return null;
    if (amount.isEmpty) return '';
    if (amount.unit == AmountUnit.fiat) return '${amount.coinText} ${amount.coinSymbol}';
    final minor = amount.fiatMinorUnits ?? BigInt.zero;
    final value = minor.toDouble() / math.pow(10, quote.currency.decimals);
    return '≈ ${formatFiat(value, quote.currency)}';
  }

  Widget _amountBottomLine(String? rate) {
    final style = TextStyle(fontFamily: 'Ubuntu Mono', fontSize: 12, color: BrandColors.inkMuted);
    final rateText = rate == null ? null : Text(rate, style: style);
    // Spice: no available line here (it's on the "From" card), so the bottom
    // line is just the rate.
    if (availableText == null) return rateText ?? const SizedBox.shrink();

    Widget availableLine = Row(
      children: [
        if (availableLeading != null) ...[availableLeading!, const SizedBox(width: 6)],
        Flexible(
          child: Text(availableText!, overflow: TextOverflow.ellipsis, style: style),
        ),
      ],
    );
    if (onAvailableTap != null) {
      availableLine = Tappable(
        behavior: HitTestBehavior.opaque,
        onTap: onAvailableTap,
        child: availableLine,
      );
    }
    return Row(
      children: [
        Expanded(child: availableLine),
        if (rateText != null) ...[const SizedBox(width: 10), rateText],
      ],
    );
  }

  Widget _prioritySection() {
    return Column(
      children: [
        BrandSegmented(
          labels: labels.priorityLabels,
          selectedIndex: selectedPriority,
          onSelect: onSelectPriority,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 11, 4, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(labels.networkFee, style: TextStyle(fontSize: 12, color: BrandColors.inkMuted)),
              feeValue,
            ],
          ),
        ),
      ],
    );
  }
}

/// The amount input, sized to fit. The font shrinks until the whole amount and
/// its fiat prefix fit the width, so every digit stays visible and the field
/// never scrolls.
class _AmountField extends StatelessWidget {
  const _AmountField({
    required this.amount,
    required this.prefix,
    required this.hint,
    required this.decimals,
  });

  final AmountEntryController amount;

  /// The fiat symbol while typing fiat; empty for the coin.
  final String prefix;
  final String hint;

  /// Fraction digits the field accepts: the coin's, or the currency's.
  final int decimals;

  static const _baseSize = 26.0;
  static const _minSize = 8.0;

  /// Room for the caret after the last digit.
  static const _caretAllowance = 4.0;

  /// Letter spacing is pinned so the theme's (Material 3 merges 0.5 into a
  /// TextField) can't widen the drawn text past what [_fittedSize] measured.
  static TextStyle _style(double size, Color color) => TextStyle(
    fontFamily: 'Ubuntu Mono',
    fontSize: size,
    fontWeight: FontWeight.w700,
    height: 1,
    letterSpacing: 0,
    color: color,
  );

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return SizedBox(
      // Fixed at the full size so the card doesn't shrink as digits are added.
      height: scaler.scale(_baseSize),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final shown = amount.field.text.isEmpty ? hint : amount.field.text;
          final size = _fittedSize(context, '$prefix$shown', constraints.maxWidth);
          final style = _style(size, BrandColors.ink);
          return Row(
            children: [
              if (prefix.isNotEmpty) Text(prefix, style: style),
              Expanded(
                child: TextField(
                  controller: amount.field,
                  keyboardType: TextInputType.numberWithOptions(decimal: decimals > 0),
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(decimals > 0 ? '^\\d+(\\.\\d{0,$decimals})?' : r'^\d+'),
                    ),
                  ],
                  style: style,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: hint,
                    hintStyle: _style(size, BrandColors.inkFaint),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  double _fittedSize(BuildContext context, String text, double maxWidth) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double widthAt(double size) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: _style(size, BrandColors.ink)),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width + _caretAllowance;
    }

    // Width is close to linear in font size, so one proportional step nearly
    // always lands; the extra passes absorb non-linear system text scaling.
    var size = _baseSize;
    for (var pass = 0; pass < 3 && size > _minSize; pass++) {
      final width = widthAt(size);
      if (width <= maxWidth) break;
      size = math.max(_minSize, (size * maxWidth / width).floorToDouble());
    }
    return size;
  }
}
