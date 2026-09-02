import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../components/components.dart';
import '../design/design.dart';
import 'chart_formatting.dart';
import 'chart_palette.dart';

/// Shared chrome for every Pointy chart: fixed height, optional legend, and a
/// single empty state. Callers never set a height in pixels themselves.
class PointyChartScaffold extends StatelessWidget {
  const PointyChartScaffold({
    super.key,
    required this.child,
    this.height = defaultHeight,
    this.legend = const <String>[],
  });

  static const double defaultHeight = 220;
  static const double compactHeight = 120;

  final Widget child;
  final double height;
  final List<String> legend;

  /// The "no data for this chart" state, at the same height so a card does not
  /// jump when data arrives.
  static Widget empty({double height = defaultHeight}) {
    return _EmptyChart(height: height);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(height: height, child: child),
        if (legend.isNotEmpty) ...[
          const SizedBox(height: 12),
          _ChartLegend(entries: legend),
        ],
      ],
    );
  }
}

class _EmptyChart extends StatelessWidget {
  const _EmptyChart({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: PointyEmptyState(
        icon: Icons.insights_outlined,
        title: AppLocalizations.of(context)!.dashboardNoWidgetData,
      ),
    );
  }
}

class _ChartLegend extends StatelessWidget {
  const _ChartLegend({required this.entries});

  final List<String> entries;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: context.pointyColors.mutedInk);
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (var index = 0; index < entries.length; index += 1)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: PointyChartPalette.seriesAt(context, index),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 6),
              Text(entries[index], style: textStyle),
            ],
          ),
      ],
    );
  }
}

/// Grid lines in the palette's line colour, horizontal only.
FlGridData chartGridData(BuildContext context) {
  return FlGridData(
    show: true,
    drawVerticalLine: false,
    getDrawingHorizontalLine: (value) =>
        FlLine(color: PointyChartPalette.grid(context), strokeWidth: 1),
  );
}

/// Value axis on the left, category axis at the bottom when labels are given.
FlTitlesData chartAxisTitles(
  BuildContext context, {
  required PointyChartValueKind valueKind,
  required List<String> categories,
}) {
  final textStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
    color: PointyChartPalette.axisLabel(context),
  );
  // Show at most eight category labels so they never collide.
  final step = categories.length <= 8 ? 1 : (categories.length / 8).ceil();
  return FlTitlesData(
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 46,
        getTitlesWidget: (value, meta) {
          if (value == meta.max) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: Text(
              formatChartAxisValue(value, valueKind),
              style: textStyle,
              textAlign: TextAlign.center,
              textDirection: TextDirection.ltr,
            ),
          );
        },
      ),
    ),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: categories.isNotEmpty,
        reservedSize: 28,
        // Ask for a label at each whole category only. Without this the chart
        // samples fractional positions, several of which round to the same
        // index and draw the same label twice.
        interval: 1,
        getTitlesWidget: (value, meta) {
          final index = value.round();
          if (index < 0 || index >= categories.length) {
            return const SizedBox.shrink();
          }
          if (index % step != 0) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              categories[index],
              style: textStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        },
      ),
    ),
  );
}
