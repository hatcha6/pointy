import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/variant_option_value_picker.dart';

class ProductParentFormFields extends StatelessWidget {
  const ProductParentFormFields({
    super.key,
    required this.nameController,
    required this.descriptionController,
    required this.selectedCategories,
    required this.isActive,
    required this.onPickCategories,
    required this.onClearCategories,
    required this.onActiveChanged,
    required this.requiredValidator,
  });

  final TextEditingController nameController;
  final TextEditingController descriptionController;
  final List<AsyncSelectionOption<int>> selectedCategories;
  final bool isActive;
  final VoidCallback onPickCategories;
  final VoidCallback? onClearCategories;
  final ValueChanged<bool> onActiveChanged;
  final FormFieldValidator<String> requiredValidator;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        TextFormField(
          controller: nameController,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.productNameLabel,
            hintText: l10n.productNameHint,
            prefixIcon: const Icon(Icons.inventory_2_outlined),
          ),
          validator: requiredValidator,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: descriptionController,
          minLines: 2,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: l10n.descriptionLabel,
            hintText: l10n.descriptionHint,
            prefixIcon: const Icon(Icons.notes_outlined),
          ),
        ),
        const SizedBox(height: 12),
        AsyncSelectionField<int>(
          fieldKey: const ValueKey('product_form_categories_field'),
          strings: productCategoryFieldStrings(l10n),
          selected: selectedCategories,
          onPick: onPickCategories,
          onClear: selectedCategories.isEmpty ? null : onClearCategories,
          validator: (_) => null,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.activeProductLabel),
          value: isActive,
          onChanged: onActiveChanged,
        ),
      ],
    );
  }
}

class ProductVariantFormFields extends StatelessWidget {
  const ProductVariantFormFields({
    super.key,
    required this.variantNameController,
    required this.skuController,
    required this.barcodeController,
    required this.priceController,
    required this.selectedOptionValues,
    required this.isActive,
    required this.isDefault,
    required this.onPickOptionValues,
    required this.onClearOptionValues,
    required this.onActiveChanged,
    required this.onDefaultChanged,
    required this.requiredValidator,
    required this.numberValidator,
    this.showDefaultToggle = true,
    this.showOptionValues = true,
  });

  final TextEditingController variantNameController;
  final TextEditingController skuController;
  final TextEditingController barcodeController;
  final TextEditingController priceController;
  final List<AsyncSelectionOption<int>> selectedOptionValues;
  final bool isActive;
  final bool isDefault;
  final VoidCallback onPickOptionValues;
  final VoidCallback? onClearOptionValues;
  final ValueChanged<bool> onActiveChanged;
  final ValueChanged<bool> onDefaultChanged;
  final FormFieldValidator<String> requiredValidator;
  final FormFieldValidator<String> numberValidator;
  final bool showDefaultToggle;
  final bool showOptionValues;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        TextFormField(
          controller: variantNameController,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.variantNameLabel,
            hintText: l10n.variantNameHint,
            prefixIcon: const Icon(Icons.tune_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: skuController,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: l10n.skuLabel,
            hintText: l10n.skuHint,
            prefixIcon: const Icon(Icons.qr_code_2),
          ),
          validator: requiredValidator,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: barcodeController,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.barcodeLabel,
            hintText: l10n.barcodeHint,
            prefixIcon: const Icon(Icons.document_scanner_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: priceController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.done,
          inputFormatters: [DecimalTextInputFormatter()],
          decoration: InputDecoration(
            labelText: l10n.unitPriceLabel,
            prefixIcon: const Icon(Icons.sell_outlined),
          ),
          validator: numberValidator,
        ),
        const SizedBox(height: 12),
        if (showOptionValues) ...[
          AsyncSelectionField<int>(
            fieldKey: const ValueKey('product_variant_option_values_field'),
            strings: variantOptionValueFieldStrings(l10n),
            selected: selectedOptionValues,
            onPick: onPickOptionValues,
            onClear: selectedOptionValues.isEmpty ? null : onClearOptionValues,
            validator: (_) => null,
          ),
          const SizedBox(height: 8),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.activeVariantLabel),
          value: isActive,
          onChanged: onActiveChanged,
        ),
        if (showDefaultToggle)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.defaultVariantLabel),
            value: isDefault,
            onChanged: onDefaultChanged,
          ),
      ],
    );
  }
}
