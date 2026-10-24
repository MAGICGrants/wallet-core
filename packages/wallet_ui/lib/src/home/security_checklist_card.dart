import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/click_cursor.dart';
import 'home_card.dart';

/// One step on the security checklist. An open step is tappable and takes the
/// user to where it is done; a finished one is struck through.
class ChecklistItem {
  final String label;
  final bool done;
  final VoidCallback onTap;

  const ChecklistItem({required this.label, required this.done, required this.onTap});
}

/// "Secure your wallet": a count, a progress bar, and the steps.
class SecurityChecklistCard extends StatelessWidget {
  final String title;

  /// "2 of 5".
  final String Function(int done, int total) progressLabel;
  final List<ChecklistItem> items;

  const SecurityChecklistCard({
    super.key,
    required this.title,
    required this.progressLabel,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final done = items.where((i) => i.done).length;
    return HomeCard(
      children: [
        HomeCardTitle(
          icon: Icons.shield_outlined,
          title: title,
          trailing: Text(progressLabel(done, items.length), style: homeMonoCaption),
        ),
        HomeProgressBar(
          value: items.isEmpty ? 0 : done / items.length,
          color: BrandColors.success,
          height: 6,
        ),
        Column(children: [for (final item in items) _ChecklistRow(item: item)]),
      ],
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  final ChecklistItem item;

  const _ChecklistRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final done = item.done;
    final mark = done
        ? Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: BrandColors.success, shape: BoxShape.circle),
            child: const Icon(Icons.check_rounded, size: 15, color: BrandColors.onPrimary),
          )
        : Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: BrandColors.borderStrong, width: 2),
            ),
          );
    final row = ConstrainedBox(
      // A comfortable touch target for the open steps.
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          mark,
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.label,
              style: TextStyle(
                fontSize: 14,
                height: 1.3,
                color: done ? BrandColors.inkMuted : BrandColors.ink,
                decoration: done ? TextDecoration.lineThrough : null,
                decorationColor: BrandColors.inkMuted,
              ),
            ),
          ),
          if (!done) Icon(Icons.chevron_right, size: 18, color: BrandColors.inkMuted),
        ],
      ),
    );
    final semantics = Semantics(button: !done, checked: done, child: row);
    if (done) return semantics;
    return Tappable(onTap: item.onTap, child: semantics);
  }
}
