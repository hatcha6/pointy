import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/catalog_identity_conflict.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../view_models/variant_generation.dart';
import 'variant_identity_watcher.dart';
import '../../../shared/components/pointy_progress.dart';
import '../../../shared/components/pointy_searchable_picker.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';

/// Lets the user define a product's options (e.g. Color, Size): options already
/// on the product show as removable chips, and everything the shop has saved
/// before is reached through a searchable field that also creates a brand new
/// option from whatever was typed.
///
/// It replaces a wall of "reuse" chips that listed every saved option at once —
/// unreadable once a shop had accumulated more than a handful.
class VariantOptionField extends StatelessWidget {
  const VariantOptionField({
    super.key,
    required this.availableOptions,
    required this.selectedOptions,
    required this.isLoading,
    required this.hasError,
    required this.onReload,
    required this.onToggleOption,
    this.onCreateOption,
  });

  final List<VariantOption> availableOptions;
  final List<VariantOption> selectedOptions;
  final bool isLoading;
  final bool hasError;
  final VoidCallback onReload;
  final ValueChanged<VariantOption> onToggleOption;

  /// Opens the create-option dialog seeded with the name typed into the search
  /// field, so a miss turns straight into the option the user was looking for.
  final ValueChanged<String>? onCreateOption;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final selectedIds = {for (final option in selectedOptions) option.id};
    final byId = {for (final option in availableOptions) option.id: option};
    // Only options not already on this product are offered.
    final reusableOptions = [
      for (final option in availableOptions)
        if (!selectedIds.contains(option.id)) option,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.tune_outlined, size: 18, color: colors.mutedInk),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.variantOptionsLabel,
                style: theme.textTheme.labelLarge,
              ),
            ),
            if (isLoading)
              const SizedBox.square(
                dimension: 16,
                child: PointySpinner(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          l10n.variantOptionsHelper,
          style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
        const SizedBox(height: 10),
        if (hasError)
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.variantOptionsLoadError,
                  style: TextStyle(color: colors.danger),
                ),
              ),
              TextButton.icon(
                onPressed: onReload,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.reloadButton),
              ),
            ],
          )
        else ...[
          if (selectedOptions.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in selectedOptions)
                  InputChip(
                    label: Text(option.displayLabel),
                    onDeleted: () => onToggleOption(option),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    deleteButtonTooltipMessage: l10n.removeVariantOptionTooltip(
                      option.displayLabel,
                    ),
                  ),
              ],
            )
          else
            Text(
              l10n.variantOptionsEmpty,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.mutedInk,
              ),
            ),
          const SizedBox(height: 10),
          TutorTarget(
            anchor: TutorAnchor.productVariantOptionPicker,
            child: PointySearchablePicker<int>(
              fieldKey: const ValueKey('variant_option_search_field'),
              entries: [
                for (final option in reusableOptions)
                  PointyPickerEntry<int>(
                    value: option.id,
                    label: option.displayLabel,
                    subtitle: _valuesPreview(option),
                    keywords: option.code,
                  ),
              ],
              hintText: onCreateOption == null
                  ? l10n.variantOptionSearchHint
                  : l10n.variantOptionSearchOrCreateHint,
              clearTooltip: l10n.clearSearchTooltip,
              noMatchText: l10n.variantOptionSearchNoMatch,
              emptyText: onCreateOption == null
                  ? l10n.variantOptionSearchNoMatch
                  : l10n.variantOptionSearchEmpty,
              onSelected: (id) {
                final option = byId[id];
                if (option != null) {
                  onToggleOption(option);
                }
              },
              onCreate: onCreateOption,
              createLabel: l10n.createVariantOptionInline,
            ),
          ),
        ],
      ],
    );
  }

  /// A one-line taste of what the option holds, so picking "المقاس" from the
  /// menu does not require remembering which sizes it carries.
  String _valuesPreview(VariantOption option) {
    final names = [
      for (final value in option.values)
        if (value.isActive) value.name,
    ];
    if (names.isEmpty) {
      return '';
    }
    const shown = 4;
    if (names.length <= shown) {
      return names.join('، ');
    }
    return '${names.take(shown).join('، ')} +${names.length - shown}';
  }
}

class VariantOptionValuesField extends StatelessWidget {
  const VariantOptionValuesField({
    super.key,
    required this.options,
    required this.selectedValueIdsByOption,
    required this.onToggleValue,
    this.errorOptionIds = const {},
    this.onCreateValue,
    this.onSelectAllValues,
    this.showInactiveSelectedValues = false,
  });

  final List<VariantOption> options;
  final Map<int, Set<int>> selectedValueIdsByOption;
  final void Function(VariantOption option, int valueId) onToggleValue;
  final Set<int> errorOptionIds;

  /// Opens the create-value dialog for [VariantOption], seeded with the name
  /// typed into that option's search field.
  final void Function(VariantOption option, String initialName)? onCreateValue;

  /// Adds every remaining value of an option at once. Left null where only one
  /// value per option can be chosen (editing a single variant), which is also
  /// what hides the button.
  final void Function(VariantOption option)? onSelectAllValues;
  final bool showInactiveSelectedValues;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (options.isEmpty) {
      return Text(l10n.variantValuesNoOptions);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final option in options) ...[
          _OptionValueGroup(
            option: option,
            selectedValueIds: selectedValueIdsByOption[option.id] ?? const {},
            hasError: errorOptionIds.contains(option.id),
            onToggleValue: (valueId) => onToggleValue(option, valueId),
            onCreateValue: onCreateValue == null
                ? null
                : (name) => onCreateValue!(option, name),
            onSelectAll: onSelectAllValues == null
                ? null
                : () => onSelectAllValues!(option),
            showInactiveSelectedValues: showInactiveSelectedValues,
          ),
          if (option != options.last) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class GeneratedVariantsPreview extends StatelessWidget {
  const GeneratedVariantsPreview({
    super.key,
    required this.combinations,
    required this.nameControllers,
    required this.skuControllers,
    required this.barcodeControllers,
    required this.priceControllers,
    required this.activeBySignature,
    required this.defaultSignature,
    required this.onDefaultChanged,
    required this.onActiveChanged,
    required this.requiredValidator,
    required this.numberValidator,
    this.conflictsBySignature = const {},
  });

  /// Duplicate SKU/barcode errors per generated row, keyed by combination
  /// signature. Populated both by the form's own in-payload check and by a
  /// rejected save.
  final Map<String, Map<CatalogIdentityField, CatalogIdentityConflict>>
  conflictsBySignature;

  final List<VariantCombination> combinations;
  final Map<String, TextEditingController> nameControllers;
  final Map<String, TextEditingController> skuControllers;
  final Map<String, TextEditingController> barcodeControllers;
  final Map<String, TextEditingController> priceControllers;
  final Map<String, bool> activeBySignature;
  final String? defaultSignature;
  final ValueChanged<String> onDefaultChanged;
  final void Function(String signature, bool value) onActiveChanged;
  final FormFieldValidator<String> requiredValidator;
  final FormFieldValidator<String> numberValidator;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (combinations.isEmpty) {
      return Text(l10n.generatedVariantsEmpty);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.generatedVariantsCount(combinations.length),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        for (final combination in combinations) ...[
          _GeneratedVariantTile(
            combination: combination,
            nameController: nameControllers[combination.signature]!,
            skuController: skuControllers[combination.signature]!,
            barcodeController: barcodeControllers[combination.signature]!,
            priceController: priceControllers[combination.signature]!,
            isActive: activeBySignature[combination.signature] ?? true,
            isDefault: defaultSignature == combination.signature,
            onDefaultChanged: () => onDefaultChanged(combination.signature),
            onActiveChanged: (value) =>
                onActiveChanged(combination.signature, value),
            requiredValidator: requiredValidator,
            numberValidator: numberValidator,
            conflicts: conflictsBySignature[combination.signature] ?? const {},
          ),
          if (combination != combinations.last) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// One option's values: the ones chosen for this product as removable chips,
/// with the rest reachable through a searchable field rather than a chip per
/// saved value.
class _OptionValueGroup extends StatelessWidget {
  const _OptionValueGroup({
    required this.option,
    required this.selectedValueIds,
    required this.hasError,
    required this.onToggleValue,
    required this.onCreateValue,
    required this.onSelectAll,
    required this.showInactiveSelectedValues,
  });

  final VariantOption option;
  final Set<int> selectedValueIds;
  final bool hasError;
  final ValueChanged<int> onToggleValue;
  final ValueChanged<String>? onCreateValue;
  final VoidCallback? onSelectAll;
  final bool showInactiveSelectedValues;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    // An inactive value that is already on the variant still has to be shown
    // when the caller asks, or editing would silently drop it.
    final selectedValues = [
      for (final value in option.values)
        if (selectedValueIds.contains(value.id) &&
            (value.isActive || showInactiveSelectedValues))
          value,
    ];
    final pickableValues = [
      for (final value in option.values)
        if (value.isActive && !selectedValueIds.contains(value.id)) value,
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: hasError ? colors.danger : colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    option.displayLabel,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (selectedValues.isNotEmpty)
                  Text(
                    l10n.variantOptionSelectedValuesCount(
                      selectedValues.length,
                    ),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.mutedInk,
                    ),
                  ),
                // Picking values one by one is the right default, but "every
                // size we carry" is a real answer and should stay one tap.
                if (onSelectAll != null && pickableValues.isNotEmpty)
                  TutorTarget(
                    anchor: TutorAnchor.productVariantOptionValuesSelectAll,
                    id: option.displayLabel,
                    child: TextButton(
                      onPressed: onSelectAll,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsetsDirectional.only(
                          start: 8,
                          end: 4,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        l10n.selectAllVariantOptionValues(
                          pickableValues.length,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (selectedValues.isEmpty)
              Text(
                option.values.isEmpty
                    ? l10n.variantOptionNoValues
                    : l10n.variantOptionNoValuesSelected,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.mutedInk,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in selectedValues)
                    InputChip(
                      label: Text(value.name),
                      onDeleted: () => onToggleValue(value.id),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      deleteButtonTooltipMessage: l10n
                          .removeVariantOptionValueTooltip(value.name),
                    ),
                ],
              ),
            const SizedBox(height: 10),
            PointySearchablePicker<int>(
              fieldKey: ValueKey('variant_option_value_search_${option.id}'),
              entries: [
                for (final value in pickableValues)
                  PointyPickerEntry<int>(
                    value: value.id,
                    label: value.name,
                    keywords: value.code,
                  ),
              ],
              hintText: onCreateValue == null
                  ? l10n.variantOptionValueSearchHint
                  : l10n.variantOptionValueSearchOrCreateHint,
              clearTooltip: l10n.clearSearchTooltip,
              noMatchText: l10n.variantOptionValueSearchNoMatch,
              emptyText: onCreateValue == null
                  ? l10n.variantOptionValueSearchNoMatch
                  : l10n.variantOptionValueSearchEmpty,
              onSelected: onToggleValue,
              onCreate: onCreateValue,
              createLabel: l10n.createVariantOptionValueInline,
            ),
            if (hasError) ...[
              const SizedBox(height: 6),
              Text(
                l10n.variantOptionValueRequired,
                style: TextStyle(color: colors.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GeneratedVariantTile extends StatelessWidget {
  const _GeneratedVariantTile({
    required this.combination,
    required this.nameController,
    required this.skuController,
    required this.barcodeController,
    required this.priceController,
    required this.isActive,
    required this.isDefault,
    required this.onDefaultChanged,
    required this.onActiveChanged,
    required this.requiredValidator,
    required this.numberValidator,
    this.conflicts = const {},
  });

  final Map<CatalogIdentityField, CatalogIdentityConflict> conflicts;
  final VariantCombination combination;
  final TextEditingController nameController;
  final TextEditingController skuController;
  final TextEditingController barcodeController;
  final TextEditingController priceController;
  final bool isActive;
  final bool isDefault;
  final VoidCallback onDefaultChanged;
  final ValueChanged<bool> onActiveChanged;
  final FormFieldValidator<String> requiredValidator;
  final FormFieldValidator<String> numberValidator;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final skuConflict = conflicts[CatalogIdentityField.sku];
    final barcodeConflict = conflicts[CatalogIdentityField.barcode];
    final skuError = skuConflict == null
        ? null
        : identityConflictMessage(l10n, skuConflict);
    final barcodeError = barcodeConflict == null
        ? null
        : identityConflictMessage(l10n, barcodeConflict);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        // A rejected row reads as rejected at a glance, not only through the
        // small red text inside it.
        border: Border.all(
          color: conflicts.isEmpty ? colors.line : colors.danger,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Checkbox(
                  value: isDefault,
                  onChanged: (_) => onDefaultChanged(),
                ),
                Expanded(
                  child: Text(
                    combination.autoName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (isDefault)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(l10n.defaultVariantBadge),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: l10n.generatedVariantNameLabel,
                hintText: combination.autoName,
                prefixIcon: const Icon(Icons.drive_file_rename_outline),
              ),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: skuController,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: l10n.skuLabel,
                prefixIcon: const Icon(Icons.qr_code_2),
                errorText: skuError,
              ),
              validator: (value) => skuError ?? requiredValidator(value),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: barcodeController,
              decoration: InputDecoration(
                labelText: l10n.barcodeLabel,
                hintText: l10n.barcodeHint,
                prefixIcon: const Icon(Icons.document_scanner_outlined),
                errorText: barcodeError,
              ),
              validator: (_) => barcodeError,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: priceController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [DecimalTextInputFormatter()],
              decoration: InputDecoration(
                labelText: l10n.unitPriceLabel,
                prefixIcon: const Icon(Icons.sell_outlined),
              ),
              validator: numberValidator,
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: Text(l10n.activeVariantLabel),
              value: isActive,
              onChanged: onActiveChanged,
            ),
          ],
        ),
      ),
    );
  }
}
