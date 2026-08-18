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
    this.emptyAction,
  });

  final ProductQuery query;
  final String emptyMessage;
  final VoidCallback onClear;

  /// Shown only when the list is genuinely empty — never alongside the
  /// "clear filters" escape, where inviting the user to create a product they
  /// may well already own would be the wrong advice.
  final Widget? emptyAction;

  /// Whether the user narrowed the listing themselves. [ProductQuery.stock] and
  /// [ProductQuery.preferredSupplierId] are deliberately excluded: the app sets
  /// those, so the user has nothing to clear.
  static bool isFiltered(ProductQuery query) {
    return query.search.trim().isNotEmpty ||
        query.categories.isNotEmpty ||
        query.availability != ProductAvailabilityFilter.all ||
        query.archived == ProductArchivedFilter.onlyArchived ||
        query.supplierId != null;
  }

  /// Strips every user-set filter, leaving app-set ones ([ProductQuery.stock],
  /// [ProductQuery.preferredSupplierId]) and the chosen ordering intact.
  static ProductQuery cleared(ProductQuery query) {
    return query.withSupplier().copyWith(
      search: '',
      categories: const [],
      availability: ProductAvailabilityFilter.all,
      archived: ProductArchivedFilter.excludeArchived,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final search = query.search.trim();

    if (!isFiltered(query)) {
      return PointyEmptyState(
        icon: Icons.inventory_2_outlined,
        title: emptyMessage,
        action: emptyAction,
      );
    }

    return PointyEmptyState(
      icon: Icons.search_off,
      title: search.isEmpty
          ? l10n.catalogNoFilteredResultsTitle
          : l10n.catalogNoSearchResultsTitle(search),
      message: l10n.catalogNoResultsMessage,
      action: FilledButton.tonalIcon(
        onPressed: onClear,
        icon: const Icon(Icons.filter_alt_off_outlined),
        label: Text(l10n.catalogClearSearchAndFiltersButton),
      ),
    );
  }
}
