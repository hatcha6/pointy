import 'package:flutter/foundation.dart';

/// One plotted value with the label shown on the category axis.
@immutable
class PointyChartPoint {
  const PointyChartPoint({required this.label, required this.value});

  final String label;
  final double value;
}

/// A named run of points. Charts colour a series by its position in the list,
/// never by a caller-supplied colour.
@immutable
class PointyChartSeries {
  const PointyChartSeries({required this.name, required this.points});

  final String name;
  final List<PointyChartPoint> points;

  bool get isEmpty => points.isEmpty || points.every((p) => p.value == 0);
}

/// One wedge of a donut chart.
@immutable
class PointyChartSlice {
  const PointyChartSlice({required this.label, required this.value});

  final String label;
  final double value;
}
