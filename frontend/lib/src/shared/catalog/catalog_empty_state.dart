import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/product_query.dart';
import '../components/components.dart';

/// Empty state for a product catalog grid.
///
/// A bare "no products" message leaves a cashier guessing why the grid went
/// blank when the cause is their own search term or pinned category. When
/// either is active this explains what was searched and offers one tap to
/// clear it; otherwise it falls back to [emptyMessage].
class CatalogEmptyState extends StatelessWidget {
  const CatalogEmptyState({
    super.key,
    required this.query,
    required this.emptyMessage,
    required this.onClear,
  });

  final ProductQuery query;
  final String emptyMessage;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final search = query.search.trim();
    final hasCategory = query.categories.isNotEmpty;

    if (search.isEmpty && !hasCategory) {
      return PointyEmptyState(
        icon: Icons.inventory_2_outlined,
        title: emptyMessage,
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
