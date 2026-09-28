import 'package:flutter/material.dart';

abstract final class PointyProductCardGrid {
  /// Narrow enough that the catalog beside a 1024px till's cart holds three
  /// cards across rather than two oversized ones.
  static const double minTileWidth = 156;
  static const double tileMainExtent = 236;
  static const double wideTileMainExtent = 252;

  /// Card height on a short screen (see `AppBreakpoints.isShortHeight`). The
  /// image well gives up the height; the code, name and price keep theirs, so
  /// a 1024×768 or 1366×768 till shows two full rows of cards, not one and a
  /// half.
  static const double shortTileMainExtent = 200;
  static const double loadMoreExtent = 720;
  static const int maxColumnCount = 5;

  static SliverGridDelegateWithFixedCrossAxisCount delegateFor({
    required double width,
    required double spacing,
    bool short = false,
  }) {
    final columnCount = columnCountFor(width: width, spacing: spacing);
    final tileWidth = tileWidthFor(
      width: width,
      spacing: spacing,
      columnCount: columnCount,
    );

    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columnCount,
      mainAxisExtent: tileMainExtentFor(tileWidth, short: short),
      crossAxisSpacing: _normalizedSpacing(spacing),
      mainAxisSpacing: _normalizedSpacing(spacing),
    );
  }

  static int columnCountFor({required double width, required double spacing}) {
    if (!width.isFinite || width <= 0) {
      return 1;
    }

    final gap = _normalizedSpacing(spacing);
    final count = ((width + gap) / (minTileWidth + gap)).floor();
    return count.clamp(1, maxColumnCount).toInt();
  }

  static double tileWidthFor({
    required double width,
    required double spacing,
    required int columnCount,
  }) {
    if (!width.isFinite || width <= 0 || columnCount <= 0) {
      return minTileWidth;
    }

    final gap = _normalizedSpacing(spacing);
    return (width - (gap * (columnCount - 1))) / columnCount;
  }

  static double tileMainExtentFor(double tileWidth, {bool short = false}) {
    if (short) {
      return shortTileMainExtent;
    }
    if (tileWidth >= 260) {
      return wideTileMainExtent;
    }
    return tileMainExtent;
  }

  static double _normalizedSpacing(double spacing) {
    if (!spacing.isFinite || spacing < 0) {
      return 0;
    }
    return spacing;
  }
}
