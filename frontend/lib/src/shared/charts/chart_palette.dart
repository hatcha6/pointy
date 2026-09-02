import 'package:flutter/material.dart';

import '../design/design.dart';

/// Series colours for every Pointy chart.
///
/// Charts never take a colour from their caller. A series is identified by its
/// index, and the palette resolves that index against the active theme, so the
/// same chart reads correctly in light and dark mode and no caller can drift
/// away from the product palette.
abstract final class PointyChartPalette {
  /// Ordered, categorical series colours.
  static List<Color> series(BuildContext context) {
    final colors = context.pointyColors;
    return <Color>[
      colors.primaryStrong,
      colors.accentAmber,
      colors.success,
      colors.danger,
      colors.primaryDark,
      colors.warning,
    ];
  }

  /// The colour for series [index], wrapping around when there are more series
  /// than palette entries.
  static Color seriesAt(BuildContext context, int index) {
    final palette = series(context);
    return palette[index % palette.length];
  }

  /// Grid, axis and border colour.
  static Color grid(BuildContext context) => context.pointyColors.line;

  /// Axis label colour.
  static Color axisLabel(BuildContext context) => context.pointyColors.mutedInk;
}

/// How a chart axis or value should be formatted.
enum PointyChartValueKind {
  /// A plain count.
  number,

  /// A money amount in the shop currency.
  money,

  /// A percentage where `1` means one percent.
  percent,
}
