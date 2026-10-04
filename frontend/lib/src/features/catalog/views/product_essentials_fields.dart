import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../view_models/product_entry_run.dart';
import 'product_entry_pins.dart';
import 'product_form_fields.dart';
import 'variant_identity_watcher.dart';

/// The few fields nearly every new product needs, first on the form and in
/// the order a shop types them in: barcode, name, price, then the
/// classification a whole shelf tends to share.
///
/// Enter walks barcode → name → price (and on into the opening stock below)
/// through [onEnter]; Tab still visits every field. While the product
/// generates variants, its barcode, SKU and price belong to each generated
/// row instead, so [showsSellingFields] leaves them out.
class ProductEssentialsFields extends StatelessWidget {
  const ProductEssentialsFields({
    super.key,
    required this.showsSellingFields,
    required this.barcodeController,
    required this.barcodeFocusNode,
    required this.barcodeFieldKey,
    required this.barcodeState,
    required this.skuController,
    required this.skuFieldKey,
    required this.skuState,
    required this.skuIsAutomatic,
    required this.nameController,
    required this.nameFocusNode,
    required this.priceController,
    required this.priceFocusNode,
    required this.selectedCategories,
    required this.onPickCategories,
    required this.onClearCategories,
    required this.unit,
    required this.onUnitChanged,
    required this.tracksExpiry,
    this.onTracksExpiryChanged,
    required this.onEnter,
    required this.requiredValidator,
    required this.numberValidator,
    this.pricingCurrencyField,
    this.pins = const {},
    this.pinScopes = const {},
    this.nameWarning,
  });

  final bool showsSellingFields;
  final TextEditingController barcodeController;
  final FocusNode barcodeFocusNode;
  final Key barcodeFieldKey;
  final IdentityFieldState barcodeState;
  final TextEditingController skuController;
  final Key skuFieldKey;
  final IdentityFieldState skuState;
  final bool skuIsAutomatic;
  final TextEditingController nameController;
  final FocusNode nameFocusNode;
  final TextEditingController priceController;
  final FocusNode priceFocusNode;
  final List<AsyncSelectionOption<int>> selectedCategories;
  final VoidCallback onPickCategories;
  final VoidCallback onClearCategories;
  final String unit;
  final ValueChanged<String> onUnitChanged;
  final bool tracksExpiry;

  /// Null hides the switch: a shop that identifies stock chooses how in the
  /// form's tracking section instead, and two controls over one choice is how
  /// they end up disagreeing.
  final ValueChanged<bool>? onTracksExpiryChanged;

  /// Enter in one of the essential text fields, named by its focus node.
  final ValueChanged<FocusNode> onEnter;
  final FormFieldValidator<String> requiredValidator;
  final FormFieldValidator<String> numberValidator;

  /// The price-sheet currency picker, when the shop prices in more than one.
  final Widget? pricingCurrencyField;

  /// One per carried field once a run of products has begun; empty before.
  final Map<ProductCarryField, FieldPin> pins;
  final Map<ProductCarryField, FocusNode> pinScopes;

  /// A warning about the name — that it is still the previous product's.
  final String? nameWarning;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    final nameField = PinnableField(
      pin: pins[ProductCarryField.name],
      focusScope: pinScopes[ProductCarryField.name],
      // The warning already says the name is the previous product's.
      showKeptLabel: nameWarning == null,
      child: TutorTarget(
        anchor: TutorAnchor.productNameField,
        child: TextFormField(
          controller: nameController,
          focusNode: nameFocusNode,
          // Desktop and web select a whole field on focus; a carried or
          // copied name keeps its cursor at the end instead, where
          // Ctrl+Backspace takes off the last word.
          selectAllOnFocus: false,
          textInputAction: TextInputAction.next,
          onEditingComplete: () => onEnter(nameFocusNode),
          decoration: InputDecoration(
            labelText: l10n.productNameLabel,
            hintText: l10n.productNameHint,
            prefixIcon: const Icon(Icons.inventory_2_outlined),
            fillColor: pins[ProductCarryField.name]?.fillColor(context),
            helperText: nameWarning,
            helperMaxLines: 2,
            helperStyle: nameWarning == null
                ? null
                : textTheme.bodySmall?.copyWith(
                    color: colors.warning,
                    fontWeight: FontWeight.w700,
                  ),
          ),
          validator: requiredValidator,
        ),
      ),
    );

    final priceField = PinnableField(
      pin: pins[ProductCarryField.price],
      focusScope: pinScopes[ProductCarryField.price],
      child: TutorTarget(
        anchor: TutorAnchor.productPriceField,
        child: TextFormField(
          controller: priceController,
          focusNode: priceFocusNode,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.next,
          onEditingComplete: () => onEnter(priceFocusNode),
          inputFormatters: [DecimalTextInputFormatter()],
          decoration: InputDecoration(
            labelText: l10n.unitPriceLabel,
            prefixIcon: const Icon(Icons.sell_outlined),
            fillColor: pins[ProductCarryField.price]?.fillColor(context),
          ),
          validator: numberValidator,
        ),
      ),
    );

    final categoryField = PinnableField(
      pin: pins[ProductCarryField.category],
      focusScope: pinScopes[ProductCarryField.category],
      child: AsyncSelectionField<int>(
        fieldKey: const ValueKey('product_form_categories_field'),
        strings: productCategoryFieldStrings(l10n),
        selected: selectedCategories,
        onPick: onPickCategories,
        onClear: selectedCategories.isEmpty ? null : onClearCategories,
        validator: (_) => null,
        fillColor: pins[ProductCarryField.category]?.fillColor(context),
      ),
    );

    final unitField = PinnableField(
      pin: pins[ProductCarryField.unit],
      focusScope: pinScopes[ProductCarryField.unit],
      child: DropdownButtonFormField<String>(
        initialValue: unit,
        decoration: InputDecoration(
          labelText: l10n.productUnitLabel,
          prefixIcon: const Icon(Icons.straighten_outlined),
          fillColor: pins[ProductCarryField.unit]?.fillColor(context),
        ),
        items: baseUnitDropdownItems(l10n),
        onChanged: (value) {
          if (value != null) {
            onUnitChanged(value);
          }
        },
      ),
    );

    final expiryPin = pins[ProductCarryField.tracksExpiry];
    final expiryField = PinnableField(
      pin: expiryPin,
      focusScope: pinScopes[ProductCarryField.tracksExpiry],
      child: Tooltip(
        message: l10n.productTracksExpiryHint,
        child: SwitchListTile(
          contentPadding: const EdgeInsetsDirectional.only(start: 12, end: 4),
          tileColor: expiryPin?.fillColor(context),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PointyRadii.input),
          ),
          title: Text(l10n.productTracksExpiryLabel),
          value: tracksExpiry,
          onChanged: onTracksExpiryChanged,
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showsSellingFields) ...[
          ResponsiveFormGrid(
            maxColumns: 2,
            children: [
              TutorTarget(
                anchor: TutorAnchor.productBarcodeField,
                child: BarcodeInputRow(
                  fieldKey: barcodeFieldKey,
                  controller: barcodeController,
                  focusNode: barcodeFocusNode,
                  onEditingComplete: () => onEnter(barcodeFocusNode),
                  label: l10n.barcodeLabel,
                  hint: l10n.barcodeHint,
                  state: barcodeState,
                  errorText: identityErrorText(l10n, barcodeState),
                  skuController: skuController,
                  idleHelperText: l10n.productBarcodeScanAnywhereHelper,
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
            ],
          ),
          const SizedBox(height: 12),
        ],
        nameField,
        const SizedBox(height: 12),
        if (showsSellingFields && pricingCurrencyField != null) ...[
          pricingCurrencyField!,
          const SizedBox(height: 12),
        ],
        ResponsiveFormGrid(
          maxColumns: 2,
          children: [
            if (showsSellingFields) priceField,
            categoryField,
            unitField,
            if (onTracksExpiryChanged != null) expiryField,
          ],
        ),
      ],
    );
  }
}
