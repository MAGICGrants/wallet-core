import 'package:flutter/material.dart';
import 'package:wallet_fiat/wallet_fiat.dart' show FiatRateModel;

import '../design/balance_text.dart';
import '../design/brand.dart';
import '../design/section_header.dart';
import '../wallet/format.dart';

/// One asset's share of the total, for the [AllocationBar].
class AllocationSlice {
  final String label;
  final Color color;

  /// Fiat value; the bar works out the shares.
  final double value;

  const AllocationSlice({required this.label, required this.color, required this.value});
}

/// The big balance at the top of the home screen.
///
/// The fiat total leads when the price API is on. While the first rate loads a
/// placeholder holds its place; when the API failed, "--" with a warning. With
/// the API off there is no fiat at all: [coinText] becomes the headline, or,
/// with no single coin to show ([coinText] null, several coins), the hero
/// leaves the number out and shows only [footer].
class HomeBalanceHero extends StatelessWidget {
  /// Small caps label above the number ("Total balance"); null for none.
  final String? label;
  final FiatRateModel fiatRate;

  /// The fiat total, or null while the rate or balance is not known yet.
  final double? fiatTotal;

  /// The coin amount with its symbol ("8.23940 XMR"), for a one-coin wallet.
  final String? coinText;
  final String fiatErrorTooltip;

  /// Under the number: connection pills, or the [AllocationBar].
  final Widget? footer;

  const HomeBalanceHero({
    super.key,
    required this.fiatRate,
    required this.fiatTotal,
    required this.fiatErrorTooltip,
    this.label,
    this.coinText,
    this.footer,
  });

  static TextStyle get _big => BrandText.balance.copyWith(fontSize: 40, letterSpacing: -0.8);

  static TextStyle get _sub => TextStyle(
    fontFamily: 'Ubuntu Mono',
    fontSize: 15,
    height: 1,
    color: BrandColors.inkMuted,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    final disabled = fiatRate.isDisabled;
    final failed = !disabled && fiatRate.hasFailed;

    final Widget? number;
    if (!disabled && fiatTotal != null) {
      number = FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: BalanceText.split(formatFiat(fiatTotal!, fiatRate.fiatCurrency), style: _big),
      );
    } else if (failed) {
      number = Text('--', style: _big);
    } else if (!disabled) {
      number = const _NumberPlaceholder();
    } else if (coinText != null) {
      number = FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(coinText!, style: _big),
      );
    } else {
      number = null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null && number != null) ...[
          SectionHeader(label: label!, padding: EdgeInsets.zero),
          const SizedBox(height: 10),
        ],
        if (number != null)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(child: number),
              if (failed) ...[
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Tooltip(
                    message: fiatErrorTooltip,
                    child: Icon(Icons.warning_rounded, size: 18, color: BrandColors.warning),
                  ),
                ),
              ],
            ],
          ),
        // The coin amount under a fiat headline; it is the headline itself
        // when there is no fiat.
        if (coinText != null && !disabled) ...[
          const SizedBox(height: 10),
          Text(coinText!, style: _sub),
        ],
        if (footer != null) ...[SizedBox(height: number == null ? 0 : 14), footer!],
      ],
    );
  }
}

class _NumberPlaceholder extends StatelessWidget {
  const _NumberPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 190,
      height: 40,
      decoration: BoxDecoration(color: BrandColors.surfaceMuted, borderRadius: BrandRadii.rTile),
    );
  }
}

/// Each asset's share of the fiat total: a segmented bar and a legend with
/// percentages. Slices with no value are left out.
class AllocationBar extends StatelessWidget {
  final List<AllocationSlice> slices;

  const AllocationBar({super.key, required this.slices});

  @override
  Widget build(BuildContext context) {
    final shown = slices.where((s) => s.value > 0).toList();
    final total = shown.fold<double>(0, (a, s) => a + s.value);
    if (total <= 0) return const SizedBox.shrink();
    final percents = _percents([for (final s in shown) s.value / total]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        ClipRRect(
          borderRadius: BrandRadii.rPill,
          child: SizedBox(
            height: 10,
            child: Row(
              spacing: 3,
              children: [
                for (final s in shown)
                  Expanded(
                    // Flex wants whole numbers; per-mille keeps small shares visible.
                    flex: ((s.value / total) * 1000).round().clamp(1, 1000),
                    child: ColoredBox(color: s.color),
                  ),
              ],
            ),
          ),
        ),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            for (var i = 0; i < shown.length; i++)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: shown[i].color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(shown[i].label, style: BrandText.caption.copyWith(fontSize: 13)),
                  const SizedBox(width: 4),
                  Text('${percents[i]}%', style: BrandText.mono.copyWith(color: BrandColors.ink)),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// Whole percentages for [shares] that add up to 100 (largest remainder), so
/// the legend never reads 99% or 101%. A share that rounds to nothing still
/// shows as 1% when it is there at all.
List<int> _percents(List<double> shares) {
  final raw = [for (final s in shares) s * 100];
  final out = [for (final r in raw) r.floor()];
  var left = 100 - out.fold<int>(0, (a, b) => a + b);
  final order = List.generate(raw.length, (i) => i)
    ..sort((a, b) => (raw[b] - out[b]).compareTo(raw[a] - out[a]));
  for (final i in order) {
    if (left <= 0) break;
    out[i]++;
    left--;
  }
  for (var i = 0; i < out.length; i++) {
    if (out[i] == 0 && shares[i] > 0) {
      out[i] = 1;
      // Taken from the largest share, so the total stays 100.
      var largest = 0;
      for (var j = 1; j < out.length; j++) {
        if (out[j] > out[largest]) largest = j;
      }
      out[largest]--;
    }
  }
  return out;
}
