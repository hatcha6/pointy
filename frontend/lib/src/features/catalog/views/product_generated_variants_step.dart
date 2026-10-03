import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/catalog_identity_conflict.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../view_models/variant_generation.dart';
import 'variant_generation_fields.dart';

/// The second step of a new product that generates variants: a SKU prefix, one
/// price for all of them, the option values to combine, and every resulting
/// row to adjust before it is created.
class ProductGeneratedVariantsStep extends StatelessWidget {
  const ProductGeneratedVariantsStep({
    super.key,
    required this.skuController,
    required this.priceController,
    required this.selectedOptions,
    required this.selectedValueIdsByOption,
    required this.errorOptionIds,
    required this.combinations,
    required this.nameControllers,
    required this.skuControllers,
    required this.barcodeControllers,
    required this.priceControllers,
    required this.activeBySignature,
    required this.defaultSignature,
    required this.onToggleValue,
    required this.onCreateValue,
    required this.onSelectAllValues,
    required this.onDefaultChanged,
    required this.onVariantActiveChanged,
    required this.numberValidator,
    required this.generationErrorText,
    required this.conflictsBySignature,
    this.openingQuantityControllers,
    this.openingCostControllers,
  });

  final TextEditingController skuController;
  final TextEditingController priceController;
  final List<VariantOption> selectedOptions;
  final Map<int, Set<int>> selectedValueIdsByOption;
  final Set<int> errorOptionIds;
  final List<VariantCombination> combinations;
  final Map<String, TextEditingController> nameControllers;
  final Map<String, TextEditingController> skuControllers;
  final Map<String, TextEditingController> barcodeControllers;
  final Map<String, TextEditingController> priceControllers;
  final Map<String, TextEditingController>? openingQuantityControllers;
  final Map<String, TextEditingController>? openingCostControllers;
  final Map<String, bool> activeBySignature;
  final String? defaultSignature;
  final void Function(VariantOption option, int valueId) onToggleValue;
  final void Function(VariantOption option, String initialName) onCreateValue;
  final void Function(VariantOption option) onSelectAllValues;
  final ValueChanged<String> onDefaultChanged;
  final void Function(String signature, bool value) onVariantActiveChanged;
  final FormFieldValidator<String> numberValidator;
  final String? generationErrorText;
  final Map<String, Map<CatalogIdentityField, CatalogIdentityConflict>>
  conflictsBySignature;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TutorTarget(
          anchor: TutorAnchor.productSkuPrefixField,
          child: TextFormField(
            controller: skuController,
            textInputAction: TextInputAction.next,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: l10n.skuPrefixLabel,
              hintText: l10n.skuPrefixHint,
              prefixIcon: const Icon(Icons.qr_code_2),
              helperText: l10n.skuOptionalHelper,
            ),
          ),
        ),
        const SizedBox(height: 12),
        TutorTarget(
          anchor: TutorAnchor.productGeneratedPriceField,
          child: TextFormField(
            controller: priceController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: l10n.generatedVariantPriceLabel,
              prefixIcon: const Icon(Icons.sell_outlined),
            ),
            inputFormatters: [DecimalTextInputFormatter()],
            validator: numberValidator,
          ),
        ),
        const SizedBox(height: 12),
        VariantOptionValuesField(
          options: selectedOptions,
          selectedValueIdsByOption: selectedValueIdsByOption,
          errorOptionIds: errorOptionIds,
          onToggleValue: onToggleValue,
          onCreateValue: onCreateValue,
          onSelectAllValues: onSelectAllValues,
        ),
        if (generationErrorText != null) ...[
          const SizedBox(height: 8),
          Text(
            generationErrorText!,
            style: TextStyle(color: context.pointyColors.danger),
          ),
        ],
        const SizedBox(height: 12),
        GeneratedVariantsPreview(
          combinations: combinations,
          nameControllers: nameControllers,
          skuControllers: skuControllers,
          barcodeControllers: barcodeControllers,
          priceControllers: priceControllers,
          activeBySignature: activeBySignature,
          defaultSignature: defaultSignature,
          onDefaultChanged: onDefaultChanged,
          onActiveChanged: onVariantActiveChanged,
          numberValidator: numberValidator,
          conflictsBySignature: conflictsBySignature,
          openingQuantityControllers: openingQuantityControllers,
          openingCostControllers: openingCostControllers,
        ),
      ],
    );
  }
}
