import 'package:flutter/material.dart';

abstract final class PointyProductCardGrid {
  static const double minTileWidth = 168;
  static const double tileMainExtent = 236;
  static const double wideTileMainExtent = 252;
  static const double loadMoreExtent = 720;
  static const int maxColumnCount = 5;

  static SliverGridDelegateWithFixedCrossAxisCount delegateFor({
    required double width,
    required double spacing,
  }) {
    final columnCount = columnCountFor(width: width, spacing: spacing);
    final tileWidth = tileWidthFor(
      width: width,
      spacing: spacing,
      columnCount: columnCount,
    );

    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columnCount,
      mainAxisExtent: tileMainExtentFor(tileWidth),
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

  static double tileMainExtentFor(double tileWidth) {
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
