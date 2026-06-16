import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/variant_option.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../view_models/variant_generation.dart';

class VariantOptionTemplateField extends StatelessWidget {
  const VariantOptionTemplateField({
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
  final VoidCallback? onCreateOption;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final selectedIds = {for (final option in selectedOptions) option.id};

    return FormField<List<VariantOption>>(
      initialValue: selectedOptions,
      builder: (field) {
        return InputDecorator(
          decoration: InputDecoration(
            labelText: l10n.variantOptionsLabel,
            helperText: l10n.variantOptionsHelper,
            prefixIcon: const Icon(Icons.tune_outlined),
            errorText: hasError ? l10n.variantOptionsLoadError : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isLoading) const LinearProgressIndicator(),
              if (hasError)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: onReload,
                    icon: const Icon(Icons.refresh),
                    label: Text(l10n.reloadButton),
                  ),
                )
              else ...[
                if (availableOptions.isEmpty && !isLoading)
                  Text(l10n.variantOptionsEmpty)
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final option in availableOptions)
                        FilterChip(
                          label: Text(option.displayLabel),
                          selected: selectedIds.contains(option.id),
                          onSelected: (_) => onToggleOption(option),
                        ),
                    ],
                  ),
                if (onCreateOption != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      onPressed: onCreateOption,
                      icon: const Icon(Icons.add),
                      label: Text(l10n.addVariantOptionButton),
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
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
    this.showInactiveSelectedValues = false,
  });

  final List<VariantOption> options;
  final Map<int, Set<int>> selectedValueIdsByOption;
  final void Function(VariantOption option, int valueId) onToggleValue;
  final Set<int> errorOptionIds;
  final void Function(VariantOption option)? onCreateValue;
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
                : () => onCreateValue!(option),
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
  });

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
          ),
          if (combination != combinations.last) const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _OptionValueGroup extends StatelessWidget {
  const _OptionValueGroup({
    required this.option,
    required this.selectedValueIds,
    required this.hasError,
    required this.onToggleValue,
    required this.onCreateValue,
    required this.showInactiveSelectedValues,
  });

  final VariantOption option;
  final Set<int> selectedValueIds;
  final bool hasError;
  final ValueChanged<int> onToggleValue;
  final VoidCallback? onCreateValue;
  final bool showInactiveSelectedValues;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final visibleValues = [
      for (final value in option.values)
        if (value.isActive ||
            (showInactiveSelectedValues && selectedValueIds.contains(value.id)))
          value,
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: hasError ? colors.danger : colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              option.displayLabel,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (visibleValues.isEmpty)
              Text(l10n.variantOptionNoValues)
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final value in visibleValues)
                    FilterChip(
                      label: Text(value.name),
                      selected: selectedValueIds.contains(value.id),
                      onSelected: (_) => onToggleValue(value.id),
                    ),
                ],
              ),
            if (onCreateValue != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  onPressed: onCreateValue,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.addVariantOptionValueButton),
                ),
              ),
            ],
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
  });

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

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
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
              ),
              validator: requiredValidator,
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: barcodeController,
              decoration: InputDecoration(
                labelText: l10n.barcodeLabel,
                hintText: l10n.barcodeHint,
                prefixIcon: const Icon(Icons.document_scanner_outlined),
              ),
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
