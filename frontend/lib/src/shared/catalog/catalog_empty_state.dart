import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/product_query.dart';
import '../components/components.dart';

/// Empty state for a product catalog grid or table.
///
/// A bare "no products" message leaves the user guessing why the list went
/// blank when the cause is their own search term, pinned category, or one of
/// the filters behind the funnel icon. When any of those is active this
/// explains what was filtered and offers one tap to clear it; otherwise it
/// falls back to [emptyMessage] (with [emptyAction], e.g. "add a product").
class CatalogEmptyState extends StatelessWidget {
  const CatalogEmptyState({
    super.key,
    required this.query,
    required this.emptyMessage,
    required this.onClear,
    this.allowAvailabilityFilter = true,
    this.emptyAction,
    this.hiddenOutOfStock = 0,
  });

  final ProductQuery query;
  final String emptyMessage;

  /// Receives [query] with every user-set filter stripped (see [cleared]).
  final ValueChanged<ProductQuery> onClear;

  /// Whether [ProductQuery.availability] is the user's to choose here, as it is
  /// for the screen's `ProductQueryControls`. The till and the purchasing
  /// catalog pin it to active products themselves: an "active only" query is
  /// where they start, not a filter to explain or clear.
  final bool allowAvailabilityFilter;

  /// Shown only when the list is genuinely empty — never alongside the
  /// "clear filters" escape, where inviting the user to create a product they
  /// may well already own would be the wrong advice.
  final Widget? emptyAction;

  /// Products the search DID match but the screen's stock filter hid (the
  /// till hides what is out of stock). When there are any, the honest answer
  /// is "it exists and has run out", not "check your spelling".
  final int hiddenOutOfStock;

  /// Whether the user narrowed the listing themselves. [ProductQuery.stock] and
  /// [ProductQuery.preferredSupplierId] are deliberately excluded: the app sets
  /// those, so the user has nothing to clear. So is [ProductQuery.availability]
  /// unless [allowAvailabilityFilter].
  static bool isFiltered(
    ProductQuery query, {
    bool allowAvailabilityFilter = true,
  }) {
    return query.search.trim().isNotEmpty ||
        query.categories.isNotEmpty ||
        (allowAvailabilityFilter &&
            query.availability != ProductAvailabilityFilter.all) ||
        query.archived == ProductArchivedFilter.onlyArchived ||
        query.supplierId != null;
  }

  /// Strips every user-set filter, leaving app-set ones ([ProductQuery.stock],
  /// [ProductQuery.system], [ProductQuery.preferredSupplierId], and
  /// [ProductQuery.availability] unless [allowAvailabilityFilter]) and the
  /// chosen ordering intact.
  static ProductQuery cleared(
    ProductQuery query, {
    bool allowAvailabilityFilter = true,
  }) {
    return query.withSupplier().copyWith(
      search: '',
      categories: const [],
      availability: allowAvailabilityFilter
          ? ProductAvailabilityFilter.all
          : query.availability,
      archived: ProductArchivedFilter.excludeArchived,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final search = query.search.trim();

    if (!isFiltered(query, allowAvailabilityFilter: allowAvailabilityFilter)) {
      return PointyEmptyState(
        icon: Icons.inventory_2_outlined,
        title: emptyMessage,
        action: emptyAction,
      );
    }

    if (search.isNotEmpty && hiddenOutOfStock > 0) {
      return PointyEmptyState(
        key: const ValueKey('catalog_empty_out_of_stock'),
        icon: Icons.production_quantity_limits,
        title: l10n.catalogOutOfStockMatchesTitle(hiddenOutOfStock),
        message: l10n.catalogOutOfStockMatchesMessage,
      );
    }

    return PointyEmptyState(
      icon: Icons.search_off,
      title: search.isEmpty
          ? l10n.catalogNoFilteredResultsTitle
          : l10n.catalogNoSearchResultsTitle(search),
      // A search narrowed to codes or to names says so: the product may well
      // be there under the half the picker left out, and the picker is small.
      message: switch (search.isEmpty
          ? ProductSearchMode.all
          : query.searchMode) {
        ProductSearchMode.all => l10n.catalogNoResultsMessage,
        ProductSearchMode.code => l10n.catalogNoResultsCodeModeMessage,
        ProductSearchMode.name => l10n.catalogNoResultsNameModeMessage,
      },
      action: FilledButton.tonalIcon(
        onPressed: () => onClear(
          cleared(query, allowAvailabilityFilter: allowAvailabilityFilter),
        ),
        icon: const Icon(Icons.filter_alt_off_outlined),
        label: Text(l10n.catalogClearSearchAndFiltersButton),
      ),
    );
  }
}
