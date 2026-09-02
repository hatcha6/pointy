import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'chart_palette.dart';
import 'pointy_chart_data.dart';

/// A bare trend line for inline use beside a number. No axes, no grid, no
/// legend — it exists to show a shape, not to be read off.
class PointySparkline extends StatelessWidget {
  const PointySparkline({
    super.key,
    required this.points,
    this.height = 44,
    this.seriesIndex = 0,
  });

  final List<PointyChartPoint> points;
  final double height;
  final int seriesIndex;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return SizedBox(height: height);
    }
    final color = PointyChartPalette.seriesAt(context, seriesIndex);
    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          titlesData: const FlTitlesData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (var i = 0; i < points.length; i += 1)
                  FlSpot(i.toDouble(), points[i].value),
              ],
              isCurved: true,
              curveSmoothness: 0.25,
              preventCurveOverShooting: true,
              color: color,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: color.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
