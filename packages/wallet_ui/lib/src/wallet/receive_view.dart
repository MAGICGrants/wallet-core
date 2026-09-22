import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_card.dart';
import '../design/brand_screen_header.dart';
import '../design/brand_segmented.dart';
import '../design/icon_circle_button.dart';
import '../design/section_header.dart';
import '../design/share_anchor.dart';
import 'coin_mark.dart';

/// Translated strings for [ReceiveView]. Injected so the view stays
/// localization-agnostic — each app passes its own generated l10n.
class ReceiveLabels {
  final String title;
  final String copyAddress;

  /// The tappable hint under the QR, at its normal size and while enlarged.
  final String enlargeQr;
  final String shrinkQr;

  const ReceiveLabels({
    required this.title,
    required this.copyAddress,
    required this.enlargeQr,
    required this.shrinkQr,
  });
}

/// The receive screen: a coin card, an optional subaddress/primary segmented
/// toggle, a white QR panel with the tappable mono address, an optional warning
/// line, and a Copy button. Presentational only — the app computes the
/// address/heading/warning + tab and enlarge state and supplies the callbacks.
///
/// The QR panel is fixed dark-on-white so it always scans, regardless of theme.
/// Tapping it (or the hint under it) grows it in place to fill the screen; what
/// else happens then, such as raising the brightness, is the app's call.
class ReceiveView extends StatelessWidget {
  final ReceiveLabels labels;
  final VoidCallback onBack;

  /// Mobile share header action; null hides the header share button.
  ///
  /// Receives the share button's global rect, which iOS needs to anchor the
  /// share popover -- pass it through as `ShareParams.sharePositionOrigin`.
  /// Null when the button could not be measured; see [shareAnchorRect].
  final ValueChanged<Rect?>? onShare;

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

  /// Whether the QR is grown to fill the screen.
  final bool qrEnlarged;

  /// Flips [qrEnlarged], from a tap on the QR or on the hint under it. Null
  /// keeps the QR at its normal size and hides the hint.
  final VoidCallback? onToggleQr;

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
    this.qrEnlarged = false,
    this.onToggleQr,
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
                    // Builder so the rect handed to [onShare] is the share
                    // button's own, not the whole screen's: it is what the iOS
                    // share popover points at.
                    action: onShare != null
                        ? Builder(
                            builder: (context) => IconCircleButton(
                              icon: Icons.ios_share,
                              onPressed: ready ? () => onShare!(shareAnchorRect(context)) : null,
                            ),
                          )
                        : null,
                  ),
                ),
                Expanded(
                  child: !ready
                      ? Center(child: CircularProgressIndicator(color: BrandColors.primary))
                      // The viewport's height caps how far the QR may grow.
                      : LayoutBuilder(
                          builder: (context, viewport) => ListView(
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
                              _QrCard(
                                address: address,
                                heading: qrHeading,
                                onCopy: onCopy,
                                enlarged: qrEnlarged,
                                onToggle: onToggleQr,
                                hint: qrEnlarged ? labels.shrinkQr : labels.enlargeQr,
                                viewportHeight: viewport.maxHeight,
                              ),
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
  final VoidCallback onCopy;
  final bool enlarged;
  final VoidCallback? onToggle;
  final String hint;
  final double viewportHeight;

  const _QrCard({
    required this.address,
    required this.heading,
    required this.onCopy,
    required this.enlarged,
    required this.onToggle,
    required this.hint,
    required this.viewportHeight,
  });

  /// The QR's side at its normal size.
  static const _normalSize = 200.0;

  /// The card's padding at normal size, and the tighter one that lets an
  /// enlarged QR reach closer to the edges of the screen.
  static const _padding = 24.0;
  static const _enlargedPadding = 12.0;
  static const _borderWidth = 1.0;

  /// The white margin around the modules, as a fraction of the QR's side: the
  /// quiet zone a scanner finds the code by. Proportional, so an enlarged code
  /// keeps as many modules' worth of it as a normal one (10px at 200px).
  static const _quietZone = 0.05;

  /// [_quietZone] for a QR of [size], in whole pixels. Floored, so the panel it
  /// makes is never wider than [_enlargedSize] allowed for.
  static double _margin(double size) => (size * _quietZone).floorToDouble();

  /// Room left above and below an enlarged QR, so it never quite touches the
  /// top and bottom of the viewport.
  static const _viewportMargin = 16.0;

  /// The side of an enlarged QR: as wide as the card allows, but never taller
  /// than the viewport, so the whole code is on screen in landscape too.
  double _enlargedSize(double cardWidth) {
    const panel = 1 + 2 * _quietZone;
    final fitWidth = (cardWidth - 2 * _borderWidth - 2 * _enlargedPadding) / panel;
    final fitHeight = (viewportHeight - 2 * _viewportMargin) / panel;
    // Floored so the panel never overflows the card by a rounding error.
    return math.max(_normalSize, math.min(fitWidth, fitHeight)).floorToDouble();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = enlarged ? _enlargedSize(constraints.maxWidth) : _normalSize;
        final margin = _margin(size);
        return BrandCard(
          radius: 22,
          borderWidth: _borderWidth,
          child: AnimatedPadding(
            duration: BrandMotion.transition,
            curve: Curves.easeInOut,
            padding: EdgeInsets.all(enlarged ? _enlargedPadding : _padding),
            child: Column(
              children: [
                // Builder so onEnd scrolls this panel into view, not the card.
                Builder(
                  builder: (panelContext) => GestureDetector(
                    onTap: onToggle,
                    // The hint below is the accessible control; announcing the
                    // QR as a second button for the same action is noise.
                    excludeFromSemantics: true,
                    child: AnimatedContainer(
                      duration: BrandMotion.transition,
                      curve: Curves.easeInOut,
                      width: size + 2 * margin,
                      height: size + 2 * margin,
                      padding: EdgeInsets.all(margin),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      // Grows downward: if that pushed the bottom off screen,
                      // scroll just far enough to bring it back.
                      onEnd: () {
                        if (!enlarged || !panelContext.mounted) return;
                        Scrollable.ensureVisible(
                          panelContext,
                          duration: BrandMotion.transition,
                          curve: Curves.easeInOut,
                          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
                        );
                      },
                      // The QR sits on a fixed white card so it scans, so its
                      // modules must stay dark in both themes — the themed ink
                      // goes light in dark mode. No size: it fills the panel.
                      child: QrImageView(
                        data: address,
                        padding: EdgeInsets.zero,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Color(0xFF2C170C),
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Color(0xFF2C170C),
                        ),
                      ),
                    ),
                  ),
                ),
                // Nothing overlaps the code itself: the affordance lives here,
                // clear of the modules and the quiet zone.
                if (onToggle != null) ...[
                  const SizedBox(height: 8),
                  _QrHint(
                    label: hint,
                    icon: enlarged ? Icons.close_fullscreen : Icons.open_in_full,
                    onTap: onToggle!,
                  ),
                  const SizedBox(height: 8),
                ] else
                  const SizedBox(height: 18),
                SectionHeader(label: heading, padding: const EdgeInsets.only(bottom: 9)),
                GestureDetector(
                  onTap: onCopy,
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
          ),
        );
      },
    );
  }
}

/// The tappable line under the QR. Styled as a dense ghost [BrandButton], but
/// its label wraps: a button's does not, and a translated or system-enlarged
/// hint can be longer than the card is wide.
class _QrHint extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _QrHint({required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = BrandColors.primaryDeep;
    const shape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12)));
    return Semantics(
      button: true,
      child: Material(
        type: MaterialType.transparency,
        shape: shape,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
            // The icon rides inline, so a wrapped hint keeps it beside the
            // first word rather than stranded at the edge of the card.
            child: Text.rich(
              TextSpan(
                children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(icon, size: 15, color: color),
                    ),
                  ),
                  TextSpan(text: label),
                ],
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.25,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
