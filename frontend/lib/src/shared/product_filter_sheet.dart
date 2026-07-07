import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/product_category.dart';
import '../data/models/product_query.dart';
import '../data/repositories/catalog_repository.dart';
import '../data/repositories/contact_repository.dart';
import 'async_selection/async_multi_select_picker.dart';
import 'components/components.dart';
import 'contact_picker_sheet.dart';
import 'product_category_picker.dart';
import 'query_controls/query_filter_sheet.dart';

class ProductFilterSheet extends StatefulWidget {
  const ProductFilterSheet({
    super.key,
    required this.query,
    required this.catalogRepository,
    required this.allowAvailabilityFilter,
    this.contactRepository,
  });

  final ProductQuery query;
  final CatalogRepository catalogRepository;
  final bool allowAvailabilityFilter;

  /// When provided, the sheet shows a "supplier" filter (products supplied by
  /// the chosen supplier, resolved through their purchase orders). Omitted for
  /// contexts where supplier filtering doesn't apply (e.g. POS).
  final ContactRepository? contactRepository;

  @override
  State<ProductFilterSheet> createState() => _ProductFilterSheetState();
}

class _ProductFilterSheetState extends State<ProductFilterSheet> {
  late ProductAvailabilityFilter _availability;
  late ProductOrdering _ordering;
  late List<AsyncSelectionOption<int>> _selectedCategories;
  late int? _supplierId;
  late String? _supplierName;

  @override
  void initState() {
    super.initState();
    _availability = widget.query.availability;
    _ordering = widget.query.ordering;
    _selectedCategories = [
      for (final category in widget.query.categories)
        productCategoryOption(category),
    ];
    _supplierId = widget.query.supplierId;
    _supplierName = widget.query.supplierName;
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
              label: l10n.orderingMostBought,
              icon: Icons.local_fire_department,
              isSelected: _ordering == ProductOrdering.mostBought,
              onTap: () => _selectOrdering(ProductOrdering.mostBought),
            ),
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
        const SizedBox(height: 22),
        QueryFilterSection(
          title: l10n.categoryFilterTitle,
          children: [
            AsyncSelectionField<int>(
              fieldKey: const ValueKey('product_category_filter_field'),
              strings: productCategoryFieldStrings(l10n),
              selected: _selectedCategories,
              onPick: () => _pickCategories(context),
              onClear: _selectedCategories.isEmpty
                  ? null
                  : () => setState(() => _selectedCategories = []),
              validator: (_) => null,
            ),
          ],
        ),
        if (widget.contactRepository != null) ...[
          const SizedBox(height: 22),
          QueryFilterSection(
            title: l10n.purchaseOrderSupplierFilterTitle,
            children: [
              ListTile(
                leading: const Icon(Icons.local_shipping_outlined),
                title: Text(_supplierName ?? l10n.allSuppliersFilterLabel),
                trailing: _supplierId == null
                    ? const PointyDisclosureChevron()
                    : IconButton(
                        tooltip: l10n.clearSupplierFilterTooltip,
                        onPressed: () => setState(() {
                          _supplierId = null;
                          _supplierName = null;
                        }),
                        icon: const Icon(Icons.close),
                      ),
                onTap: _chooseSupplier,
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _chooseSupplier() async {
    final repository = widget.contactRepository;
    if (repository == null) {
      return;
    }
    final supplier = await showSupplierPickerSheet(
      context: context,
      repository: repository,
    );
    if (!mounted || supplier == null) {
      return;
    }
    setState(() {
      _supplierId = supplier.id;
      _supplierName = supplier.name;
    });
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
      _selectedCategories = [];
      // Reset to the surface's own default sort (most-bought on POS/catalog,
      // A–Z elsewhere) rather than hard-coding A–Z, which would drop the
      // most-bought default whenever a cashier taps Reset.
      _ordering = widget.query.ordering;
      _supplierId = null;
      _supplierName = null;
    });
  }

  void _apply() {
    Navigator.of(context).pop(
      widget.query
          .copyWith(
            availability: widget.allowAvailabilityFilter
                ? _availability
                : widget.query.availability,
            categories: [
              for (final option in _selectedCategories)
                ProductCategory(id: option.id, name: option.label),
            ],
            ordering: _ordering,
          )
          .withSupplier(supplierId: _supplierId, supplierName: _supplierName),
    );
  }

  Future<void> _pickCategories(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: productCategoryPickerStrings(l10n),
      selected: _selectedCategories,
      searchFieldKey: const ValueKey('product_category_filter_search_field'),
      applyButtonKey: const ValueKey('product_category_filter_apply_button'),
      optionKeyForId: (id) => ValueKey('product_category_filter_option_$id'),
      loadPage: (search, page) => loadProductCategorySelectionPage(
        catalogRepository: widget.catalogRepository,
        search: search,
        page: page,
      ),
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedCategories = picked);
  }
}
