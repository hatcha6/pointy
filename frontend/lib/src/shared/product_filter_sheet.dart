import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/product_query.dart';
import 'query_controls/query_filter_sheet.dart';

class ProductFilterSheet extends StatefulWidget {
  const ProductFilterSheet({
    super.key,
    required this.query,
    required this.allowAvailabilityFilter,
  });

  final ProductQuery query;
  final bool allowAvailabilityFilter;

  @override
  State<ProductFilterSheet> createState() => _ProductFilterSheetState();
}

class _ProductFilterSheetState extends State<ProductFilterSheet> {
  late ProductAvailabilityFilter _availability;
  late ProductOrdering _ordering;

  @override
  void initState() {
    super.initState();
    _availability = widget.query.availability;
    _ordering = widget.query.ordering;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryFilterSheet(
      title: l10n.filtersSheetTitle,
      resetLabel: l10n.resetFiltersButton,
      applyLabel: l10n.applyFiltersButton,
      onReset: _reset,
      onApply: _apply,
      children: [
        if (widget.allowAvailabilityFilter) ...[
          const SizedBox(height: 22),
          QueryFilterSection(
            title: l10n.availabilityFilterTitle,
            children: [
              QueryFilterOptionTile(
                label: l10n.availabilityAll,
                icon: Icons.inventory_2_outlined,
                isSelected: _availability == ProductAvailabilityFilter.all,
                onTap: () => _selectAvailability(ProductAvailabilityFilter.all),
              ),
              QueryFilterOptionTile(
                label: l10n.availabilityActive,
                icon: Icons.check_circle_outline,
                isSelected: _availability == ProductAvailabilityFilter.active,
                onTap: () =>
                    _selectAvailability(ProductAvailabilityFilter.active),
              ),
              QueryFilterOptionTile(
                label: l10n.availabilityInactive,
                icon: Icons.pause_circle_outline,
                isSelected: _availability == ProductAvailabilityFilter.inactive,
                onTap: () =>
                    _selectAvailability(ProductAvailabilityFilter.inactive),
              ),
            ],
          ),
        ],
        const SizedBox(height: 22),
        QueryFilterSection(
          title: l10n.orderingTitle,
          children: [
            QueryFilterOptionTile(
              label: l10n.orderingName,
              icon: Icons.sort_by_alpha,
              isSelected: _ordering == ProductOrdering.name,
              onTap: () => _selectOrdering(ProductOrdering.name),
            ),
            QueryFilterOptionTile(
              label: l10n.orderingPriceAsc,
              icon: Icons.trending_up,
              isSelected: _ordering == ProductOrdering.priceAsc,
              onTap: () => _selectOrdering(ProductOrdering.priceAsc),
            ),
            QueryFilterOptionTile(
              label: l10n.orderingPriceDesc,
              icon: Icons.trending_down,
              isSelected: _ordering == ProductOrdering.priceDesc,
              onTap: () => _selectOrdering(ProductOrdering.priceDesc),
            ),
            QueryFilterOptionTile(
              label: l10n.orderingNewest,
              icon: Icons.schedule,
              isSelected: _ordering == ProductOrdering.newest,
              onTap: () => _selectOrdering(ProductOrdering.newest),
            ),
          ],
        ),
      ],
    );
  }

  void _selectAvailability(ProductAvailabilityFilter availability) {
    setState(() => _availability = availability);
  }

  void _selectOrdering(ProductOrdering ordering) {
    setState(() => _ordering = ordering);
  }

  void _reset() {
    setState(() {
      _availability = widget.allowAvailabilityFilter
          ? ProductAvailabilityFilter.all
          : widget.query.availability;
      _ordering = ProductOrdering.name;
    });
  }

  void _apply() {
    Navigator.of(context).pop(
      widget.query.copyWith(
        availability: widget.allowAvailabilityFilter
            ? _availability
            : widget.query.availability,
        ordering: _ordering,
      ),
    );
  }
}
