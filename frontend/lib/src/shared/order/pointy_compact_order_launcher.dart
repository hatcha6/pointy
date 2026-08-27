import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';
import '../components/pointy_progress.dart';

class PointyCompactOrderLauncher extends StatelessWidget {
  const PointyCompactOrderLauncher({
    super.key,
    required this.title,
    required this.lineCountLabel,
    required this.totalLabel,
    required this.actionLabel,
    required this.icon,
    required this.onPressed,
    this.isBusy = false,
  });

  final String title;
  final String lineCountLabel;
  final String totalLabel;
  final String actionLabel;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool isBusy;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.line)),
        boxShadow: [
          BoxShadow(
            color: colors.ink.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            spacing.md,
            spacing.sm,
            spacing.md,
            spacing.sm,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < AppBreakpoints.phoneMin) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _CompactOrderSummary(
                      title: title,
                      lineCountLabel: lineCountLabel,
                      totalLabel: totalLabel,
                    ),
                    SizedBox(height: spacing.sm),
                    _CompactOrderAction(
                      actionLabel: actionLabel,
                      icon: icon,
                      isBusy: isBusy,
                      onPressed: onPressed,
                    ),
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(
                    child: _CompactOrderSummary(
                      title: title,
                      lineCountLabel: lineCountLabel,
                      totalLabel: totalLabel,
                    ),
                  ),
                  SizedBox(width: spacing.md),
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 144,
                      maxWidth: 184,
                    ),
                    child: _CompactOrderAction(
                      actionLabel: actionLabel,
                      icon: icon,
                      isBusy: isBusy,
                      onPressed: onPressed,
                    ),
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

class _CompactOrderSummary extends StatelessWidget {
  const _CompactOrderSummary({
    required this.title,
    required this.lineCountLabel,
    required this.totalLabel,
  });

  final String title;
  final String lineCountLabel;
  final String totalLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.labelLarge?.copyWith(
            color: colors.mutedInk,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Flexible(
              child: Text(
                lineCountLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 8),
              child: Icon(Icons.circle, size: 5, color: colors.line),
            ),
            Flexible(
              child: Text(
                totalLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(
                  color: colors.primaryStrong,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CompactOrderAction extends StatelessWidget {
  const _CompactOrderAction({
    required this.actionLabel,
    required this.icon,
    required this.isBusy,
    required this.onPressed,
  });

  final String actionLabel;
  final IconData icon;
  final bool isBusy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: PointyDimensions.primaryActionHeight,
      child: FilledButton.icon(
        onPressed: isBusy ? null : onPressed,
        icon: isBusy
            ? const SizedBox.square(
                dimension: 18,
                child: PointySpinner(strokeWidth: 2),
              )
            : Icon(icon),
        label: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(actionLabel, maxLines: 1),
        ),
      ),
    );
  }
}
