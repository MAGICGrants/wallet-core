import 'package:flutter/material.dart';

import '../design/brand.dart';
import 'home_card.dart';

/// One payment on its way in: what it is, how far along, and how much.
class IncomingItem {
  final Widget icon;
  final String title;

  /// "Unlocks in about 8 minutes · 6 of 10", "0 of 1 confirmations".
  final String detail;

  /// Signed amount with its symbol, "+0.66180 XMR".
  final String amount;

  /// Confirmations so far over those needed, 0..1.
  final double progress;

  const IncomingItem({
    required this.icon,
    required this.title,
    required this.detail,
    required this.amount,
    required this.progress,
  });
}

/// Payments that have arrived but cannot be spent yet, each with a progress
/// bar toward its unlock. The home leaves the card out when there are none.
class IncomingCard extends StatelessWidget {
  final String title;
  final List<IncomingItem> items;

  const IncomingCard({super.key, required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return HomeCard(
      children: [
        HomeCardTitle(
          icon: Icons.hourglass_bottom_rounded,
          iconColor: BrandColors.warning,
          title: title,
        ),
        for (final item in items) _IncomingRow(item: item),
      ],
    );
  }
}

class _IncomingRow extends StatelessWidget {
  final IncomingItem item;

  const _IncomingRow({required this.item});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        Row(
          children: [
            item.icon,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: BrandColors.ink,
                    ),
                  ),
                  Text(item.detail, style: BrandText.caption.copyWith(fontSize: 13)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(item.amount, style: BrandText.amount.copyWith(color: BrandColors.success)),
          ],
        ),
        HomeProgressBar(value: item.progress, color: BrandColors.warning),
      ],
    );
  }
}
