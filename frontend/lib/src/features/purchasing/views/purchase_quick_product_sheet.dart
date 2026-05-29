import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_draft.dart';
import '../../../data/models/product_variant.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/responsive/responsive.dart';
import '../view_models/purchase_view_model.dart';

Future<ProductVariant?> resolveOrCreatePurchaseVariant(
  BuildContext context, {
  required PurchaseViewModel viewModel,
  required String barcode,
}) async {
  final variant = await viewModel.findVariantByBarcode(barcode);
  if (variant != null) {
    return variant;
  }
  if (!context.mounted) {
    return null;
  }
  return showPurchaseQuickProductSheet(
    context,
    barcode: barcode,
    viewModel: viewModel,
  );
}

Future<ProductVariant?> showPurchaseQuickProductSheet(
  BuildContext context, {
  required String barcode,
  required PurchaseViewModel viewModel,
}) {
  return showAdaptiveModalBottomSheet<ProductVariant?>(
    context: context,
    builder: (context) {
      return PurchaseQuickProductSheet(
        barcode: barcode,
        viewModel: viewModel,
        onCreate: (draft, unitCost) async {
          final variant = await viewModel.createQuickProduct(draft);
          if (variant != null) {
            viewModel.rememberVariantCost(variant, unitCost);
          }
          return variant;
        },
      );
    },
  );
}

class PurchaseQuickProductSheet extends StatefulWidget {
  const PurchaseQuickProductSheet({
    super.key,
    required this.barcode,
    required this.viewModel,
    required this.onCreate,
  });

  final String barcode;
  final PurchaseViewModel viewModel;
  final Future<ProductVariant?> Function(ProductDraft draft, double unitCost)
  onCreate;

  @override
  State<PurchaseQuickProductSheet> createState() =>
      _PurchaseQuickProductSheetState();
}

class _PurchaseQuickProductSheetState extends State<PurchaseQuickProductSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _barcodeController = TextEditingController(
    text: widget.barcode,
  );
  late final TextEditingController _skuController = TextEditingController(
    text: widget.barcode,
  );
  final _nameController = TextEditingController();
  final _priceController = TextEditingController();
  List<AsyncSelectionOption<int>> _selectedCategories = [];
  bool _isSaving = false;
  bool _hasError = false;

  @override
  void dispose() {
    _barcodeController.dispose();
    _skuController.dispose();
    _nameController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Form(
        key: _formKey,
        child: ListView(
          shrinkWrap: true,
          children: [
            Row(
              children: [
                const Icon(Icons.add_business_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.quickCreateProductTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(l10n.quickCreateProductMessage(widget.barcode)),
            const SizedBox(height: 16),
            TextFormField(
              controller: _barcodeController,
              enabled: false,
              decoration: InputDecoration(
                labelText: l10n.barcodeLabel,
                prefixIcon: const Icon(Icons.document_scanner_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameController,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.productNameLabel,
                hintText: l10n.quickCreateProductNameHint,
                prefixIcon: const Icon(Icons.inventory_2_outlined),
              ),
              validator: _requiredValidator,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _skuController,
              textInputAction: TextInputAction.next,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: l10n.skuLabel,
                prefixIcon: const Icon(Icons.qr_code_2),
              ),
              validator: _requiredValidator,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _priceController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              inputFormatters: [DecimalTextInputFormatter()],
              decoration: InputDecoration(
                labelText: l10n.quickCreateUnitCostLabel,
                prefixIcon: const Icon(Icons.payments_outlined),
              ),
              validator: _numberValidator,
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            AsyncSelectionField<int>(
              fieldKey: const ValueKey(
                'purchase_quick_product_categories_field',
              ),
              strings: productCategoryFieldStrings(l10n),
              selected: _selectedCategories,
              onPick: _pickCategories,
              onClear: _selectedCategories.isEmpty
                  ? null
                  : () => setState(() => _selectedCategories = []),
              validator: (_) => null,
            ),
            if (_hasError) ...[
              const SizedBox(height: 8),
              Text(
                l10n.productCreateError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isSaving
                        ? null
                        : () =>
                              Navigator.of(context).pop<ProductVariant?>(null),
                    child: Text(l10n.cancelButton),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isSaving ? null : _submit,
                    icon: _isSaving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add),
                    label: Text(
                      _isSaving
                          ? l10n.quickCreateProductSaving
                          : l10n.quickCreateProductButton,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String? _requiredValidator(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.of(context)!.requiredField;
    }
    return null;
  }

  String? _numberValidator(String? value) {
    final parsed = _parseNumber(value);
    if (parsed == null || parsed < 0) {
      return AppLocalizations.of(context)!.invalidNumber;
    }
    return null;
  }

  double? _parseNumber(String? value) {
    if (value == null) {
      return null;
    }
    return double.tryParse(value.trim().replaceAll(',', '.'));
  }

  Future<void> _submit() async {
    if (_isSaving || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() {
      _isSaving = true;
      _hasError = false;
    });

    final unitCost = _parseNumber(_priceController.text)!;
    final created = await widget.onCreate(
      ProductDraft(
        variantSku: _skuController.text.trim(),
        variantBarcode: widget.barcode,
        name: _nameController.text.trim(),
        variantUnitPrice: 0,
        isActive: true,
        categoryIds: [for (final category in _selectedCategories) category.id],
      ),
      unitCost,
    );

    if (!mounted) {
      return;
    }

    if (created == null) {
      setState(() {
        _isSaving = false;
        _hasError = true;
      });
      return;
    }

    Navigator.of(context).pop(created);
  }

  Future<void> _pickCategories() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: productCategoryPickerStrings(l10n),
      selected: _selectedCategories,
      searchFieldKey: const ValueKey('purchase_quick_category_search_field'),
      applyButtonKey: const ValueKey('purchase_quick_category_apply_button'),
      optionKeyForId: (id) => ValueKey('purchase_quick_category_option_$id'),
      loadPage: (search, page) => loadProductCategorySelectionPage(
        catalogRepository: widget.viewModel.catalogRepository,
        search: search,
        page: page,
      ),
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedCategories = picked);
  }
}
