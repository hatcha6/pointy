import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyStickyActionFooter extends StatelessWidget {
  const PointyStickyActionFooter({
    super.key,
    required this.primaryAction,
    this.secondaryActions = const [],
    this.summary,
    this.padding,
    this.showTopBorder = true,
    this.primaryActionHeight,
  });

  final Widget primaryAction;
  final List<Widget> secondaryActions;
  final Widget? summary;
  final EdgeInsetsGeometry? padding;
  final bool showTopBorder;
  final double? primaryActionHeight;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final actionHeight =
        primaryActionHeight ?? PointyDimensions.primaryActionHeight;
    final resolvedPadding =
        padding ??
        EdgeInsetsDirectional.fromSTEB(
          spacing.md,
          spacing.sm,
          spacing.md,
          spacing.sm,
        );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: showTopBorder
            ? Border(top: BorderSide(color: colors.line))
            : null,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: resolvedPadding,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < AppBreakpoints.tabletMin;
              if (isCompact) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (summary != null) ...[
                      summary!,
                      SizedBox(height: spacing.sm),
                    ],
                    for (final action in secondaryActions) ...[
                      action,
                      SizedBox(height: spacing.sm),
                    ],
                    SizedBox(height: actionHeight, child: primaryAction),
                  ],
                );
              }

              return Row(
                children: [
                  if (summary != null)
                    Expanded(child: summary!)
                  else
                    const Spacer(),
                  for (final action in secondaryActions) ...[
                    SizedBox(width: spacing.sm),
                    action,
                  ],
                  SizedBox(width: spacing.md),
                  SizedBox(
                    width: 280,
                    height: actionHeight,
                    child: primaryAction,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
