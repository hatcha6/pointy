import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/variant_option_value_picker.dart';
import 'variant_identity_watcher.dart';

class ProductParentFormFields extends StatelessWidget {
  const ProductParentFormFields({
    super.key,
    required this.nameController,
    required this.descriptionController,
    required this.selectedCategories,
    required this.isActive,
    required this.tracksExpiry,
    required this.onPickCategories,
    required this.onClearCategories,
    required this.onActiveChanged,
    required this.onTracksExpiryChanged,
    required this.requiredValidator,
    this.unit = 'piece',
    this.isService = false,
    this.isPrepared = false,
    this.onUnitChanged,
    this.onIsServiceChanged,
    this.onIsPreparedChanged,
  });

  final TextEditingController nameController;
  final TextEditingController descriptionController;
  final List<AsyncSelectionOption<int>> selectedCategories;
  final bool isActive;
  final bool tracksExpiry;
  final VoidCallback onPickCategories;
  final VoidCallback? onClearCategories;
  final ValueChanged<bool> onActiveChanged;
  final ValueChanged<bool> onTracksExpiryChanged;
  final FormFieldValidator<String> requiredValidator;
  final String unit;
  final bool isService;
  final bool isPrepared;
  final ValueChanged<String>? onUnitChanged;
  final ValueChanged<bool>? onIsServiceChanged;
  final ValueChanged<bool>? onIsPreparedChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final nameField = TextFormField(
      controller: nameController,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: l10n.productNameLabel,
        hintText: l10n.productNameHint,
        prefixIcon: const Icon(Icons.inventory_2_outlined),
      ),
      validator: requiredValidator,
    );
    final categoryField = AsyncSelectionField<int>(
      fieldKey: const ValueKey('product_form_categories_field'),
      strings: productCategoryFieldStrings(l10n),
      selected: selectedCategories,
      onPick: onPickCategories,
      onClear: selectedCategories.isEmpty ? null : onClearCategories,
      validator: (_) => null,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResponsiveFormGrid(maxColumns: 2, children: [nameField, categoryField]),
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
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.activeProductLabel),
          value: isActive,
          onChanged: onActiveChanged,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.productTracksExpiryLabel),
          subtitle: Text(l10n.productTracksExpiryHint),
          value: tracksExpiry,
          onChanged: onTracksExpiryChanged,
        ),
        if (onUnitChanged != null) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: unit,
            decoration: InputDecoration(
              labelText: l10n.productUnitLabel,
              prefixIcon: const Icon(Icons.straighten_outlined),
            ),
            items: [
              DropdownMenuItem(value: 'piece', child: Text(l10n.unitPiece)),
              DropdownMenuItem(value: 'kg', child: Text(l10n.unitKilogram)),
              DropdownMenuItem(value: 'g', child: Text(l10n.unitGram)),
              DropdownMenuItem(value: 'l', child: Text(l10n.unitLiter)),
              DropdownMenuItem(value: 'ml', child: Text(l10n.unitMilliliter)),
            ],
            onChanged: (value) {
              if (value != null) {
                onUnitChanged!(value);
              }
            },
          ),
        ],
        if (onIsPreparedChanged != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.productIsPreparedTitle),
            subtitle: Text(l10n.productIsPreparedDescription),
            value: isPrepared,
            onChanged: onIsPreparedChanged,
          ),
        if (onIsServiceChanged != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.productIsServiceTitle),
            subtitle: Text(l10n.productIsServiceDescription),
            value: isService,
            onChanged: onIsServiceChanged,
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
    this.skuState = const IdentityFieldState(),
    this.barcodeState = const IdentityFieldState(),
    this.skuFieldKey,
    this.barcodeFieldKey,
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

  /// Live "is this code taken?" state for the two identity fields — drives the
  /// inline error, the availability hint and the trailing status icon.
  final IdentityFieldState skuState;
  final IdentityFieldState barcodeState;

  /// Keys the parent uses to scroll a rejected field into view.
  final Key? skuFieldKey;
  final Key? barcodeFieldKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final skuError = identityErrorText(l10n, skuState);
    final barcodeError = identityErrorText(l10n, barcodeState);

    final fields = [
      TextFormField(
        controller: variantNameController,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: l10n.variantNameLabel,
          hintText: l10n.variantNameHint,
          prefixIcon: const Icon(Icons.tune_outlined),
        ),
      ),
      TextFormField(
        key: skuFieldKey,
        controller: skuController,
        textInputAction: TextInputAction.next,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(
          labelText: l10n.skuLabel,
          hintText: l10n.skuHint,
          prefixIcon: const Icon(Icons.qr_code_2),
          suffixIcon: IdentityStatusIcon(state: skuState, isBarcode: false),
          helperText: identityHelperText(l10n, skuState, isBarcode: false),
          // The server error stays visible until the value changes; validator
          // errors (a blank SKU) still win, so both can never show at once.
          errorText: skuError,
        ),
        validator: (value) => skuError ?? requiredValidator(value),
      ),
      BarcodeInputRow(
        fieldKey: barcodeFieldKey,
        controller: barcodeController,
        label: l10n.barcodeLabel,
        hint: l10n.barcodeHint,
        state: barcodeState,
        errorText: barcodeError,
      ),
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
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResponsiveFormGrid(maxColumns: 2, children: fields),
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
          const SizedBox(height: 12),
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

class BarcodeInputRow extends StatelessWidget {
  const BarcodeInputRow({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.fieldKey,
    this.state = const IdentityFieldState(),
    this.errorText,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final Key? fieldKey;
  final IdentityFieldState state;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextFormField(
      key: fieldKey,
      controller: controller,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: const Icon(Icons.document_scanner_outlined),
        suffixIcon: IdentityStatusIcon(state: state, isBarcode: true),
        helperText: identityHelperText(l10n, state, isBarcode: true),
        errorText: errorText,
      ),
      // A barcode is optional, so the only thing that can fail it is a clash —
      // surfaced through the same validator so Form.validate() blocks the save.
      validator: (_) => errorText,
    );
  }
}

/// Trailing marker on an identity field: a spinner while the code is being
/// looked up, a check once it is confirmed free, a muted cloud when the lookup
/// could not run. A taken code shows nothing here — the red error text below
/// the field is the signal.
class IdentityStatusIcon extends StatelessWidget {
  const IdentityStatusIcon({
    super.key,
    required this.state,
    required this.isBarcode,
  });

  final IdentityFieldState state;
  final bool isBarcode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return switch (state.status) {
      IdentityStatus.checking => const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      IdentityStatus.free => Icon(
        Icons.check_circle_outline,
        color: colors.success,
        semanticLabel: isBarcode
            ? l10n.barcodeAvailableLabel
            : l10n.skuAvailableLabel,
      ),
      IdentityStatus.unavailable => Tooltip(
        message: l10n.identityCheckUnavailableLabel,
        child: Icon(Icons.cloud_off_outlined, color: colors.mutedInk),
      ),
      IdentityStatus.idle || IdentityStatus.taken => const SizedBox.shrink(),
    };
  }
}

/// Helper line under an identity field. Only ever *reassuring* text: the
/// negative case is the field's error, which replaces the helper anyway.
String? identityHelperText(
  AppLocalizations l10n,
  IdentityFieldState state, {
  required bool isBarcode,
}) {
  return switch (state.status) {
    IdentityStatus.checking => l10n.identityCheckingLabel,
    IdentityStatus.free =>
      isBarcode ? l10n.barcodeAvailableLabel : l10n.skuAvailableLabel,
    _ => null,
  };
}
