import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/product_query.dart';
import '../data/repositories/catalog_repository.dart';
import '../data/repositories/contact_repository.dart';
import 'product_filter_sheet.dart';
import 'product_search/product_search_mode_controller.dart';
import 'product_search/product_search_mode_picker.dart';
import 'query_controls/query_control_bar.dart';
import 'responsive/responsive.dart';

/// The product search bar of the till, the purchasing screen and the catalog.
///
/// On a machine whose device settings turned on the search-mode picker (see
/// [ProductSearchModeController]) the field ends in a dropdown choosing what
/// the search reads — codes, names, or both — carried on the query as
/// [ProductQuery.searchMode]. Everywhere else it is the plain search field.
class ProductQueryControls extends StatefulWidget {
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
    this.searchResetSignal,
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
  final Listenable? searchResetSignal;

  @override
  State<ProductQueryControls> createState() => _ProductQueryControlsState();
}

class _ProductQueryControlsState extends State<ProductQueryControls> {
  bool _pickerEnabled = false;
  bool _resetScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pickerEnabled = ProductSearchModeScope.pickerEnabledOf(context);
    _dropHiddenSearchMode();
  }

  @override
  void didUpdateWidget(covariant ProductQueryControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    _dropHiddenSearchMode();
  }

  /// A search mode nobody can see must not go on narrowing the results.
  ///
  /// The screens keep their query while the cashier is elsewhere, so a search
  /// left on "name" when the picker is switched off in device settings would
  /// come back as a plain-looking field that quietly ignores every code. Put
  /// it back to the ordinary search instead — after the frame, because that
  /// reloads the list and this runs while the tree is being built.
  void _dropHiddenSearchMode() {
    if (_pickerEnabled ||
        _resetScheduled ||
        widget.query.searchMode == ProductSearchMode.all) {
      return;
    }
    _resetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resetScheduled = false;
      final query = widget.query;
      if (!mounted ||
          _pickerEnabled ||
          query.searchMode == ProductSearchMode.all) {
        return;
      }
      widget.onQueryChanged(query.copyWith(searchMode: ProductSearchMode.all));
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final query = widget.query;
    final searchMode = _pickerEnabled
        ? query.searchMode
        : ProductSearchMode.all;

    return QueryControlBar(
      searchValue: query.search,
      searchHint: switch (searchMode) {
        ProductSearchMode.all => widget.searchHint ?? l10n.searchProductsHint,
        ProductSearchMode.code => l10n.productSearchCodeHint,
        ProductSearchMode.name => l10n.productSearchNameHint,
      },
      clearSearchTooltip: l10n.clearSearchTooltip,
      filterLabel: l10n.filtersButtonLabel,
      openFiltersTooltip: l10n.openFiltersTooltip,
      activeFilterCount: _activeFilterCount,
      onSearchChanged: widget.onSearchChanged,
      onOpenFilters: () => _showFilters(context),
      onSearchSubmitted: widget.onSearchSubmitted,
      onOpenCameraScanner: widget.onOpenCameraScanner,
      openCameraScannerTooltip:
          widget.openCameraScannerTooltip ?? l10n.openCameraScannerTooltip,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      searchFieldKey: widget.searchFieldKey,
      searchFocusNode: widget.searchFocusNode,
      searchResetSignal: widget.searchResetSignal,
      searchTrailing: _pickerEnabled
          ? (context, compact) => ProductSearchModePicker(
              mode: searchMode,
              compact: compact,
              enabled: widget.enabled,
              onChanged: (mode) =>
                  widget.onQueryChanged(query.copyWith(searchMode: mode)),
            )
          : null,
    );
  }

  int get _activeFilterCount {
    final query = widget.query;
    return (widget.allowAvailabilityFilter &&
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
          query: widget.query,
          catalogRepository: widget.catalogRepository,
          contactRepository: widget.contactRepository,
          allowAvailabilityFilter: widget.allowAvailabilityFilter,
        );
      },
    );

    if (updatedQuery != null) {
      widget.onQueryChanged(updatedQuery);
    }
  }
}
