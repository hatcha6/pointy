import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyErrorState extends StatelessWidget {
  const PointyErrorState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.error_outline,
    this.action,
    this.maxWidth = AppContentWidth.compact,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;
  final AppContentWidth maxWidth;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Center(
      child: AdaptiveMaxWidth(
        width: maxWidth,
        expand: false,
        child: Padding(
          padding: spacing.sectionPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: colors.danger),
              SizedBox(height: spacing.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: textTheme.titleMedium?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (message != null) ...[
                SizedBox(height: spacing.sm),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
                ),
              ],
              if (action != null) ...[SizedBox(height: spacing.lg), action!],
            ],
          ),
        ),
      ),
    );
  }
}
