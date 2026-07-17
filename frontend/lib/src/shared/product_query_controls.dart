import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/product_query.dart';
import '../data/repositories/catalog_repository.dart';
import '../data/repositories/contact_repository.dart';
import 'product_filter_sheet.dart';
import 'query_controls/query_control_bar.dart';
import 'responsive/responsive.dart';

class ProductQueryControls extends StatelessWidget {
  const ProductQueryControls({
    super.key,
    required this.query,
    required this.catalogRepository,
    required this.onSearchChanged,
    required this.onQueryChanged,
    this.contactRepository,
    this.allowAvailabilityFilter = true,
    this.onSearchSubmitted,
    this.onOpenCameraScanner,
    this.searchHint,
    this.openCameraScannerTooltip,
    this.enabled = true,
    this.autofocus = false,
    this.searchFieldKey,
    this.searchFocusNode,
  });

  final ProductQuery query;
  final CatalogRepository catalogRepository;
  final ContactRepository? contactRepository;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<ProductQuery> onQueryChanged;
  final bool allowAvailabilityFilter;
  final FutureOr<bool> Function(String value)? onSearchSubmitted;
  final VoidCallback? onOpenCameraScanner;
  final String? searchHint;
  final String? openCameraScannerTooltip;
  final bool enabled;
  final bool autofocus;
  final Key? searchFieldKey;
  final FocusNode? searchFocusNode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return QueryControlBar(
      searchValue: query.search,
      searchHint: searchHint ?? l10n.searchProductsHint,
      clearSearchTooltip: l10n.clearSearchTooltip,
      filterLabel: l10n.filtersButtonLabel,
      openFiltersTooltip: l10n.openFiltersTooltip,
      activeFilterCount: _activeFilterCount,
      onSearchChanged: onSearchChanged,
      onOpenFilters: () => _showFilters(context),
      onSearchSubmitted: onSearchSubmitted,
      onOpenCameraScanner: onOpenCameraScanner,
      openCameraScannerTooltip:
          openCameraScannerTooltip ?? l10n.openCameraScannerTooltip,
      enabled: enabled,
      autofocus: autofocus,
      searchFieldKey: searchFieldKey,
      searchFocusNode: searchFocusNode,
    );
  }

  int get _activeFilterCount {
    return (allowAvailabilityFilter &&
                query.availability != ProductAvailabilityFilter.all
            ? 1
            : 0) +
        (query.categories.isEmpty ? 0 : 1) +
        (query.supplierId == null ? 0 : 1) +
        (query.ordering == ProductOrdering.name ? 0 : 1);
  }

  Future<void> _showFilters(BuildContext context) async {
    final updatedQuery = await showAdaptiveModalBottomSheet<ProductQuery>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (context) {
        return ProductFilterSheet(
          query: query,
          catalogRepository: catalogRepository,
          contactRepository: contactRepository,
          allowAvailabilityFilter: allowAvailabilityFilter,
        );
      },
    );

    if (updatedQuery != null) {
      onQueryChanged(updatedQuery);
    }
  }
}
