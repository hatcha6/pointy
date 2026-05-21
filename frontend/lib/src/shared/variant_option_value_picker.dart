import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../core/result.dart';
import '../data/models/variant_option_value.dart';
import '../data/models/variant_option_value_query.dart';
import '../data/repositories/catalog_repository.dart';
import 'async_selection/async_multi_select_picker.dart';

AsyncSelectionOption<int> variantOptionValueOption(
  VariantOptionValue optionValue,
) {
  return AsyncSelectionOption<int>(
    id: optionValue.id,
    label: optionValue.displayLabel,
    subtitle: optionValue.code,
  );
}

Future<AsyncSelectionPage<int>> loadVariantOptionValueSelectionPage({
  required CatalogRepository catalogRepository,
  required String search,
  required int page,
}) async {
  final result = await catalogRepository.loadVariantOptionValues(
    query: VariantOptionValueQuery(
      search: search,
      availability: VariantOptionValueAvailabilityFilter.active,
    ),
    page: page,
  );
  return switch (result) {
    Ok(value: final optionValuePage) => AsyncSelectionPage<int>(
      options: [
        for (final optionValue in optionValuePage.optionValues)
          variantOptionValueOption(optionValue),
      ],
      hasMore: optionValuePage.hasMore,
    ),
    Error() => throw Exception('variant option value picker failed'),
  };
}

AsyncSelectionFieldStrings<int> variantOptionValueFieldStrings(
  AppLocalizations l10n,
) {
  return AsyncSelectionFieldStrings<int>(
    label: l10n.variantOptionValuesLabel,
    emptyText: l10n.variantOptionValuesEmpty,
    helperText: l10n.variantOptionValuesHelper,
    clearTooltip: l10n.clearButton,
    openPickerTooltip: l10n.variantOptionValuesOpenPickerTooltip,
    fallbackLabelForId: l10n.variantOptionValueFallbackLabel,
  );
}

AsyncSelectionPickerStrings<int> variantOptionValuePickerStrings(
  AppLocalizations l10n,
) {
  return AsyncSelectionPickerStrings<int>(
    title: l10n.variantOptionValuePickerTitle,
    searchHint: l10n.variantOptionValuePickerSearchHint,
    emptyText: l10n.variantOptionValuePickerEmpty,
    clearText: l10n.clearButton,
    clearSearchTooltip: l10n.clearSearchTooltip,
    loadErrorText: l10n.variantOptionValuePickerLoadError,
    confirmText: l10n.confirmButton,
    fallbackLabelForId: l10n.variantOptionValueFallbackLabel,
  );
}
