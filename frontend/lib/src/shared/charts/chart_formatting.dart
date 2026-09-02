import 'package:intl/intl.dart';

import '../formatters.dart';
import 'chart_palette.dart';

final NumberFormat _compactFormat = NumberFormat.compact(locale: 'en');
final NumberFormat _plainFormat = NumberFormat.decimalPattern('en');

/// Formats a value for an axis label: short, so it fits, and always LTR digits.
String formatChartAxisValue(double value, PointyChartValueKind kind) {
  return switch (kind) {
    PointyChartValueKind.percent => '${_trimDecimal(value)}%',
    PointyChartValueKind.money ||
    PointyChartValueKind.number => _compactFormat.format(value),
  };
}

/// Formats a value for a tooltip or a data label, where there is room for the
/// exact figure.
String formatChartValue(double value, PointyChartValueKind kind) {
  return switch (kind) {
    PointyChartValueKind.money => formatMoney(value),
    PointyChartValueKind.percent => '${_trimDecimal(value)}%',
    PointyChartValueKind.number => _plainFormat.format(value),
  };
}

String _trimDecimal(double value) {
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toStringAsFixed(1);
}

/// The upper bound for a value axis: the largest value with headroom, never
/// zero (fl_chart draws nothing when min and max are both zero).
double chartMaxValue(Iterable<double> values) {
  final max = values.fold<double>(0, (current, value) {
    return value > current ? value : current;
  });
  return max <= 0 ? 1 : max * 1.25;
}
