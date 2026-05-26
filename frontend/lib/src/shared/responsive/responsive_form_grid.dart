import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'adaptive_spacing.dart';
import 'app_breakpoints.dart';

class ResponsiveFormGrid extends StatelessWidget {
  const ResponsiveFormGrid({
    super.key,
    required this.children,
    this.minChildWidth = 220,
    this.maxColumns = 3,
    this.spacing,
    this.runSpacing,
  });

  final List<Widget> children;
  final double minChildWidth;
  final int maxColumns;
  final double? spacing;
  final double? runSpacing;

  static int columnCountForWidth(
    double width, {
    double minChildWidth = 220,
    int maxColumns = 3,
    double spacing = 12,
  }) {
    final breakpointLimit = switch (AppBreakpoints.forWidth(width)) {
      AppBreakpoint.phone => 1,
      AppBreakpoint.largePhone => math.min(2, maxColumns),
      AppBreakpoint.tablet => math.min(3, maxColumns),
      AppBreakpoint.desktop => math.min(4, maxColumns),
      AppBreakpoint.widePos => maxColumns,
    };
    final fitLimit = math.max(
      1,
      ((width + spacing) / (minChildWidth + spacing)).floor(),
    );

    return math.max(1, math.min(breakpointLimit, fitLimit));
  }

  static double itemWidthForWidth(
    double width, {
    double minChildWidth = 220,
    int maxColumns = 3,
    double spacing = 12,
  }) {
    final columns = columnCountForWidth(
      width,
      minChildWidth: minChildWidth,
      maxColumns: maxColumns,
      spacing: spacing,
    );
    final totalSpacing = spacing * (columns - 1);
    return (width - totalSpacing) / columns;
  }

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = _effectiveWidth(context, constraints);
        final adaptiveSpacing = AdaptiveSpacing.fromWidth(width);
        final resolvedSpacing = spacing ?? adaptiveSpacing.formGap;
        final resolvedRunSpacing = runSpacing ?? resolvedSpacing;
        final itemWidth = itemWidthForWidth(
          width,
          minChildWidth: minChildWidth,
          maxColumns: maxColumns,
          spacing: resolvedSpacing,
        );

        return Wrap(
          spacing: resolvedSpacing,
          runSpacing: resolvedRunSpacing,
          children: [
            for (final child in children)
              SizedBox(width: itemWidth, child: child),
          ],
        );
      },
    );
  }

  double _effectiveWidth(BuildContext context, BoxConstraints constraints) {
    if (constraints.hasBoundedWidth) {
      return constraints.maxWidth;
    }
    return MediaQuery.sizeOf(context).width;
  }
}
