import 'package:flutter/material.dart';

import '../responsive/responsive.dart';

/// Lays out cards in equal-width columns that grow with the viewport, so wide
/// POS screens use their horizontal space instead of stacking full-width
/// cards. Cards keep their intrinsic height per row.
class PointyCardGrid extends StatelessWidget {
  const PointyCardGrid({
    super.key,
    required this.children,
    this.minTileWidth = 320,
    this.maxColumns = 3,
  });

  final List<Widget> children;
  final double minTileWidth;
  final int maxColumns;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final gap = spacing.md;
        final columns = (width ~/ minTileWidth).clamp(1, maxColumns).toInt();
        final tileWidth = (width - (columns - 1) * gap) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children)
              SizedBox(width: tileWidth, child: child),
          ],
        );
      },
    );
  }
}
