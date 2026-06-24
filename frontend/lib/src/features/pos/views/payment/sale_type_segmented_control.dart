import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/sale_order.dart';
import '../../../../shared/design/design.dart';

/// Single-select control for how the sale is recorded: عادي (standard, paid in
/// full), آجل (credit / debt), or عرض سعر (quotation, no payment). Quotation and
/// credit are only offered when the shop enables them.
class SaleTypeSegmentedControl extends StatelessWidget {
  const SaleTypeSegmentedControl({
    super.key,
    required this.label,
    required this.selectedSaleType,
    required this.onSelected,
    this.enableCredit = true,
    this.enableQuotations = true,
  });

  final String label;
  final SaleType selectedSaleType;
  final ValueChanged<SaleType> onSelected;
  final bool enableCredit;
  final bool enableQuotations;

  List<SaleType> get _availableTypes {
    return [
      SaleType.standard,
      if (enableCredit) SaleType.credit,
      if (enableQuotations) SaleType.quotation,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final types = _availableTypes;
    // With only the standard type available there is nothing to choose.
    if (types.length < 2) {
      return const SizedBox.shrink();
    }

    final colors = context.pointyColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<SaleType>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              backgroundColor: colors.surface,
              foregroundColor: colors.ink,
              selectedBackgroundColor: Color.alphaBlend(
                colors.primaryStrong.withValues(alpha: 0.14),
                colors.surface,
              ),
              selectedForegroundColor: colors.primaryDark,
              side: BorderSide(color: colors.line),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(PointyRadii.chip),
              ),
            ),
            segments: [
              for (final type in types)
                ButtonSegment(
                  value: type,
                  icon: Icon(_saleTypeIcon(type)),
                  label: Text(
                    _saleTypeLabel(l10n, type),
                    key: ValueKey('sale_type_${type.apiValue}'),
                  ),
                ),
            ],
            selected: {selectedSaleType},
            onSelectionChanged: (selected) {
              if (selected.isEmpty) {
                return;
              }
              onSelected(selected.first);
            },
          ),
        ),
      ],
    );
  }
}

String _saleTypeLabel(AppLocalizations l10n, SaleType type) {
  return switch (type) {
    SaleType.standard => l10n.saleTypeStandardLabel,
    SaleType.credit => l10n.saleTypeCreditLabel,
    SaleType.quotation => l10n.saleTypeQuotationLabel,
  };
}

IconData _saleTypeIcon(SaleType type) {
  return switch (type) {
    SaleType.standard => Icons.point_of_sale_outlined,
    SaleType.credit => Icons.schedule_outlined,
    SaleType.quotation => Icons.request_quote_outlined,
  };
}
