import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../core/result.dart';
import '../data/models/product_category.dart';
import '../data/models/product_category_query.dart';
import '../data/repositories/catalog_repository.dart';
import 'async_selection/async_multi_select_picker.dart';

AsyncSelectionOption<int> productCategoryOption(ProductCategory category) {
  return AsyncSelectionOption<int>(
    id: category.id,
    label: category.name,
    subtitle: category.parentName,
  );
}

Future<AsyncSelectionPage<int>> loadProductCategorySelectionPage({
  required CatalogRepository catalogRepository,
  required String search,
  required int page,
}) async {
  final result = await catalogRepository.loadProductCategories(
    query: ProductCategoryQuery(
      search: search,
      availability: ProductCategoryAvailabilityFilter.active,
    ),
    page: page,
  );
  return switch (result) {
    Ok(value: final categoryPage) => AsyncSelectionPage<int>(
      options: [
        for (final category in categoryPage.categories)
          productCategoryOption(category),
      ],
      hasMore: categoryPage.hasMore,
    ),
    Error() => throw Exception('product category picker failed'),
  };
}

AsyncSelectionFieldStrings<int> productCategoryFieldStrings(
  AppLocalizations l10n,
) {
  return AsyncSelectionFieldStrings<int>(
    label: l10n.productCategoriesLabel,
    emptyText: l10n.productCategoriesEmpty,
    helperText: l10n.productCategoriesHelper,
    clearTooltip: l10n.clearButton,
    openPickerTooltip: l10n.productCategoriesOpenPickerTooltip,
    fallbackLabelForId: l10n.productCategoryFallbackLabel,
  );
}

AsyncSelectionPickerStrings<int> productCategoryPickerStrings(
  AppLocalizations l10n,
) {
  return AsyncSelectionPickerStrings<int>(
    title: l10n.productCategoryPickerTitle,
    searchHint: l10n.categorySearchHint,
    emptyText: l10n.productCategoryPickerEmpty,
    clearText: l10n.clearButton,
    clearSearchTooltip: l10n.clearSearchTooltip,
    loadErrorText: l10n.categoriesLoadError,
    confirmText: l10n.confirmButton,
    fallbackLabelForId: l10n.productCategoryFallbackLabel,
  );
}
