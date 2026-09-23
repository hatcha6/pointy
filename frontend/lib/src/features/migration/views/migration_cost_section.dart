import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/migration.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/migration_view_model.dart';
import 'migration_formatting.dart';

/// "Does each product's cost come across?" — asked on its own.
///
/// It used to be answered by the quantity question: "no quantities" dropped the
/// stock record, the cost rode on that record, and a shop that only wanted to
/// count its own shelves opened with no cost on anything — every first sale
/// then booked the whole selling price as profit. So the cost is its own card,
/// on by default, sitting directly under the quantities it was confused with.
class MigrationCostSection extends StatelessWidget {
  const MigrationCostSection({super.key, required this.viewModel});

  final MigrationViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final spacing = AdaptiveSpacing.of(context);
    if (!viewModel.canCarryCosts) return const SizedBox.shrink();

    // Rebuilt from the invoices, the costs arrive on the purchase lines those
    // invoices carry; a switch here would be one that does nothing.
    final fromPurchases =
        viewModel.stockSource == MigrationStockSource.reconstruct;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.pointyColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.pointyColors.line),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.migrationCostSectionTitle,
              style: theme.textTheme.titleSmall,
            ),
            if (fromPurchases) ...[
              SizedBox(height: spacing.xs),
              Text(
                l10n.migrationCostsFromPurchasesNote,
                style: theme.textTheme.bodySmall,
              ),
            ] else ...[
              SwitchListTile.adaptive(
                key: const ValueKey('migration_carry_costs_switch'),
                contentPadding: EdgeInsets.zero,
                value: viewModel.carryCosts,
                onChanged: viewModel.setCarryCosts,
                title: Text(l10n.migrationCarryCostsLabel),
                subtitle: Text(l10n.migrationCarryCostsSubtitle),
              ),
              if (!viewModel.carryCosts)
                PointyInlineMessage.warning(
                  message: l10n.migrationCarryCostsOffWarning,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// How many products a run costed, and how many the old system had no cost
/// for — the number an owner checks before trusting the first day's profit.
class MigrationCostTally extends StatelessWidget {
  const MigrationCostTally({super.key, required this.run});

  final MigrationRun run;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tally = run.costTally;
    if (tally == null) return const SizedBox.shrink();
    final costed = formatCount(tally.costed);
    if (tally.uncosted == 0) {
      return PointyInlineMessage.success(
        message: l10n.migrationCostTally(costed),
      );
    }
    return PointyInlineMessage.warning(
      message: l10n.migrationCostTallyWithMissing(
        costed,
        formatCount(tally.uncosted),
      ),
    );
  }
}
