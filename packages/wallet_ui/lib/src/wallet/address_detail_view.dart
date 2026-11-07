import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:wallet_domain/wallet_domain.dart';

import '../design/brand.dart';
import '../design/brand_button.dart';
import '../design/brand_card.dart';
import '../design/brand_screen_header.dart';
import '../design/icon_circle_button.dart';
import '../design/share_anchor.dart';
import '../l10n/wallet_ui_localizations.dart';
import 'labeled_addresses.dart';
import 'receive_view.dart';

/// One used address's own screen, on a phone: its QR to hand it out again, what
/// it received, and the way to its transactions and its label. The app supplies
/// [body] (an [AddressDetailContent]) with the height the QR may grow to.
class AddressDetailView extends StatelessWidget {
  const AddressDetailView({
    super.key,
    required this.title,
    required this.onBack,
    required this.body,
    this.onShare,
  });

  /// The label, or "Subaddress #12" when it has none.
  final String title;
  final VoidCallback onBack;

  /// Gets the viewport's height, which caps how far the QR may grow.
  final Widget Function(double viewportHeight) body;

  /// The header's share button; null hides it. Gets the button's rect, for the
  /// iOS share popover ([shareAnchorRect]).
  final ValueChanged<Rect?>? onShare;

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
                    center: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BrandText.appBar.copyWith(fontSize: 16),
                    ),
                    action: onShare == null
                        ? null
                        : Builder(
                            builder: (context) => IconCircleButton(
                              icon: Icons.ios_share,
                              onPressed: () => onShare!(shareAnchorRect(context)),
                            ),
                          ),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, viewport) => ListView(
                      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
                      children: [body(viewport.maxHeight)],
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

/// The address screen's content, on a phone ([AddressDetailView]) or inside a
/// desktop shell ([wide]: the QR beside the rest once there is room).
class AddressDetailContent extends StatelessWidget {
  const AddressDetailContent({
    super.key,
    required this.strings,
    required this.coin,
    required this.entry,
    required this.onCopy,
    required this.onTransactions,
    required this.onEditLabel,
    required this.viewportHeight,
    this.qrEnlarged = false,
    this.onToggleQr,
    this.wide = false,
  });

  final WalletUiLocalizations strings;
  final LabeledAddressCoin coin;
  final LabeledAddress entry;
  final VoidCallback onCopy;

  /// Opens History filtered to this address.
  final VoidCallback onTransactions;

  /// Opens the label sheet.
  final VoidCallback onEditLabel;
  final double viewportHeight;
  final bool qrEnlarged;

  /// Null keeps the QR at its normal size and hides the hint.
  final VoidCallback? onToggleQr;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final used = entry.used;
    final qr = ReceiveQrCard(
      address: used.address,
      heading: labeledAddressName(strings, coin.kind, used.index),
      onCopy: onCopy,
      enlarged: qrEnlarged,
      onToggle: onToggleQr,
      hint: onToggleQr == null
          ? null
          : (qrEnlarged ? strings.receiveShrinkQr : strings.receiveEnlargeQr),
      viewportHeight: viewportHeight,
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Stats(strings: strings, coin: coin, used: used),
        const SizedBox(height: 14),
        BrandButton(
          label: strings.receiveCopyAddress,
          icon: Icons.copy_outlined,
          onPressed: onCopy,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: BrandButton.secondary(
                label: strings.addressDetailTransactions,
                icon: Icons.history,
                onPressed: onTransactions,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: BrandButton.secondary(
                label: entry.label == null
                    ? strings.addressDetailAddLabel
                    : strings.addressDetailEditLabel,
                icon: Icons.edit_outlined,
                onPressed: onEditLabel,
              ),
            ),
          ],
        ),
      ],
    );
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [qr, const SizedBox(height: 12), details],
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [qr, const SizedBox(height: 20), details],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 340, child: qr),
            const SizedBox(width: 28),
            Expanded(child: details),
          ],
        );
      },
    );
  }
}

/// Received, Transactions, Last Transaction.
class _Stats extends StatelessWidget {
  const _Stats({required this.strings, required this.coin, required this.used});

  final WalletUiLocalizations strings;
  final LabeledAddressCoin coin;
  final UsedReceiveAddress used;

  @override
  Widget build(BuildContext context) {
    // Default symbols only: initializeDateFormatting is not wired, as for the
    // tx details sheet's date.
    final last = DateFormat('d MMM yyyy')
        .format(DateTime.fromMillisecondsSinceEpoch(used.lastUsed * 1000));
    return BrandCard(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _stat(strings.coinHomeReceived, labeledAddressTotal(used.receivedBaseUnits, coin)),
            VerticalDivider(width: 1, thickness: 1, color: BrandColors.hairline),
            _stat(strings.addressDetailTransactions, '${used.txCount}'),
            VerticalDivider(width: 1, thickness: 1, color: BrandColors.hairline),
            _stat(strings.addressDetailLastTransaction, last),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: BrandText.caption),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: BrandText.amount.copyWith(fontSize: 14)),
          ),
        ],
      ),
    ),
  );
}
