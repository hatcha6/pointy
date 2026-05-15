import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/product_query.dart';
import 'product_filter_sheet.dart';
import 'query_controls/query_control_bar.dart';

class ProductQueryControls extends StatelessWidget {
  const ProductQueryControls({
    super.key,
    required this.query,
    required this.onSearchChanged,
    required this.onQueryChanged,
    this.allowAvailabilityFilter = true,
  });

  final ProductQuery query;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<ProductQuery> onQueryChanged;
  final bool allowAvailabilityFilter;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryControlBar(
      searchValue: query.search,
      searchHint: l10n.searchProductsHint,
      clearSearchTooltip: l10n.clearSearchTooltip,
      filterLabel: l10n.filtersButtonLabel,
      openFiltersTooltip: l10n.openFiltersTooltip,
      activeFilterCount: _activeFilterCount,
      onSearchChanged: onSearchChanged,
      onOpenFilters: () => _showFilters(context),
    );
  }

  int get _activeFilterCount {
    return (allowAvailabilityFilter &&
                query.availability != ProductAvailabilityFilter.all
            ? 1
            : 0) +
        (query.ordering == ProductOrdering.name ? 0 : 1);
  }

  Future<void> _showFilters(BuildContext context) async {
    final updatedQuery = await showModalBottomSheet<ProductQuery>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) {
        return ProductFilterSheet(
          query: query,
          allowAvailabilityFilter: allowAvailabilityFilter,
        );
      },
    );

    if (updatedQuery != null) {
      onQueryChanged(updatedQuery);
    }
  }
}
