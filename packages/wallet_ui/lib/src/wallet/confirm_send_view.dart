import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_card.dart';
import '../design/sheet.dart';
import 'coin_mark.dart';

/// Translated strings for [ConfirmSendView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class ConfirmSendLabels {
  final String title;
  final String description;
  final String amount;
  final String networkFee;
  final String address;
  final String openAlias;
  final String send;
  final String cancel;

  const ConfirmSendLabels({
    required this.title,
    required this.description,
    required this.amount,
    required this.networkFee,
    required this.address,
    required this.send,
    required this.cancel,
    this.openAlias = 'OpenAlias',
  });
}

/// The "Confirm Send" review, rendered as the body of a brand bottom sheet:
/// amount (with coin mark + fiat), network fee (+ fiat), an optional OpenAlias
/// row, the verifiable destination address (+ optional contact name), a
/// high-fee warning, and the Send/Cancel buttons.
///
/// Presentational only — the app builds every display string (amounts, fees,
/// fiat, address), decides whether to show the high-fee warning, and supplies
/// [onConfirm] (its own tx commit). The view owns nothing but the sheet layout;
/// [loading] is injected and blocks dismissal + the buttons.
class ConfirmSendView extends StatelessWidget {
  final ConfirmSendLabels labels;

  // Amount row.
  final String coinSymbol;
  final String iconAsset;
  final String amountText;
  final String? amountFiat;

  // Network-fee row.
  final String feeText;
  final String? feeFiat;

  // Destination.
  final String address;
  final String? openAlias;
  final String? openAliasName;
  final String? contactName;

  // High-fee warning. [highFeeWarning] is the localized sentence with a single
  // occurrence of [highFeeToken]; the view splits on the token and renders
  // [highFeePercent] bold in its place.
  final bool showHighFeeWarning;
  final String? highFeeWarning;
  final String? highFeeToken;
  final String? highFeePercent;

  final Future<void> Function() onConfirm;
  final bool loading;

  const ConfirmSendView({
    super.key,
    required this.labels,
    required this.coinSymbol,
    required this.amountText,
    required this.feeText,
    required this.address,
    required this.onConfirm,
    this.iconAsset = '',
    this.amountFiat,
    this.feeFiat,
    this.openAlias,
    this.openAliasName,
    this.contactName,
    this.showHighFeeWarning = false,
    this.highFeeWarning,
    this.highFeeToken,
    this.highFeePercent,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      _detailRow(
        labels.amount,
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CoinMark(coinSymbol: coinSymbol, iconAsset: iconAsset, size: 22),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    amountText,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontFamily: 'Ubuntu Mono',
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: BrandColors.ink,
                    ),
                  ),
                ),
              ],
            ),
            if (amountFiat != null) ...[const SizedBox(height: 4), _fiatText(amountFiat!)],
          ],
        ),
      ),
      _detailRow(
        labels.networkFee,
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              feeText,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontFamily: 'Ubuntu Mono',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: BrandColors.ink,
              ),
            ),
            if (feeFiat != null) ...[const SizedBox(height: 4), _fiatText(feeFiat!)],
          ],
        ),
      ),
      if (openAlias != null)
        _detailRow(
          labels.openAlias,
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                openAlias!,
                textAlign: TextAlign.end,
                style: TextStyle(fontSize: 12.5, color: BrandColors.ink),
              ),
              if (openAliasName != null) ...[
                const SizedBox(height: 4),
                _fiatText('($openAliasName)', mono: false),
              ],
            ],
          ),
        ),
      _detailRow(
        labels.address,
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _verifiableAddress(address),
            if (contactName != null) ...[
              const SizedBox(height: 4),
              _fiatText('($contactName)', mono: false),
            ],
          ],
        ),
      ),
    ];

    // Desktop modal: the card owns the edge padding.
    final hpad = isDesktopModal ? 0.0 : 22.0;

    return PopScope(
      // Block drag/back dismissal while the commit is in flight.
      canPop: !loading,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.86),
          child: Padding(
            padding: EdgeInsets.only(top: isDesktopModal ? 0 : 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SheetHandle(),
                Padding(
                  padding: EdgeInsets.fromLTRB(hpad, 0, hpad, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          SheetIcon(
                            icon: Icons.north_east,
                            bg: BrandColors.surfaceAccent,
                            color: BrandColors.primaryDeep,
                          ),
                          const SizedBox(width: 11),
                          Expanded(child: Text(labels.title, style: BrandText.sheetTitle)),
                        ],
                      ),
                      const SizedBox(height: 7),
                      Text(
                        labels.description,
                        style: BrandText.bodyMuted.copyWith(fontSize: 13, height: 1.5),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: hpad),
                          child: BrandCard(
                            radius: 18,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: Column(
                              children: [
                                for (var i = 0; i < rows.length; i++) ...[
                                  if (i != 0) Container(height: 1, color: BrandColors.hairline),
                                  rows[i],
                                ],
                              ],
                            ),
                          ),
                        ),
                        if (showHighFeeWarning && highFeeWarning != null)
                          Padding(
                            padding: EdgeInsets.fromLTRB(hpad, 12, hpad, 0),
                            child: _highFeeWarning(
                              highFeeWarning!,
                              highFeeToken ?? '',
                              highFeePercent ?? '',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(hpad, 18, hpad, 8),
                  child: SheetActions(
                    primary: BrandButton(
                      label: labels.send,
                      icon: Icons.north_east,
                      iconTrailing: true,
                      loading: loading,
                      onPressed: onConfirm,
                    ),
                    secondary: BrandButton.ghost(
                      label: labels.cancel,
                      color: BrandColors.inkMuted,
                      onPressed: loading ? null : () => Navigator.of(context).pop(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, Widget value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1.35,
              color: BrandColors.ink,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: value),
          ),
        ],
      ),
    );
  }

  Widget _fiatText(String text, {bool mono = true}) {
    return Text(
      text,
      textAlign: TextAlign.end,
      style: TextStyle(
        fontFamily: mono ? 'Ubuntu Mono' : null,
        fontSize: 11.5,
        color: BrandColors.inkMuted,
      ),
    );
  }

  /// Address with its first/last chunks bold and the middle de-emphasised, so
  /// the parts users actually verify stand out.
  Widget _verifiableAddress(String address) {
    final parts = _addressDisplayParts(address);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 210),
      child: Text.rich(
        TextSpan(
          style: TextStyle(
            fontFamily: 'Ubuntu Mono',
            fontSize: 12.5,
            height: 1.5,
            color: BrandColors.ink,
          ),
          children: [
            TextSpan(
              text: parts.$1,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (parts.$2.isNotEmpty)
              TextSpan(
                text: parts.$2,
                style: TextStyle(fontWeight: FontWeight.w300, color: BrandColors.inkMuted),
              ),
            TextSpan(
              text: parts.$3,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        textAlign: TextAlign.end,
      ),
    );
  }

  Widget _highFeeWarning(String warning, String token, String percent) {
    // Split the localized string on the placeholder token so the percentage can
    // be bolded regardless of locale. The app inserts a sentinel token (not a
    // space, since the sentence itself has spaces) via its l10n getter.
    final parts = token.isEmpty ? [warning] : warning.split(token);
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: BrandColors.warningBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: BrandColors.warning, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 12.5, height: 1.4, color: BrandColors.ink),
                children: [
                  TextSpan(text: parts.first),
                  TextSpan(
                    text: percent,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (parts.length > 1) TextSpan(text: parts.last),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Splits an address into visually distinct prefix/middle/suffix regions so
/// users can verify the start and end regardless of coin or address format.
/// Inlined from the app-side `addressDisplayParts` so the shared view stays
/// self-contained.
(String, String, String) _addressDisplayParts(String address) {
  if (address.isEmpty) return ('', '', '');
  if (address.length <= 12) return (address, '', '');

  final highlight = switch (address.length) {
    <= 20 => 4,
    <= 40 => 6,
    <= 60 => 8,
    _ => 10,
  };

  if (address.length <= highlight * 2) {
    final mid = address.length ~/ 2;
    return (address.substring(0, mid), '', address.substring(mid));
  }

  return (
    address.substring(0, highlight),
    address.substring(highlight, address.length - highlight),
    address.substring(address.length - highlight),
  );
}

/// Opens [ConfirmSendView] as a brand bottom sheet and resolves to `true` once
/// [onConfirm] succeeds (mirroring the source-of-truth Spice flow), or null if
/// the user dismisses/cancels. [onConfirm] should do the app's own tx commit;
/// the sheet pops `true` after it returns.
Future<bool?> showConfirmSendSheet({
  required BuildContext context,
  required ConfirmSendLabels labels,
  required String coinSymbol,
  required String amountText,
  required String feeText,
  required String address,
  required Future<void> Function() onConfirm,
  String iconAsset = '',
  String? amountFiat,
  String? feeFiat,
  String? openAlias,
  String? openAliasName,
  String? contactName,
  bool showHighFeeWarning = false,
  String? highFeeWarning,
  String? highFeeToken,
  String? highFeePercent,
}) {
  return showBrandSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ConfirmSendSheet(
      labels: labels,
      coinSymbol: coinSymbol,
      iconAsset: iconAsset,
      amountText: amountText,
      amountFiat: amountFiat,
      feeText: feeText,
      feeFiat: feeFiat,
      address: address,
      openAlias: openAlias,
      openAliasName: openAliasName,
      contactName: contactName,
      showHighFeeWarning: showHighFeeWarning,
      highFeeWarning: highFeeWarning,
      highFeeToken: highFeeToken,
      highFeePercent: highFeePercent,
      onConfirm: onConfirm,
    ),
  );
}

/// Stateful wrapper that owns the in-flight [loading] flag: runs [onConfirm],
/// and on success pops the sheet with `true`. The app's [onConfirm] surfaces
/// its own errors (snackbars); this just resets loading if it returns without
/// having popped.
class _ConfirmSendSheet extends StatefulWidget {
  final ConfirmSendLabels labels;
  final String coinSymbol;
  final String iconAsset;
  final String amountText;
  final String? amountFiat;
  final String feeText;
  final String? feeFiat;
  final String address;
  final String? openAlias;
  final String? openAliasName;
  final String? contactName;
  final bool showHighFeeWarning;
  final String? highFeeWarning;
  final String? highFeeToken;
  final String? highFeePercent;
  final Future<void> Function() onConfirm;

  const _ConfirmSendSheet({
    required this.labels,
    required this.coinSymbol,
    required this.iconAsset,
    required this.amountText,
    required this.amountFiat,
    required this.feeText,
    required this.feeFiat,
    required this.address,
    required this.openAlias,
    required this.openAliasName,
    required this.contactName,
    required this.showHighFeeWarning,
    required this.highFeeWarning,
    required this.highFeeToken,
    required this.highFeePercent,
    required this.onConfirm,
  });

  @override
  State<_ConfirmSendSheet> createState() => _ConfirmSendSheetState();
}

class _ConfirmSendSheetState extends State<_ConfirmSendSheet> {
  bool _loading = false;

  Future<void> _confirm() async {
    setState(() => _loading = true);
    try {
      await widget.onConfirm();
      if (mounted) Navigator.of(context).pop(true);
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConfirmSendView(
      labels: widget.labels,
      coinSymbol: widget.coinSymbol,
      iconAsset: widget.iconAsset,
      amountText: widget.amountText,
      amountFiat: widget.amountFiat,
      feeText: widget.feeText,
      feeFiat: widget.feeFiat,
      address: widget.address,
      openAlias: widget.openAlias,
      openAliasName: widget.openAliasName,
      contactName: widget.contactName,
      showHighFeeWarning: widget.showHighFeeWarning,
      highFeeWarning: widget.highFeeWarning,
      highFeeToken: widget.highFeeToken,
      highFeePercent: widget.highFeePercent,
      loading: _loading,
      onConfirm: _confirm,
    );
  }
}
