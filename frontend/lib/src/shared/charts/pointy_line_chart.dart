import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'chart_formatting.dart';
import 'chart_palette.dart';
import 'chart_scaffold.dart';
import 'pointy_chart_data.dart';

/// A trend over time. One line per series, area-filled for a single series.
class PointyLineChart extends StatelessWidget {
  const PointyLineChart({
    super.key,
    required this.series,
    this.valueKind = PointyChartValueKind.money,
    this.height = PointyChartScaffold.defaultHeight,
    this.showCategoryLabels = true,
  });

  final List<PointyChartSeries> series;
  final PointyChartValueKind valueKind;
  final double height;
  final bool showCategoryLabels;

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
    return PointyChartScaffold(
      height: height,
      legend: drawable.length > 1
          ? [for (final s in drawable) s.name]
          : const <String>[],
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY,
          gridData: chartGridData(context),
          borderData: FlBorderData(show: false),
          titlesData: chartAxisTitles(
            context,
            valueKind: valueKind,
            categories: showCategoryLabels ? categories : const <String>[],
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipItems: (spots) => [
                for (final spot in spots)
                  LineTooltipItem(
                    formatChartValue(spot.y, valueKind),
                    Theme.of(context).textTheme.labelSmall ?? const TextStyle(),
                  ),
              ],
            ),
          ),
          lineBarsData: [
            for (var index = 0; index < drawable.length; index += 1)
              LineChartBarData(
                spots: [
                  for (var i = 0; i < drawable[index].points.length; i += 1)
                    FlSpot(i.toDouble(), drawable[index].points[i].value),
                ],
                isCurved: true,
                curveSmoothness: 0.25,
                preventCurveOverShooting: true,
                color: PointyChartPalette.seriesAt(context, index),
                barWidth: 3,
                dotData: FlDotData(show: drawable[index].points.length <= 12),
                belowBarData: BarAreaData(
                  show: drawable.length == 1,
                  color: PointyChartPalette.seriesAt(
                    context,
                    index,
                  ).withValues(alpha: 0.14),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
