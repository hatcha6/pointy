import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/decimal_text_input_formatter.dart';

class ProductFormFields extends StatelessWidget {
  const ProductFormFields({
    super.key,
    required this.nameController,
    required this.skuController,
    required this.barcodeController,
    required this.descriptionController,
    required this.priceController,
    required this.isActive,
    required this.onActiveChanged,
    required this.requiredValidator,
    required this.numberValidator,
  });

  final TextEditingController nameController;
  final TextEditingController skuController;
  final TextEditingController barcodeController;
  final TextEditingController descriptionController;
  final TextEditingController priceController;
  final bool isActive;
  final ValueChanged<bool> onActiveChanged;
  final FormFieldValidator<String> requiredValidator;
  final FormFieldValidator<String> numberValidator;

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
