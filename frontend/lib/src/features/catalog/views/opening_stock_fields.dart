import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

/// What the shop already has of a product on the day it types it in, and what
/// one unit of it cost.
///
/// The pair exists because a cost that only arrives with a purchase order is no
/// cost at all for a shop that has been trading for ten years and is entering
/// its shelves: the till would show no cost, gross profit would book the whole
/// selling price, and the sell-below-cost guard would have nothing to guard.
/// The server turns these two numbers into a real opening balance in the
/// valuation ledger.
///
/// Both figures are per BASE unit — per piece, not per carton — which is the
/// same denomination as the price field above them.
class OpeningStockFields extends StatelessWidget {
  const OpeningStockFields({
    super.key,
    required this.quantityController,
    required this.costController,
    this.dense = false,
  });

  final TextEditingController quantityController;
  final TextEditingController costController;

  /// Laid out for a generated-variant tile, which is already a stack of fields
  /// and does not want a second heading inside it.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final fields = [
      TextFormField(
        controller: quantityController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.next,
        inputFormatters: [DecimalTextInputFormatter()],
        decoration: InputDecoration(
          labelText: l10n.openingStockQuantityLabel,
          prefixIcon: const Icon(Icons.inventory_outlined),
        ),
        validator: (value) => _quantityError(context, value),
      ),
      TextFormField(
        controller: costController,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.next,
        inputFormatters: [DecimalTextInputFormatter()],
        decoration: InputDecoration(
          labelText: l10n.openingStockUnitCostLabel,
          helperText: dense ? null : l10n.openingStockUnitCostHelper,
          prefixIcon: const Icon(Icons.payments_outlined),
        ),
        // A cost with no quantity would be silently dropped by the server (it
        // has nothing to value), so it is caught here where the owner can see
        // which of the two they forgot.
        validator: (value) => _costError(context, value),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!dense) ...[
          Text(
            l10n.openingStockSectionHint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.pointyColors.mutedInk,
            ),
          ),
          const SizedBox(height: 12),
        ],
        ResponsiveFormGrid(maxColumns: 2, children: fields),
        _OpeningStockValue(
          quantityController: quantityController,
          costController: costController,
        ),
      ],
    );
  }

  String? _quantityError(BuildContext context, String? value) {
    if ((value ?? '').trim().isEmpty) {
      return null;
    }
    final parsed = parseDecimal(value);
    if (parsed == null || parsed < 0) {
      return AppLocalizations.of(context)!.invalidNumber;
    }
    return null;
  }

  String? _costError(BuildContext context, String? value) {
    final l10n = AppLocalizations.of(context)!;
    if ((value ?? '').trim().isEmpty) {
      return null;
    }
    final parsed = parseDecimal(value);
    if (parsed == null || parsed < 0) {
      return l10n.invalidNumber;
    }
    final quantity = parseDecimal(quantityController.text) ?? 0;
    if (quantity <= 0) {
      return l10n.openingStockCostNeedsQuantityError;
    }
    return null;
  }
}

/// Quantity × cost, live, under the pair.
///
/// A typo in an opening cost is silent in a way a typo in a price is not — the
/// shelf looks right and the shop finds out at the end of the month — so the
/// number it multiplies out to is shown while it can still be corrected.
class _OpeningStockValue extends StatelessWidget {
  const _OpeningStockValue({
    required this.quantityController,
    required this.costController,
  });

  final TextEditingController quantityController;
  final TextEditingController costController;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([quantityController, costController]),
      builder: (context, _) {
        final quantity = parseDecimal(quantityController.text) ?? 0;
        final cost = parseDecimal(costController.text) ?? 0;
        if (quantity <= 0 || cost <= 0) {
          return const SizedBox.shrink();
        }
        final l10n = AppLocalizations.of(context)!;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            l10n.openingStockValueLabel(formatMoney(quantity * cost)),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.pointyColors.mutedInk,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
      },
    );
  }
}
