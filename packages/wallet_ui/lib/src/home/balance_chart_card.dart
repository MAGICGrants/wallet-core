import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../design/brand.dart';
import '../design/section_header.dart';
import 'home_card.dart';

/// A balance from [at] on, until the next step: [at] is the position across
/// the chart, 0 at its left edge and 1 now.
typedef ChartStep = ({double at, double value});

/// One line on the balance chart: a coin's balance as steps, oldest first.
class BalanceSeries {
  /// The legend's text, the coin amount now: "12.4837 XMR".
  final String label;
  final Color color;
  final List<ChartStep> points;

  /// The change over the window: "+54%", "+5.1 XMR", "New".
  final String change;

  /// Whether the balance went up; an increase is shown in the success colour.
  final bool up;

  const BalanceSeries({
    required this.label,
    required this.color,
    required this.points,
    required this.change,
    required this.up,
  });
}

/// Dash patterns given to the lines in turn, so the coins stay apart without
/// relying on colour alone. The first line is solid.
const _dashes = <List<double>?>[
  null,
  [6, 4],
  [2, 4],
  [10, 3, 2, 3],
];

/// From this width the legend sits beside the chart rather than under it.
const _sideLegendWidth = 520.0;

/// "Balance · 90 days": each coin's balance over the window, drawn from its own
/// zero so the shape is honest. With one coin the change sits in the title row;
/// with several, each coin gets a legend row with its amount and change.
class BalanceChartCard extends StatelessWidget {
  final String title;

  /// Right of the title: the one coin's change, or a short caption.
  final String? note;
  final List<BalanceSeries> series;
  final String startLabel;
  final String endLabel;

  /// Shown in place of the chart while there is nothing to draw yet.
  final String? emptyText;

  const BalanceChartCard({
    super.key,
    required this.title,
    required this.series,
    required this.startLabel,
    required this.endLabel,
    this.note,
    this.emptyText,
  });

  @override
  Widget build(BuildContext context) {
    final single = series.length == 1;
    final noteStyle = single && series.first.up
        ? homeMonoCaption.copyWith(color: BrandColors.success, fontSize: 14)
        : homeMonoCaption.copyWith(fontSize: single ? 14 : 12);
    return HomeCard(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: SectionHeader(label: title, padding: EdgeInsets.zero),
            ),
            if (note != null) Text(note!, style: noteStyle),
          ],
        ),
        if (emptyText != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(emptyText!, style: BrandText.bodyMuted.copyWith(fontSize: 13)),
          )
        else ...[
          LayoutBuilder(
            builder: (context, constraints) {
              final chart = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  Semantics(
                    label: [for (final s in series) '${s.label} ${s.change}'].join(', '),
                    child: SizedBox(
                      height: 96,
                      width: double.infinity,
                      child: CustomPaint(painter: _BalanceChartPainter(series)),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(startLabel, style: homeMonoCaption.copyWith(fontSize: 12)),
                      Text(endLabel, style: homeMonoCaption.copyWith(fontSize: 12)),
                    ],
                  ),
                ],
              );
              if (single) return chart;
              final legend = Column(
                spacing: 4,
                children: [
                  for (var i = 0; i < series.length; i++)
                    _LegendRow(series: series[i], dash: _dashes[i % _dashes.length]),
                ],
              );
              // Wide enough (desktop): the legend beside the lines.
              if (constraints.maxWidth >= _sideLegendWidth) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(flex: 2, child: chart),
                    const SizedBox(width: 28),
                    Expanded(child: legend),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  chart,
                  Container(
                    padding: const EdgeInsets.only(top: 10),
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: BrandColors.hairline)),
                    ),
                    child: legend,
                  ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  final BalanceSeries series;
  final List<double>? dash;

  const _LegendRow({required this.series, required this.dash});

  @override
  Widget build(BuildContext context) {
    final mono = BrandText.amount.copyWith(fontWeight: FontWeight.w400);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 8,
            child: CustomPaint(painter: _SwatchPainter(series.color, dash)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(series.label, style: mono)),
          Text(
            series.change,
            style: BrandText.amount.copyWith(
              color: series.up ? BrandColors.success : BrandColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

/// Strokes [path] with [dash] (on, off, on, off…), or solid when null.
void _strokeDashed(Canvas canvas, Path path, Paint paint, List<double>? dash) {
  if (dash == null) {
    canvas.drawPath(path, paint);
    return;
  }
  for (final PathMetric metric in path.computeMetrics()) {
    var distance = 0.0;
    var i = 0;
    while (distance < metric.length) {
      final len = dash[i % dash.length];
      if (i.isEven) {
        canvas.drawPath(metric.extractPath(distance, distance + len), paint);
      }
      distance += len;
      i++;
    }
  }
}

class _BalanceChartPainter extends CustomPainter {
  final List<BalanceSeries> series;

  _BalanceChartPainter(this.series);

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 2.0;
    final w = size.width - inset * 2;
    final h = size.height - inset * 2;

    for (var s = 0; s < series.length; s++) {
      final points = series[s].points;
      if (points.isEmpty) continue;
      final top = points.map((p) => p.value).reduce(math.max);
      double x(double at) => inset + w * at;
      // Each line on its own zero-based scale: the balances differ by orders
      // of magnitude between coins, and the shape is what the chart is for.
      double y(double value) => inset + h - (top > 0 ? h * (value / top) : 0);
      // A balance holds until a transaction changes it: flat, then straight up
      // or down where it did.
      final path = Path()..moveTo(x(points.first.at), y(points.first.value));
      for (var i = 1; i < points.length; i++) {
        path
          ..lineTo(x(points[i].at), y(points[i - 1].value))
          ..lineTo(x(points[i].at), y(points[i].value));
      }
      path.lineTo(x(1), y(points.last.value));
      final paint = Paint()
        ..color = series[s].color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      _strokeDashed(canvas, path, paint, series.length == 1 ? null : _dashes[s % _dashes.length]);
    }
  }

  @override
  bool shouldRepaint(_BalanceChartPainter old) => !identical(old.series, series);
}

class _SwatchPainter extends CustomPainter {
  final Color color;
  final List<double>? dash;

  _SwatchPainter(this.color, this.dash);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final path = Path()
      ..moveTo(1, y)
      ..lineTo(size.width - 1, y);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    _strokeDashed(canvas, path, paint, dash);
  }

  @override
  bool shouldRepaint(_SwatchPainter old) => old.color != color || old.dash != dash;
}
