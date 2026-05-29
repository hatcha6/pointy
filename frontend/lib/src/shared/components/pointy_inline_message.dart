import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

enum PointyInlineMessageTone { neutral, error, warning, success }

class PointyInlineMessage extends StatelessWidget {
  const PointyInlineMessage({
    super.key,
    required this.message,
    this.icon = Icons.info_outline,
    this.tone = PointyInlineMessageTone.neutral,
    this.compact = false,
  });

  const PointyInlineMessage.error({
    super.key,
    required this.message,
    this.icon = Icons.error_outline,
    this.compact = false,
  }) : tone = PointyInlineMessageTone.error;

  const PointyInlineMessage.warning({
    super.key,
    required this.message,
    this.icon = Icons.warning_amber_outlined,
    this.compact = false,
  }) : tone = PointyInlineMessageTone.warning;

  const PointyInlineMessage.success({
    super.key,
    required this.message,
    this.icon = Icons.check_circle_outline,
    this.compact = false,
  }) : tone = PointyInlineMessageTone.success;

  final String message;
  final IconData icon;
  final PointyInlineMessageTone tone;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final foreground = _foregroundColor(context, colors);
    final background = _backgroundColor(context, colors, foreground);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: foreground.withValues(alpha: 0.20)),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.symmetric(
          horizontal: compact ? spacing.sm : spacing.md,
          vertical: compact ? spacing.xs : spacing.sm,
        ),
        child: Row(
          children: [
            Icon(icon, color: foreground, size: compact ? 18 : 20),
            SizedBox(width: spacing.sm),
            Expanded(
              child: Text(
                message,
                maxLines: compact ? 2 : null,
                overflow: compact ? TextOverflow.ellipsis : null,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _foregroundColor(BuildContext context, PointySemanticColors colors) {
    final colorScheme = Theme.of(context).colorScheme;
    return switch (tone) {
      PointyInlineMessageTone.neutral => colors.primaryStrong,
      PointyInlineMessageTone.error => colorScheme.onErrorContainer,
      PointyInlineMessageTone.warning => colors.warning,
      PointyInlineMessageTone.success => colors.success,
    };
  }

  Color _backgroundColor(
    BuildContext context,
    PointySemanticColors colors,
    Color foreground,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return switch (tone) {
      PointyInlineMessageTone.error => colorScheme.errorContainer,
      PointyInlineMessageTone.neutral => Color.alphaBlend(
        foreground.withValues(alpha: 0.08),
        colors.surface,
      ),
      PointyInlineMessageTone.warning => Color.alphaBlend(
        foreground.withValues(alpha: 0.10),
        colors.surface,
      ),
      PointyInlineMessageTone.success => Color.alphaBlend(
        foreground.withValues(alpha: 0.10),
        colors.surface,
      ),
    };
  }
}
