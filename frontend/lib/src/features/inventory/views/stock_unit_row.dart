import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/stock_unit.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/tracking/unit_attribute_summary.dart';

/// One article in the units list.
///
/// Says which **variant** it is — four iPhone 13s in one list were four
/// lookalike columns of IMEIs — what condition it is in, and what it sells
/// for, labelled. The cost, for those allowed to see it, is a second,
/// labelled figure; it used to stand alone where the price belongs, with
/// nothing to say which of the two it was.
class StockUnitRow extends StatelessWidget {
  const StockUnitRow({
    super.key,
    required this.unit,
    required this.onTap,
    this.onIdentify,
    this.selecting = false,
    this.selected = false,
  });

  final StockUnit unit;
  final VoidCallback onTap;

  /// Names a placeholder article, from the row itself.
  final VoidCallback? onIdentify;

  /// Choosing articles to print labels for: the row shows a checkbox and a
  /// tap toggles it.
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final days = unit.daysInStock;
    final name = unit.variantName.isNotEmpty
        ? unit.variantName
        : unit.productName;
    final facts = UnitAttributeSummary.describe(unit.attributeDisplay);
    final sold = unit.status == StockUnitStatus.sold;
    final price = sold ? unit.soldPrice : unit.listPrice ?? unit.askingPrice;

    return ListTile(
      onTap: onTap,
      leading: selecting
          ? Checkbox(value: selected, onChanged: (_) => onTap())
          : Icon(
              unit.isIdentified ? Icons.qr_code_2_outlined : Icons.help_outline,
              color: unit.isIdentified ? null : colors.warning,
            ),
      title: Text(
        unit.isIdentified ? unit.code : l10n.stockUnitsAwaitingIdentifier,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
          fontStyle: unit.isIdentified ? FontStyle.normal : FontStyle.italic,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            [
              if (name.isNotEmpty) name,
              if (unit.batchCode.isNotEmpty)
                l10n.posCartLineBatchBadge(unit.batchCode),
              if (unit.isOnHand && days != null)
                l10n.posUnitPickerDaysInStock(days),
              if (unit.soldAt != null) formatDate(unit.soldAt!),
            ].join(' · '),
            // A phone is narrow enough to cut the variant off mid-colour.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (facts.isNotEmpty)
            Text(
              facts,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
        ],
      ),
      trailing: onIdentify != null && !selecting
          ? TextButton.icon(
              key: ValueKey('stock_unit_identify_${unit.id}'),
              onPressed: onIdentify,
              icon: const Icon(Icons.qr_code_scanner_outlined, size: 18),
              label: Text(l10n.stockUnitIdentifyAction),
            )
          : _Figures(
              price: price,
              priceCaption: sold
                  ? l10n.stockUnitSoldFor
                  : l10n.stockUnitPriceCaption,
              cost: unit.showsCost ? unit.totalCost : null,
            ),
    );
  }
}

class _Figures extends StatelessWidget {
  const _Figures({
    required this.price,
    required this.priceCaption,
    required this.cost,
  });

  final double? price;
  final String priceCaption;
  final double? cost;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final price = this.price;
    final cost = this.cost;
    if (price == null && cost == null) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (price != null) ...[
          Text(
            formatMoney(price),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            priceCaption,
            style: theme.textTheme.labelSmall?.copyWith(color: colors.mutedInk),
          ),
        ],
        if (cost != null)
          Text(
            l10n.stockUnitCostCaption(formatMoney(cost)),
            style: theme.textTheme.labelSmall?.copyWith(color: colors.mutedInk),
          ),
      ],
    );
  }
}
