import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyOrderPanel extends StatelessWidget {
  const PointyOrderPanel({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              spacing.md,
              spacing.sm,
              spacing.sm,
              spacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          Divider(height: 1, color: colors.line),
          Expanded(child: child),
        ],
      ),
    );
  }
}
