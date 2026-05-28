import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyEmptyState extends StatelessWidget {
  const PointyEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.maxWidth = AppContentWidth.compact,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final AppContentWidth maxWidth;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colorScheme = Theme.of(context).colorScheme;
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
              Icon(icon, size: 40, color: colorScheme.primary),
              SizedBox(height: spacing.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (message != null) ...[
                SizedBox(height: spacing.sm),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: textTheme.bodyMedium?.copyWith(
                    color: context.pointyColors.mutedInk,
                  ),
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
