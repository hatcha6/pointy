import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'chart_formatting.dart';
import 'chart_palette.dart';
import 'chart_scaffold.dart';
import 'pointy_chart_data.dart';

/// A categorical comparison. Multiple series render as grouped bars.
class PointyBarChart extends StatelessWidget {
  const PointyBarChart({
    super.key,
    required this.series,
    this.valueKind = PointyChartValueKind.money,
    this.height = PointyChartScaffold.defaultHeight,
    this.horizontal = false,
  });

  final List<PointyChartSeries> series;
  final PointyChartValueKind valueKind;
  final double height;

  /// Lay the bars along the horizontal axis, which reads better for long
  /// category names such as product titles.
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final drawable = series.where((s) => s.points.isNotEmpty).toList();
    if (drawable.isEmpty || drawable.every((s) => s.isEmpty)) {
      return PointyChartScaffold.empty(height: height);
    }
    final categories = drawable.first.points
        .map((point) => point.label)
        .toList(growable: false);
    final maxY = chartMaxValue(
      drawable.expand((s) => s.points).map((point) => point.value),
    );
    final barWidth = switch (categories.length) {
      <= 6 => 22.0,
      <= 12 => 14.0,
      <= 24 => 9.0,
      _ => 5.0,
    };
    return PointyChartScaffold(
      height: height,
      legend: drawable.length > 1
          ? [for (final s in drawable) s.name]
          : const <String>[],
      child: BarChart(
        BarChartData(
          maxY: maxY,
          alignment: BarChartAlignment.spaceAround,
          gridData: chartGridData(context),
          borderData: FlBorderData(show: false),
          titlesData: chartAxisTitles(
            context,
            valueKind: valueKind,
            categories: categories,
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                return BarTooltipItem(
                  formatChartValue(rod.toY, valueKind),
                  Theme.of(context).textTheme.labelSmall ?? const TextStyle(),
                );
              },
            ),
          ),
          barGroups: [
            for (var i = 0; i < categories.length; i += 1)
              BarChartGroupData(
                x: i,
                barRods: [
                  for (var s = 0; s < drawable.length; s += 1)
                    if (i < drawable[s].points.length)
                      BarChartRodData(
                        toY: drawable[s].points[i].value,
                        width: barWidth,
                        borderRadius: BorderRadius.circular(4),
                        color: PointyChartPalette.seriesAt(context, s),
                      ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
