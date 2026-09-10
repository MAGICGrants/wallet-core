import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:wallet_domain/wallet_domain.dart';
import 'package:wallet_fiat/wallet_fiat.dart' show FiatRateModel;

import '../design/brand.dart';
import 'coin_mark.dart';
import 'format.dart';

/// A single transaction paired with the asset it belongs to, for a merged
/// activity timeline (coin home + global history).
typedef TxEntry = ({TxDetails tx, CryptoWallet asset});

/// The translated "Received" / "Sent" labels, injected so this widget stays
/// localization-agnostic (each app passes its own generated strings).
class TxActivityLabels {
  final String received, sent;
  const TxActivityLabels({required this.received, required this.sent});
}

/// One activity row: asset icon + direction badge, "Received/Sent" + time·chain,
/// and the signed amount with its fiat value.
class TxActivityRow extends StatelessWidget {
  final TxDetails tx;
  final CryptoWallet asset;
  final TxActivityLabels labels;
  final FiatRateModel fiatRate;
  final String fiatSymbol;
  final bool showDivider;

  /// When false, the leading badge is a coin-agnostic direction circle (no
  /// [CoinMark]) — used by single-coin apps (Skylight/Monero). Default true so
  /// multicoin (Spice) is unchanged.
  final bool showCoinIcon;
  final VoidCallback onTap;

  const TxActivityRow({
    super.key,
    required this.tx,
    required this.asset,
    required this.labels,
    required this.fiatRate,
    required this.fiatSymbol,
    required this.showDivider,
    this.showCoinIcon = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final incoming = tx.direction == txDirectionIncoming;
    final coinRate = fiatRate.rateFor(asset.coinSymbol);
    final amount = displayAmount(tx.amountBaseUnits, asset.baseUnitDecimals);
    final amountFiat = coinRate != null ? amount * coinRate : null;
    final confirmed = asset.isTxConfirmed(tx);
    final date = DateTime.fromMillisecondsSinceEpoch(tx.timestamp * 1000);
    final amountColor = incoming ? BrandColors.success : BrandColors.ink;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        decoration: showDivider
            ? BoxDecoration(
                border: Border(bottom: BorderSide(color: BrandColors.surfaceTinted)),
              )
            : null,
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            TxActivityIcon(asset: asset, incoming: incoming, showCoinIcon: showCoinIcon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    incoming ? labels.received : labels.sent,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.25,
                      color: BrandColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      if (!confirmed) ...[
                        Icon(Icons.hourglass_top_rounded, size: 12, color: BrandColors.warning),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        // Default (en) symbols: initializeDateFormatting isn't wired, so a
                        // locale arg would throw for pt. Single-coin apps
                        // (showCoinIcon false) drop the redundant coin name.
                        showCoinIcon
                            ? '${DateFormat('HH:mm').format(date)} · ${asset.assetName}'
                            : DateFormat('HH:mm').format(date),
                        style: TextStyle(fontSize: 11, height: 1.3, color: BrandColors.inkMuted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${incoming ? '+' : '−'}${formatAmount(amount, asset.decimals, symbol: asset.coinSymbol)}',
                  style: TextStyle(
                    fontFamily: 'Ubuntu Mono',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                    color: amountColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (amountFiat != null && !fiatRate.isDisabled) ...[
                  const SizedBox(height: 2),
                  Text(
                    formatFiat(amountFiat, fiatSymbol),
                    style: TextStyle(
                      fontFamily: 'Ubuntu Mono',
                      fontSize: 11,
                      height: 1.3,
                      color: BrandColors.inkMuted,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The asset's chain tile with a small direction badge (receive / send). When
/// [showCoinIcon] is false, renders just a direction circle (no [CoinMark]) for
/// single-coin apps.
class TxActivityIcon extends StatelessWidget {
  final CryptoWallet asset;
  final bool incoming;
  final bool showCoinIcon;

  const TxActivityIcon({
    super.key,
    required this.asset,
    required this.incoming,
    this.showCoinIcon = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!showCoinIcon) {
      return Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: BrandColors.surfaceSunken, shape: BoxShape.circle),
        child: Icon(
          incoming ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
          size: 16,
          color: incoming ? BrandColors.success : BrandColors.primary,
        ),
      );
    }
    return SizedBox(
      width: 38,
      height: 38,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CoinMark(coinSymbol: asset.coinSymbol, iconAsset: asset.iconAsset, size: 36),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 17,
              height: 17,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: BrandColors.paper,
                shape: BoxShape.circle,
                border: Border.all(color: BrandColors.hairline, width: 1.5),
              ),
              child: Icon(
                incoming ? Icons.south : Icons.north,
                size: 10,
                color: incoming ? BrandColors.success : BrandColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
