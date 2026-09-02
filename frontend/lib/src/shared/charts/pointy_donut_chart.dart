import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../design/design.dart';
import 'chart_formatting.dart';
import 'chart_palette.dart';
import 'chart_scaffold.dart';
import 'pointy_chart_data.dart';

/// A share-of-total breakdown. Slice labels live in the legend, not on the
/// wedges, so Arabic category names stay readable.
class PointyDonutChart extends StatelessWidget {
  const PointyDonutChart({
    super.key,
    required this.slices,
    this.valueKind = PointyChartValueKind.money,
    this.height = PointyChartScaffold.defaultHeight,
  });

  final List<PointyChartSlice> slices;
  final PointyChartValueKind valueKind;
  final double height;

  @override
  Widget build(BuildContext context) {
    final drawable = slices
        .where((slice) => slice.value.abs() > 0)
        .toList(growable: false);
    if (drawable.isEmpty) {
      return PointyChartScaffold.empty(height: height);
    }
    final total = drawable.fold<double>(0, (sum, s) => sum + s.value.abs());
    return PointyChartScaffold(
      height: height,
      legend: [for (final slice in drawable) slice.label],
      child: PieChart(
        PieChartData(
          centerSpaceRadius: height * 0.21,
          sectionsSpace: 2,
          pieTouchData: PieTouchData(enabled: true),
          sections: [
            for (var index = 0; index < drawable.length; index += 1)
              PieChartSectionData(
                value: drawable[index].value.abs(),
                title: _shareLabel(drawable[index].value.abs(), total),
                radius: height * 0.33,
                color: PointyChartPalette.seriesAt(context, index),
                titleStyle: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: context.pointyColors.surface,
                  fontWeight: FontWeight.w700,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _shareLabel(double value, double total) {
    if (total <= 0) return '';
    final share = value / total * 100;
    if (share < 6) return '';
    return formatChartAxisValue(share, PointyChartValueKind.percent);
  }
}
