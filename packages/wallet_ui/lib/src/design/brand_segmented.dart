import 'package:flutter/material.dart';

import 'brand.dart';

/// Tinted-track segmented control with a raised pill for the selected option.
/// [dense] is the compact bordered variant (Receive's address-type toggle);
/// the default is the roomier shadowed variant (connection type, send priority).
class BrandSegmented extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final bool dense;

  const BrandSegmented({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onSelect,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(dense ? 4 : 3),
      decoration: BoxDecoration(
        color: BrandColors.surfaceTinted,
        border: dense ? Border.all(color: BrandColors.border) : null,
        borderRadius: BorderRadius.circular(dense ? 15 : 14),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i != 0 && dense) const SizedBox(width: 4),
            Expanded(child: _segment(i)),
          ],
        ],
      ),
    );
  }

  Widget _segment(int i) {
    final selected = i == selectedIndex;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onSelect(i),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: dense ? 9 : 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? (dense ? BrandColors.card : BrandColors.paper) : Colors.transparent,
          border: dense
              ? Border.all(color: selected ? BrandColors.borderStrong : Colors.transparent)
              : null,
          borderRadius: BorderRadius.circular(11),
          boxShadow: !dense && selected
              ? [
                  BoxShadow(
                    color: BrandColors.ink.withValues(alpha: 0.08),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Text(
          labels[i],
          style: TextStyle(
            fontSize: dense ? 13.5 : 13,
            height: 1,
            fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
            color: selected ? BrandColors.ink : BrandColors.inkMuted,
          ),
        ),
      ),
    );
  }
}
