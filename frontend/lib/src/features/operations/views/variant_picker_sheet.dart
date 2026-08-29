import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/product_query.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_page.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../shared/components/components.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

/// Search-and-pick a product variant by name/SKU/barcode.
///
/// Returns the chosen [ProductVariant] or null. [where] narrows the results —
/// the job-services picker passes `isService`, so a technician adding "كشف
/// وتشخيص" is never offered a screen or a brake pad.
Future<ProductVariant?> showVariantPickerSheet(
  BuildContext context, {
  required CatalogRepository catalogRepository,
  String? title,
  bool Function(ProductVariant variant)? where,
  String? emptyMessage,
}) {
  return showAdaptiveModalBottomSheet<ProductVariant>(
    context: context,
    builder: (sheetContext) => _VariantPickerSheet(
      catalogRepository: catalogRepository,
      title: title,
      where: where,
      emptyMessage: emptyMessage,
    ),
  );
}

class _VariantPickerSheet extends StatefulWidget {
  const _VariantPickerSheet({
    required this.catalogRepository,
    this.title,
    this.where,
    this.emptyMessage,
  });

  final CatalogRepository catalogRepository;
  final String? title;
  final bool Function(ProductVariant variant)? where;
  final String? emptyMessage;

  @override
  State<_VariantPickerSheet> createState() => _VariantPickerSheetState();
}

class _VariantPickerSheetState extends State<_VariantPickerSheet> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  var _isLoading = false;
  var _hasError = false;
  List<ProductVariant> _variants = const [];

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _search(value);
    });
  }

  Future<void> _search(String query) async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });
    final result = await widget.catalogRepository.loadProductVariants(
      query: ProductQuery(search: query),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoading = false;
      switch (result) {
        case Ok<ProductVariantPage>():
          _variants = result.value.variants
              .where((variant) => variant.isActive)
              .where((variant) => widget.where?.call(variant) ?? true)
              .toList(growable: false);
        case Error<ProductVariantPage>():
          _hasError = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.title != null)
              Padding(
                padding: EdgeInsets.only(bottom: spacing.sm),
                child: Text(
                  widget.title!,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            TextField(
              controller: _searchController,
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.searchProductsHint,
              ),
              onChanged: _onQueryChanged,
            ),
            SizedBox(height: spacing.sm),
            Flexible(
              child: _isLoading
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: PointySpinner()),
                    )
                  : _hasError
                  ? PointyEmptyState(
                      icon: Icons.warning_amber_outlined,
                      title: l10n.operationsActionError,
                    )
                  : _variants.isEmpty
                  ? PointyEmptyState(
                      icon: Icons.search_off_outlined,
                      title: widget.emptyMessage ?? l10n.dashboardNoWidgetData,
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _variants.length,
                      itemBuilder: (context, index) {
                        final variant = _variants[index];
                        return ListTile(
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: Text(variant.displayLabel),
                          subtitle: Text(
                            [
                              if (variant.sku.trim().isNotEmpty) variant.sku,
                              formatMoney(variant.unitPrice),
                            ].join(' · '),
                          ),
                          onTap: () => Navigator.of(context).pop(variant),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
