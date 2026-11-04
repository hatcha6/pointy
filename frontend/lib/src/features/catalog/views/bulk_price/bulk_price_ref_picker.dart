import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/bulk_price_rule.dart';
import '../../../../data/repositories/catalog_repository.dart';
import '../../../../data/repositories/contact_repository.dart';
import '../../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../../shared/contact_picker_sheet.dart';
import '../../../../shared/product_category_picker.dart';

/// Picks the categories or the supplier a rule condition names, shared by the
/// bulk price editor and the bulk tracking page. Null when dismissed.
Future<List<BulkPriceRef>?> pickBulkPriceRefs(
  BuildContext context, {
  required CatalogRepository catalogRepository,
  ContactRepository? contactRepository,
  required BulkPriceField field,
  required List<BulkPriceRef> current,
}) async {
  final l10n = AppLocalizations.of(context)!;
  if (field == BulkPriceField.category) {
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: productCategoryPickerStrings(l10n),
      selected: [
        for (final ref in current)
          AsyncSelectionOption(id: ref.id, label: ref.label, subtitle: ''),
      ],
      loadPage: (search, page) => loadProductCategorySelectionPage(
        catalogRepository: catalogRepository,
        search: search,
        page: page,
      ),
    );
    if (picked == null) return null;
    return [
      for (final option in picked)
        BulkPriceRef(id: option.id, label: option.label),
    ];
  }
  if (field == BulkPriceField.supplier && contactRepository != null) {
    final supplier = await showSupplierPickerSheet(
      context: context,
      repository: contactRepository,
    );
    if (supplier == null) return null;
    return [
      ...current.where((ref) => ref.id != supplier.id),
      BulkPriceRef(id: supplier.id, label: supplier.name),
    ];
  }
  return null;
}
