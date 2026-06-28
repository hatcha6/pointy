import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/purchase_submission.dart';
import '../../../shared/components/components.dart';
import '../../../shared/formatters.dart';

/// Lowest / Highest / Last / Average cost metric grid, derived from purchase
/// history. Shown on the variant detail screen (single variant) and, in an
/// aggregated form, on the product detail screen.
class VariantCostMetrics extends StatelessWidget {
  const VariantCostMetrics({
    super.key,
    required this.lowestCost,
    required this.highestCost,
    required this.lastCost,
    required this.averageCost,
    this.currentPrice,
  });

  /// Builds the metrics from a single variant's [VariantCostSummary].
  factory VariantCostMetrics.fromSummary(VariantCostSummary summary) {
    return VariantCostMetrics(
      lowestCost: summary.lowestCost,
      highestCost: summary.highestCost,
      lastCost: summary.lastCost,
      averageCost: summary.averageCost,
      currentPrice: summary.unitPrice,
    );
  }

  /// Aggregates a product's variants into one cost overview: lowest/highest are
  /// the min/max across variants, average is the mean of per-variant averages,
  /// and "last" is the most recently purchased variant's last cost (approximated
  /// by the default/first variant that has cost data).
  factory VariantCostMetrics.aggregate(
    List<VariantCostSummary> summaries, {
    double? currentPrice,
  }) {
    final withCost = summaries.where((s) => s.hasCost).toList();
    double? lowest;
    double? highest;
    final averages = <double>[];
    for (final summary in withCost) {
      final low = summary.lowestCost;
      final high = summary.highestCost;
      if (low != null) {
        lowest = lowest == null ? low : (low < lowest ? low : lowest);
      }
      if (high != null) {
        highest = highest == null ? high : (high > highest ? high : highest);
      }
      if (summary.averageCost != null) {
        averages.add(summary.averageCost!);
      }
    }
    final lastCost = withCost.isEmpty ? null : withCost.first.lastCost;
    final average = averages.isEmpty
        ? null
        : averages.reduce((a, b) => a + b) / averages.length;
    return VariantCostMetrics(
      lowestCost: lowest,
      highestCost: highest,
      lastCost: lastCost,
      averageCost: average,
      currentPrice: currentPrice,
    );
  }

  final double? lowestCost;
  final double? highestCost;
  final double? lastCost;
  final double? averageCost;
  final double? currentPrice;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final empty = l10n.shopSettingsEmptyValue;
    String money(double? value) => value == null ? empty : formatMoney(value);

    return PointyMetricGrid(
      maxColumns: 3,
      minTileWidth: 150,
      gap: PointyMetricGridGap.compact,
      metrics: [
        PointyMetricGridItem(
          label: l10n.lowestCostLabel,
          value: money(lowestCost),
          icon: Icons.south_outlined,
        ),
        PointyMetricGridItem(
          label: l10n.highestCostLabel,
          value: money(highestCost),
          icon: Icons.north_outlined,
        ),
        PointyMetricGridItem(
          label: l10n.lastCostLabel,
          value: money(lastCost),
          icon: Icons.history_outlined,
        ),
        PointyMetricGridItem(
          label: l10n.averageCostLabel,
          value: money(averageCost),
          icon: Icons.calculate_outlined,
        ),
        if (currentPrice != null)
          PointyMetricGridItem(
            label: l10n.currentPriceLabel,
            value: formatMoney(currentPrice!),
            icon: Icons.sell_outlined,
          ),
      ],
    );
  }
}
