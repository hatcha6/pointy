import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_count_draft.dart';
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
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.lg,
        spacing.sm,
        spacing.lg,
        spacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.stockCountReentryTitle,
            style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: spacing.sm),
          Text(
            l10n.stockCountReentryBody(existing),
            style: textTheme.bodyLarge,
          ),
          SizedBox(height: spacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      Navigator.of(context).pop(StockCountEntryMode.replace),
                  child: Text(l10n.stockCountReentryReplace),
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(StockCountEntryMode.add),
                  child: Text(l10n.stockCountReentryAdd),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
