import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../responsive/responsive.dart';

/// A masonry (staggered) grid that lays children into equal-width columns,
/// placing each next child into the column that is currently shortest.
///
/// Unlike a [Wrap]-based grid, a short card next to a tall one does not leave a
/// vertical gap: the following card flows up into the free space. This keeps
/// dense dashboards visually packed instead of leaving large empty bands under
/// short cards.
///
/// The grid is RTL-aware. Column 0 is laid out at the trailing (right) edge
/// under [TextDirection.rtl], so reading order flows naturally right-to-left.
///
/// The number of columns is derived from the incoming width: it fits as many
/// [minTileWidth]-wide columns as possible, clamped to [maxColumns]. The grid
/// must be given a bounded width (it is intended for vertically scrolling
/// surfaces); when handed an unbounded width it degrades gracefully to a single
/// stacked column.
class PointyMasonryGrid extends StatelessWidget {
  const PointyMasonryGrid({
    super.key,
    required this.children,
    this.minTileWidth = 300,
    this.maxColumns = 4,
    this.spacing,
  });

  final List<Widget> children;

  /// Smallest column width before the grid drops a column.
  final double minTileWidth;

  /// Upper bound on column count regardless of available width.
  final int maxColumns;

  /// Gap between columns and between stacked cards. Defaults to the adaptive
  /// medium spacing for the current breakpoint.
  final double? spacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }
    final resolvedSpacing = spacing ?? AdaptiveSpacing.of(context).md;
    return _MasonryGrid(
      minTileWidth: minTileWidth,
      maxColumns: maxColumns < 1 ? 1 : maxColumns,
      spacing: resolvedSpacing,
      textDirection: Directionality.of(context),
      children: children,
    );
  }
}

class _MasonryGrid extends MultiChildRenderObjectWidget {
  const _MasonryGrid({
    required this.minTileWidth,
    required this.maxColumns,
    required this.spacing,
    required this.textDirection,
    required super.children,
  });

  final double minTileWidth;
  final int maxColumns;
  final double spacing;
  final TextDirection textDirection;

  @override
  _RenderMasonryGrid createRenderObject(BuildContext context) {
    return _RenderMasonryGrid(
      minTileWidth: minTileWidth,
      maxColumns: maxColumns,
      spacing: spacing,
      textDirection: textDirection,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMasonryGrid renderObject,
  ) {
    renderObject
      ..minTileWidth = minTileWidth
      ..maxColumns = maxColumns
      ..spacing = spacing
      ..textDirection = textDirection;
  }
}

class _MasonryParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderMasonryGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _MasonryParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _MasonryParentData> {
  _RenderMasonryGrid({
    required double minTileWidth,
    required int maxColumns,
    required double spacing,
    required TextDirection textDirection,
  }) : _minTileWidth = minTileWidth,
       _maxColumns = maxColumns,
       _spacing = spacing,
       _textDirection = textDirection;

  double _minTileWidth;
  double get minTileWidth => _minTileWidth;
  set minTileWidth(double value) {
    if (_minTileWidth == value) return;
    _minTileWidth = value;
    markNeedsLayout();
  }

  int _maxColumns;
  int get maxColumns => _maxColumns;
  set maxColumns(int value) {
    if (_maxColumns == value) return;
    _maxColumns = value;
    markNeedsLayout();
  }

  double _spacing;
  double get spacing => _spacing;
  set spacing(double value) {
    if (_spacing == value) return;
    _spacing = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MasonryParentData) {
      child.parentData = _MasonryParentData();
    }
  }

  int _resolveColumns(double width) {
    if (!width.isFinite || width <= 0) {
      return 1;
    }
    final fit = (width / _minTileWidth).floor();
    return fit.clamp(1, _maxColumns);
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;

    // Unbounded width: degrade to a single stacked column with loose
    // constraints so the grid never throws in unusual hosts.
    if (!width.isFinite) {
      var y = 0.0;
      RenderBox? child = firstChild;
      while (child != null) {
        final parentData = child.parentData! as _MasonryParentData;
        child.layout(const BoxConstraints(), parentUsesSize: true);
        parentData.offset = Offset(0, y);
        y += child.size.height + _spacing;
        child = parentData.nextSibling;
      }
      size = constraints.constrain(Size(0, y > 0 ? y - _spacing : 0));
      return;
    }

    final columns = _resolveColumns(width);
    final columnWidth = (width - (columns - 1) * _spacing) / columns;
    final columnStride = columnWidth + _spacing;
    final columnHeights = List<double>.filled(columns, 0.0);
    final childConstraints = BoxConstraints.tightFor(width: columnWidth);

    RenderBox? child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as _MasonryParentData;
      child.layout(childConstraints, parentUsesSize: true);

      // Pick the shortest column; ties resolve to the lowest index so equal
      // rows fill in reading order.
      var target = 0;
      for (var column = 1; column < columns; column += 1) {
        if (columnHeights[column] < columnHeights[target] - 0.01) {
          target = column;
        }
      }

      final y = columnHeights[target];
      final x = _textDirection == TextDirection.rtl
          ? width - target * columnStride - columnWidth
          : target * columnStride;
      parentData.offset = Offset(x, y);
      columnHeights[target] = y + child.size.height + _spacing;

      child = parentData.nextSibling;
    }

    var contentHeight = 0.0;
    for (final height in columnHeights) {
      final adjusted = height > 0 ? height - _spacing : 0.0;
      if (adjusted > contentHeight) {
        contentHeight = adjusted;
      }
    }
    size = constraints.constrain(Size(width, contentHeight));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}
