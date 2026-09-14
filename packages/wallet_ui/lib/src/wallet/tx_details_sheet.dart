import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:wallet_domain/wallet_domain.dart'
    show CryptoWallet, TxDetails, TxRecipient, TxStatus, txDirectionIncoming;
import 'package:wallet_infra/wallet_infra.dart' show SecureClipboard;

import '../design/brand.dart';
import '../design/toast.dart';
import '../design/brand_button.dart';
import '../design/brand_card.dart';
import '../design/sheet.dart';
import 'coin_mark.dart';
import 'format.dart';

/// Translated strings for [showTxDetailsSheet]. The app builds this from its own
/// l10n and passes it in — the package carries no localization of its own.
class TxDetailsSheetLabels {
  final String title;
  final String hash;
  final String amount;
  final String networkFee;
  final String timeAndDate;
  final String confirmationHeight;
  final String confirmations;
  final String viewKey;
  final String recipients;
  final String changeRecipient;
  final String close;
  final String copied;
  final String received;
  final String sent;
  final String copyHint;

  /// Shown in the status banner when the chain reports the transaction failed —
  /// mined, fee spent, transfer did not happen.
  ///
  /// Nullable, unlike its siblings, and that is deliberate. This package carries
  /// no localization of its own, so a *required* field would fail both apps'
  /// builds until each added a string, and until then the sheet would present a
  /// failed transaction as a completed one. A non-localized fallback is worse
  /// than translated text and much better than silence, so the status is
  /// displayed either way and the apps can localize on their own schedule.
  final String? failed;

  /// Shown when the chain reports the transaction reverted. Same nullability
  /// reasoning as [failed].
  final String? reverted;

  /// Shown when the broadcast's outcome was never observed. Same nullability
  /// reasoning as [failed].
  final String? unknownStatus;

  /// Address-list header on an incoming tx (the addresses are our own, not who
  /// was paid). Nullable; falls back to [recipients].
  final String? receivedAt;

  /// Shown in place of a mempool tx's height/date. Nullable; falls back to English.
  final String? unconfirmed;

  const TxDetailsSheetLabels({
    required this.title,
    required this.hash,
    required this.amount,
    required this.networkFee,
    required this.timeAndDate,
    required this.confirmationHeight,
    required this.confirmations,
    required this.viewKey,
    required this.recipients,
    required this.changeRecipient,
    required this.close,
    required this.copied,
    required this.received,
    required this.sent,
    required this.copyHint,
    this.failed,
    this.reverted,
    this.unknownStatus,
    this.receivedAt,
    this.unconfirmed,
  });
}

/// Read-only details for a single transaction, as a brand bottom sheet. Every
/// value is tappable to copy (SecureClipboard, so the clip is treated as
/// sensitive). Amounts/fee format per the [wallet]'s own decimals/symbols. A
/// status banner is shown at the top for failed/reverted/unknown txs.
///
/// Presentational: the app injects its translated [labels]; no app l10n here.
void showTxDetailsSheet({
  required BuildContext context,
  required CryptoWallet wallet,
  required TxDetails tx,
  required TxDetailsSheetLabels labels,
}) {
  showBrandSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _TxDetailsSheet(wallet: wallet, tx: tx, labels: labels),
  );
}

class _TxDetailsSheet extends StatelessWidget {
  final CryptoWallet wallet;
  final TxDetails tx;
  final TxDetailsSheetLabels labels;

  const _TxDetailsSheet({required this.wallet, required this.tx, required this.labels});

  static TextStyle get _labelStyle =>
      TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: BrandColors.ink);
  static TextStyle get _valueStyle =>
      TextStyle(fontFamily: 'Ubuntu Mono', fontSize: 13, color: BrandColors.ink);
  static TextStyle get _mutedMono =>
      TextStyle(fontFamily: 'Ubuntu Mono', fontSize: 12.5, color: BrandColors.inkMuted);

  void _copy(BuildContext context, String text) {
    SecureClipboard.copy(text);
    showCopyToast(context, labels.copied);
  }

  String _fmtAmount(BigInt units) => formatAmount(
    displayAmount(units, wallet.baseUnitDecimals),
    wallet.decimals,
    symbol: wallet.coinSymbol,
  );

  /// Status-banner text, or null when there is nothing to warn about. Falls
  /// back to English when the app has not supplied a string: see
  /// [TxDetailsSheetLabels.failed] for why that is the right trade here.
  String? get _statusBanner => switch (tx.status) {
    TxStatus.ok => null,
    TxStatus.failed => labels.failed ?? 'This transaction failed. The funds were not sent.',
    TxStatus.unknown =>
      labels.unknownStatus ??
          'This transaction was not confirmed as sent. Check before sending again.',
  };

  @override
  Widget build(BuildContext context) {
    final incoming = tx.direction == txDirectionIncoming;
    final statusBanner = _statusBanner;
    final date = DateTime.fromMillisecondsSinceEpoch(tx.timestamp * 1000);
    final feeText = formatAmount(
      displayAmount(tx.feeBaseUnits, wallet.feeBaseUnitDecimals),
      wallet.feeDecimals,
      symbol: wallet.feeCoinSymbol,
    );
    // A mempool tx has no block/timestamp; shown raw they read as 0 / 31 Dec 1969.
    final unconfirmed = labels.unconfirmed ?? 'Unconfirmed';
    final heightText = tx.height <= 0 ? unconfirmed : NumberFormat('#,##0').format(tx.height);
    // Default (en) date symbols: initializeDateFormatting isn't wired.
    final dateText = tx.timestamp <= 0
        ? unconfirmed
        : '${DateFormat('HH:mm').format(date)} · ${DateFormat('d MMM yyyy').format(date)}';

    final recipients = tx.recipients.where((r) => !r.isChange).toList();
    final change = tx.recipients.where((r) => r.isChange).toList();

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.86),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetHandle(),
              _header(incoming),
              if (statusBanner != null) ...[const SizedBox(height: 14), _banner(statusBanner)],
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: _card(context, [
                    _row(context, labels.amount, _fmtAmount(tx.amountBaseUnits), bold: true),
                    // The fee is only paid by the sender; received txs don't show it.
                    if (!incoming) _row(context, labels.networkFee, feeText),
                    _row(context, labels.hash, shortenMiddle(tx.hash), copyText: tx.hash),
                    _row(context, labels.timeAndDate, dateText, mono: false),
                    _row(context, labels.confirmationHeight, heightText),
                    _row(context, labels.confirmations, '${tx.confirmations}'),
                    if (tx.key.isNotEmpty)
                      _row(
                        context,
                        labels.viewKey,
                        shortenMiddle(tx.key, head: 6, tail: 4),
                        copyText: tx.key,
                      ),
                    if (recipients.isNotEmpty) _recipients(context, recipients, incoming),
                    for (final c in change)
                      _row(
                        context,
                        labels.changeRecipient,
                        shortenMiddle(c.address, head: 6, tail: 4),
                        copyText: c.address,
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              BrandButton.ghost(
                label: labels.close,
                color: BrandColors.inkMuted,
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A reverted transaction is not one more attribute of a successful one:
  /// everything below reads as a receipt, so the warning leads.
  Widget _banner(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: BrandColors.errorBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrandColors.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_rounded, size: 18, color: BrandColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                height: 1.35,
                color: BrandColors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(bool incoming) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 42,
          height: 42,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              CoinMark(coinSymbol: wallet.coinSymbol, iconAsset: wallet.iconAsset, size: 40),
              Positioned(
                right: -1,
                bottom: -1,
                child: Container(
                  width: 18,
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: BrandColors.paper,
                    shape: BoxShape.circle,
                    border: Border.all(color: BrandColors.hairline, width: 1.5),
                  ),
                  child: Icon(
                    incoming ? Icons.south : Icons.north,
                    size: 11,
                    color: incoming ? BrandColors.success : BrandColors.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(labels.title, style: BrandText.sheetTitle),
              const SizedBox(height: 3),
              Text(
                '${incoming ? labels.received : labels.sent} · ${labels.copyHint}',
                style: BrandText.caption.copyWith(fontSize: 12.5, color: BrandColors.inkMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _card(BuildContext context, List<Widget> rows) {
    return BrandCard(
      padding: const EdgeInsets.symmetric(horizontal: 15),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i != 0) Container(height: 1, color: BrandColors.hairline),
            rows[i],
          ],
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    String value, {
    bool mono = true,
    bool bold = false,
    String? copyText,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _copy(context, copyText ?? value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Text(label, style: _labelStyle),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: mono
                    ? _valueStyle.copyWith(
                        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
                        fontSize: bold ? 15 : 13,
                      )
                    : TextStyle(fontSize: 13, color: BrandColors.ink),
              ),
            ),
            const SizedBox(width: 10),
            Icon(Icons.copy_outlined, size: 15, color: BrandColors.inkFaint),
          ],
        ),
      ),
    );
  }

  Widget _recipients(BuildContext context, List<TxRecipient> recipients, bool incoming) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                incoming ? (labels.receivedAt ?? labels.recipients) : labels.recipients,
                style: _labelStyle,
              ),
              const Spacer(),
              Text('${recipients.length}', style: _mutedMono),
            ],
          ),
          for (final r in recipients)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _copy(context, r.address),
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(shortenMiddle(r.address, head: 6, tail: 4), style: _mutedMono),
                    ),
                    const SizedBox(width: 10),
                    Text(_fmtAmount(r.amountBaseUnits), style: _valueStyle),
                    const SizedBox(width: 10),
                    Icon(Icons.copy_outlined, size: 15, color: BrandColors.inkFaint),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
