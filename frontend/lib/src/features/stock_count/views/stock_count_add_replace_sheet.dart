import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_count_draft.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// Asked when a re-scanned item was already counted, so a second pass over a
/// shelf never quietly inflates the number. Returns the chosen mode, or null on
/// dismiss.
Future<StockCountEntryMode?> showStockCountReentrySheet(
  BuildContext context, {
  required String existing,
}) {
  return showAdaptiveModalBottomSheet<StockCountEntryMode>(
    context: context,
    size: AdaptiveModalSize.compact,
    builder: (context) => _ReentrySheet(existing: existing),
  );
}

class _ReentrySheet extends StatelessWidget {
  const _ReentrySheet({required this.existing});

  final String existing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.lg,
        spacing.xs,
        spacing.lg,
        spacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.warning.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.replay_rounded,
                  color: colors.warning,
                  size: 22,
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Text(
                  l10n.stockCountReentryTitle,
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.md),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceSunken,
              borderRadius: BorderRadius.circular(PointyRadii.input),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: spacing.md,
                vertical: spacing.sm,
              ),
              child: Row(
                children: [
                  Text(
                    l10n.stockCountReentryCurrentLabel,
                    style: textTheme.bodyMedium?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    existing,
                    style: PointyTypography.numeric(
                      textTheme.titleMedium ?? const TextStyle(),
                    ).copyWith(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: spacing.sm),
          Text(
            l10n.stockCountReentryQuestion,
            style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
          ),
          SizedBox(height: spacing.lg),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(StockCountEntryMode.add),
              icon: const Icon(Icons.add),
              label: Text(l10n.stockCountReentryAdd),
            ),
          ),
          SizedBox(height: spacing.sm),
          SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              onPressed: () =>
                  Navigator.of(context).pop(StockCountEntryMode.replace),
              icon: const Icon(Icons.swap_horiz),
              label: Text(l10n.stockCountReentryReplace),
            ),
          ),
        ],
      ),
    );
  }
}
