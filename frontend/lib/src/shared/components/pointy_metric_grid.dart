import 'package:flutter/material.dart';

import '../responsive/responsive.dart';
import 'pointy_metric_tile.dart';

enum PointyMetricGridGap { compact, regular }

class PointyMetricGridItem {
  const PointyMetricGridItem({
    required this.label,
    required this.value,
    this.icon,
    this.subtitle,
    this.accentColor,
  });

  final String label;
  final String value;
  final IconData? icon;
  final String? subtitle;
  final Color? accentColor;
}

class PointyMetricGrid extends StatelessWidget {
  const PointyMetricGrid({
    super.key,
    required this.metrics,
    this.maxWidth,
    this.minTileWidth = 220,
    this.maxColumns = 3,
    this.gap = PointyMetricGridGap.regular,
    this.includeBottomSpacing = false,
  });

  final List<PointyMetricGridItem> metrics;
  final double? maxWidth;
  final double minTileWidth;
  final int maxColumns;
  final PointyMetricGridGap gap;
  final bool includeBottomSpacing;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final resolvedGap = switch (gap) {
      PointyMetricGridGap.compact => spacing.sm,
      PointyMetricGridGap.regular => spacing.md,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = _resolvedWidth(constraints);
        final tileWidth = _tileWidth(width, gap: resolvedGap);

        return Padding(
          padding: EdgeInsets.only(
            bottom: includeBottomSpacing ? spacing.md : 0,
          ),
          child: Wrap(
            spacing: resolvedGap,
            runSpacing: resolvedGap,
            children: [
              for (final metric in metrics)
                SizedBox(
                  width: tileWidth,
                  child: PointyMetricTile(
                    label: metric.label,
                    value: metric.value,
                    icon: metric.icon,
                    accentColor: metric.accentColor,
                    subtitle:
                        metric.subtitle == null || metric.subtitle!.isEmpty
                        ? null
                        : metric.subtitle,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  double _resolvedWidth(BoxConstraints constraints) {
    if (maxWidth != null) {
      return maxWidth!;
    }
    if (constraints.hasBoundedWidth) {
      return constraints.maxWidth;
    }
    return minTileWidth;
  }

  double _tileWidth(double width, {required double gap}) {
    final rawColumns = width ~/ minTileWidth;
    final columns = rawColumns.clamp(1, maxColumns).toInt();
    final gaps = (columns - 1) * gap;
    return (width - gaps) / columns;
  }
}
