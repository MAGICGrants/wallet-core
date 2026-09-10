import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_card.dart';
import '../design/brand_screen_header.dart';
import '../design/brand_segmented.dart';
import '../design/icon_circle_button.dart';
import '../design/section_header.dart';
import 'coin_mark.dart';

/// Translated strings for [ReceiveView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class ReceiveLabels {
  final String title;
  final String copyAddress;

  const ReceiveLabels({required this.title, required this.copyAddress});
}

/// The receive screen: a coin card, an optional subaddress/primary segmented
/// toggle, a white QR panel with the tappable mono address, an optional warning
/// line, and a Copy button. Presentational only — the app computes the
/// address/heading/warning + tab state and supplies the copy/share callbacks.
///
/// The QR panel is fixed dark-on-white so it always scans, regardless of theme.
class ReceiveView extends StatelessWidget {
  final ReceiveLabels labels;
  final VoidCallback onBack;

  /// Mobile share header action; null hides the header share button.
  final VoidCallback? onShare;

  /// Spinner while false (the address is still being resolved).
  final bool ready;

  // Coin card. When [coinName] is null the card is omitted.
  final String coinSymbol;
  final String iconAsset;
  final String? coinName;
  final String? blockchainSubtitle;

  // Subaddress tabs. Null [tabLabels] hides the segmented control.
  final List<String>? tabLabels;
  final int selectedTab;
  final ValueChanged<int>? onSelectTab;

  final String address;
  final String qrHeading;
  final String? warning;
  final VoidCallback onCopy;

  const ReceiveView({
    super.key,
    required this.labels,
    required this.onBack,
    required this.ready,
    required this.coinSymbol,
    required this.iconAsset,
    required this.coinName,
    required this.blockchainSubtitle,
    required this.address,
    required this.qrHeading,
    required this.onCopy,
    this.onShare,
    this.tabLabels,
    this.selectedTab = 0,
    this.onSelectTab,
    this.warning,
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
                    action: onShare != null
                        ? IconCircleButton(icon: Icons.ios_share, onPressed: ready ? onShare : null)
                        : null,
                  ),
                ),
                Expanded(
                  child: !ready
                      ? Center(child: CircularProgressIndicator(color: BrandColors.primary))
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 22, 16, 24),
                          children: [
                            if (coinName != null)
                              _CoinCard(
                                coinSymbol: coinSymbol,
                                iconAsset: iconAsset,
                                coinName: coinName!,
                                blockchainSubtitle: blockchainSubtitle,
                              ),
                            if (tabLabels != null) ...[
                              const SizedBox(height: 14),
                              BrandSegmented(
                                dense: true,
                                labels: tabLabels!,
                                selectedIndex: selectedTab,
                                onSelect: onSelectTab ?? (_) {},
                              ),
                            ],
                            const SizedBox(height: 14),
                            _QrCard(address: address, heading: qrHeading, onTap: onCopy),
                            if (warning != null) ...[
                              const SizedBox(height: 14),
                              Text(
                                warning!,
                                textAlign: TextAlign.center,
                                style: BrandText.caption.copyWith(
                                  color: BrandColors.warning,
                                  height: 1.4,
                                ),
                              ),
                            ],
                            const SizedBox(height: 14),
                            BrandButton(
                              label: labels.copyAddress,
                              icon: Icons.copy_outlined,
                              onPressed: onCopy,
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
}

class _CoinCard extends StatelessWidget {
  final String coinSymbol;
  final String iconAsset;
  final String coinName;
  final String? blockchainSubtitle;

  const _CoinCard({
    required this.coinSymbol,
    required this.iconAsset,
    required this.coinName,
    required this.blockchainSubtitle,
  });

  @override
  Widget build(BuildContext context) {
    return BrandCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          CoinMark(coinSymbol: coinSymbol, iconAsset: iconAsset, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  coinName,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w500,
                    height: 1.25,
                    color: BrandColors.ink,
                  ),
                ),
                if (blockchainSubtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    blockchainSubtitle!,
                    style: BrandText.caption.copyWith(fontSize: 11.5, color: BrandColors.inkMuted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QrCard extends StatelessWidget {
  final String address;
  final String heading;
  final VoidCallback onTap;

  const _QrCard({required this.address, required this.heading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return BrandCard(
      radius: 22,
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            // The QR sits on a fixed white card so it scans, so its modules must
            // stay dark in both themes — the themed ink goes light in dark mode.
            child: QrImageView(
              data: address,
              size: 200,
              padding: EdgeInsets.zero,
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF2C170C)),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Color(0xFF2C170C),
              ),
            ),
          ),
          const SizedBox(height: 18),
          SectionHeader(label: heading, padding: const EdgeInsets.only(bottom: 9)),
          GestureDetector(
            onTap: onTap,
            child: Text(
              address,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Ubuntu Mono',
                fontSize: 12.5,
                height: 1.7,
                color: BrandColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
