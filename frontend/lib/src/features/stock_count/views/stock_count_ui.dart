import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_count.dart';
import '../../../shared/design/design.dart';

/// Cross-screen building blocks for the stock-count feature so the sessions,
/// counting, and reconciliation surfaces share one visual language.

/// Visual treatment for a session status: a localized label, a semantic color,
/// and an icon so status reads through text + shape, never color alone.
class StockCountStatusVisual {
  const StockCountStatusVisual(this.label, this.color, this.icon);

  final String label;
  final Color color;
  final IconData icon;

  static StockCountStatusVisual of(
    BuildContext context,
    StockCountStatus status,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return switch (status) {
      StockCountStatus.inProgress => StockCountStatusVisual(
        l10n.stockCountStatusInProgress,
        colors.warning,
        Icons.timelapse_outlined,
      ),
      StockCountStatus.applied => StockCountStatusVisual(
        l10n.stockCountStatusApplied,
        colors.success,
        Icons.check_circle_outline,
      ),
      StockCountStatus.cancelled ||
      StockCountStatus.unknown => StockCountStatusVisual(
        l10n.stockCountStatusCancelled,
        colors.mutedInk,
        Icons.cancel_outlined,
      ),
    };
  }
}

/// A compact scope indicator ("all products" or "category: X") rendered as a
/// soft outlined chip with a leading icon.
class StockCountScopeChip extends StatelessWidget {
  const StockCountScopeChip({
    super.key,
    required this.session,
    this.onDark = false,
  });

  final StockCount session;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final isCategory = session.scope == StockCountScope.category;
    final label = isCategory
        ? l10n.stockCountScopeCategoryLabel(session.categoryName)
        : l10n.stockCountScopeFull;
    final icon = isCategory ? Icons.category_outlined : Icons.apps_outlined;

    final foreground = onDark ? colors.surface : colors.mutedInk;
    final background = onDark
        ? colors.surface.withValues(alpha: 0.12)
        : colors.subtleFill;
    final border = onDark
        ? colors.surface.withValues(alpha: 0.18)
        : colors.line;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(PointyRadii.chip),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(8, 5, 10, 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: foreground),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
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
}

/// A labelled, rounded progress bar shared by the resume card and the counting
/// header. [onDark] switches the palette for the focused counting surface.
class StockCountProgressBar extends StatelessWidget {
  const StockCountProgressBar({
    super.key,
    required this.counted,
    required this.total,
    required this.progress,
    this.onDark = false,
    this.compact = false,
  });

  final int counted;
  final int total;
  final double progress;
  final bool onDark;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    final strong = onDark ? colors.surface : colors.ink;
    final muted = onDark
        ? colors.surface.withValues(alpha: 0.72)
        : colors.mutedInk;
    final track = onDark
        ? colors.surface.withValues(alpha: 0.16)
        : colors.surfaceSunken;
    final fill = onDark ? colors.surface : PointyColors.primary;
    final remaining = (total - counted).clamp(0, total);

    final countStyle = PointyTypography.numeric(
      (compact ? textTheme.titleMedium : textTheme.titleLarge) ??
          const TextStyle(),
    ).copyWith(color: strong, fontWeight: FontWeight.w800);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(formatCount(counted), style: countStyle),
            const SizedBox(width: 4),
            Text(
              l10n.stockCountOfTotal(total),
              style: textTheme.bodySmall?.copyWith(color: muted),
            ),
            const Spacer(),
            Text(
              l10n.stockCountRemaining(remaining),
              style: textTheme.labelMedium?.copyWith(
                color: muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        SizedBox(height: compact ? 6 : 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: total <= 0 ? null : progress,
            minHeight: compact ? 8 : 10,
            backgroundColor: track,
            valueColor: AlwaysStoppedAnimation<Color>(fill),
          ),
        ),
      ],
    );
  }
}

/// Western-digit count, kept tabular at call sites that need column alignment.
String formatCount(int value) => value.toString();
