import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../view_models/tracked_stock_view_model.dart';

/// A product's variants as chips — «كل الخيارات» first.
class VariantFilterChips extends StatelessWidget {
  const VariantFilterChips({
    super.key,
    required this.viewModel,
    required this.onSelected,
  });

  final TrackedStockViewModel viewModel;
  final ValueChanged<int?> onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ChoiceChip(
            key: const ValueKey('variant_filter_all'),
            label: Text(l10n.stockUnitsAllVariants),
            selected: viewModel.variantId == null,
            onSelected: (_) => onSelected(null),
          ),
          for (final choice in viewModel.variantChoices)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6),
              child: ChoiceChip(
                key: ValueKey('variant_filter_${choice.id}'),
                label: Text(choice.label),
                selected: viewModel.variantId == choice.id,
                onSelected: (_) => onSelected(choice.id),
              ),
            ),
        ],
      ),
    );
  }
}
