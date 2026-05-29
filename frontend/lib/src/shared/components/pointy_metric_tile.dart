import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyMetricTile extends StatelessWidget {
  const PointyMetricTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.accentColor,
    this.subtitle,
  });

  final String label;
  final String value;
  final IconData? icon;
  final Color? accentColor;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final resolvedAccent = accentColor ?? theme.colorScheme.primary;

    return Card(
      child: Padding(
        padding: spacing.compactPadding,
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: resolvedAccent),
              SizedBox(width: spacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                  SizedBox(height: spacing.xs),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      value,
                      maxLines: 1,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (subtitle != null) ...[
                    SizedBox(height: spacing.xs),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
