import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/variant_option_value_picker.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import 'variant_identity_watcher.dart';
import '../../../shared/components/pointy_progress.dart';

/// The base units a product can be counted in, for a unit dropdown.
List<DropdownMenuItem<String>> baseUnitDropdownItems(AppLocalizations l10n) {
  return [
    DropdownMenuItem(value: 'piece', child: Text(l10n.unitPiece)),
    DropdownMenuItem(value: 'kg', child: Text(l10n.unitKilogram)),
    DropdownMenuItem(value: 'g', child: Text(l10n.unitGram)),
    DropdownMenuItem(value: 'l', child: Text(l10n.unitLiter)),
    DropdownMenuItem(value: 'ml', child: Text(l10n.unitMilliliter)),
  ];
}

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
    this.onTracksExpiryChanged,
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

  /// Null hides the expiry switch — the sheet then shows the whole tracking
  /// choice in a section of its own.
  final ValueChanged<bool>? onTracksExpiryChanged;
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

    final nameField = TutorTarget(
      anchor: TutorAnchor.productNameField,
      child: TextFormField(
        controller: nameController,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: l10n.productNameLabel,
          hintText: l10n.productNameHint,
          prefixIcon: const Icon(Icons.inventory_2_outlined),
        ),
        validator: requiredValidator,
      ),
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
        if (onTracksExpiryChanged != null)
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
            items: baseUnitDropdownItems(l10n),
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
    required this.numberValidator,
    this.showDefaultToggle = true,
    this.showOptionValues = true,
    this.skuState = const IdentityFieldState(),
    this.barcodeState = const IdentityFieldState(),
    this.skuIsAutomatic = false,
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
  final FormFieldValidator<String> numberValidator;
  final bool showDefaultToggle;
  final bool showOptionValues;

  /// Live "is this code taken?" state for the two identity fields — drives the
  /// inline error, the availability hint and the trailing status icon.
  final IdentityFieldState skuState;
  final IdentityFieldState barcodeState;

  /// The SKU field still holds the number the form filled in — said under the
  /// field, so the owner knows the code is the shop's next one and theirs to
  /// change.
  final bool skuIsAutomatic;

  /// Keys the parent uses to scroll a rejected field into view.
  final Key? skuFieldKey;
  final Key? barcodeFieldKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
      TutorTarget(
        anchor: TutorAnchor.productSkuField,
        child: VariantSkuField(
          fieldKey: skuFieldKey,
          controller: skuController,
          state: skuState,
          isAutomatic: skuIsAutomatic,
        ),
      ),
      TutorTarget(
        anchor: TutorAnchor.productBarcodeField,
        child: BarcodeInputRow(
          fieldKey: barcodeFieldKey,
          controller: barcodeController,
          label: l10n.barcodeLabel,
          hint: l10n.barcodeHint,
          state: barcodeState,
          errorText: barcodeError,
          skuController: skuController,
        ),
      ),
      TutorTarget(
        anchor: TutorAnchor.productPriceField,
        child: TextFormField(
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

/// A variant's SKU, with its live "is this code taken?" status.
///
/// Optional, like the barcode beside it: a shop that keeps no SKUs should not
/// have to invent one, and the server codes a blank row itself.
class VariantSkuField extends StatelessWidget {
  const VariantSkuField({
    super.key,
    required this.controller,
    required this.state,
    this.fieldKey,
    this.isAutomatic = false,
  });

  final TextEditingController controller;
  final IdentityFieldState state;
  final Key? fieldKey;

  /// The field still holds the number the form filled in — said under the
  /// field, so the owner knows the code is the shop's next one and theirs to
  /// change.
  final bool isAutomatic;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final error = identityErrorText(l10n, state);
    return TextFormField(
      key: fieldKey,
      controller: controller,
      textInputAction: TextInputAction.next,
      textCapitalization: TextCapitalization.characters,
      decoration: InputDecoration(
        labelText: l10n.skuLabel,
        hintText: l10n.skuHint,
        prefixIcon: const Icon(Icons.qr_code_2),
        suffixIcon: IdentityStatusIcon(state: state, isBarcode: false),
        // Says it is optional while there is no live status to report.
        helperText: isAutomatic
            ? l10n.skuAutomaticHelper
            : identityHelperText(l10n, state, isBarcode: false) ??
                  l10n.skuOptionalHelper,
        // The server error stays visible until the value changes.
        errorText: error,
      ),
      // Only a clash can fail a SKU — surfaced through the validator so
      // Form.validate() blocks the save, exactly as the barcode does.
      validator: (_) => error,
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
    this.skuController,
    this.focusNode,
    this.onEditingComplete,
    this.idleHelperText,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final Key? fieldKey;
  final IdentityFieldState state;
  final String? errorText;
  final FocusNode? focusNode;

  /// Replaces the default "move to the next field" on Enter — the product
  /// form walks a fixed path of essential fields instead.
  final VoidCallback? onEditingComplete;

  /// Shown under the field while there is no availability status to report.
  final String? idleHelperText;

  /// The SKU beside this barcode. When given, the field offers a one-click
  /// "barcode = SKU" — see [UseSkuAsBarcodeButton].
  final TextEditingController? skuController;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final status = IdentityStatusIcon(state: state, isBarcode: true);
    final sku = skuController;
    return TextFormField(
      key: fieldKey,
      controller: controller,
      focusNode: focusNode,
      textInputAction: TextInputAction.next,
      onEditingComplete: onEditingComplete,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: const Icon(Icons.document_scanner_outlined),
        suffixIcon: sku == null
            ? status
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  status,
                  UseSkuAsBarcodeButton(sku: sku, barcode: controller),
                ],
              ),
        helperText:
            identityHelperText(l10n, state, isBarcode: true) ?? idleHelperText,
        errorText: errorText,
      ),
      // A barcode is optional, so the only thing that can fail it is a clash —
      // surfaced through the same validator so Form.validate() blocks the save.
      validator: (_) => errorText,
    );
  }
}

/// One click to make a barcode the same code as its SKU.
///
/// A shop printing its own labels for goods that arrived without a barcode
/// wants the label to scan as the number the product is filed under, and
/// retyping it is where the two drift apart. Copies the SKU as it will be
/// saved — upper-cased, the way the server stores it — and is disabled while
/// there is nothing to copy or the two already match.
class UseSkuAsBarcodeButton extends StatelessWidget {
  const UseSkuAsBarcodeButton({
    super.key,
    required this.sku,
    required this.barcode,
  });

  final TextEditingController sku;
  final TextEditingController barcode;

  String get _code => sku.text.trim().toUpperCase();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Out of the Tab/Enter order. A scanner ends a barcode with Enter, and
    // focus landing here would put the next keystroke on this button — which
    // replaces the code just scanned with the SKU.
    return ExcludeFocusTraversal(
      child: ListenableBuilder(
        listenable: Listenable.merge([sku, barcode]),
        builder: (context, _) {
          final code = _code;
          return IconButton(
            tooltip: l10n.useSkuAsBarcodeTooltip,
            icon: const Icon(Icons.content_copy_outlined),
            // Read again on the click: a code typed since the last frame is
            // the one the user means.
            onPressed: code.isEmpty || barcode.text.trim() == code
                ? null
                : () => barcode.text = _code,
          );
        },
      ),
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
          child: PointySpinner(strokeWidth: 2),
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
