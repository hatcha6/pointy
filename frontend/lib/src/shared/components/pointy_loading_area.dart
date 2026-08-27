import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';
import 'pointy_progress.dart';

class PointyLoadingArea extends StatelessWidget {
  const PointyLoadingArea({
    super.key,
    this.label,
    this.minHeight = 160,
    this.progressSize = 28,
  });

  final String? label;
  final double minHeight;
  final double progressSize;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: progressSize,
              child: const PointySpinner(strokeWidth: 2.6),
            ),
            if (label != null) ...[
              SizedBox(height: spacing.md),
              Text(
                label!,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: context.pointyColors.mutedInk,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
