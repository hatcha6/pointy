import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_draft.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/variant_option_value_picker.dart';
import '../view_models/product_details_view_model.dart';
import 'product_form_fields.dart';

class ProductVariantFormSheet extends StatefulWidget {
  const ProductVariantFormSheet({
    super.key,
    required this.viewModel,
    this.variant,
    this.onSaved,
  });

  final ProductDetailsViewModel viewModel;
  final ProductVariant? variant;
  final VoidCallback? onSaved;

  @override
  State<ProductVariantFormSheet> createState() =>
      _ProductVariantFormSheetState();
}

class _ProductVariantFormSheetState extends State<ProductVariantFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _variantNameController;
  late final TextEditingController _skuController;
  late final TextEditingController _barcodeController;
  late final TextEditingController _priceController;
  late List<AsyncSelectionOption<int>> _selectedOptionValues;
  late bool _isActive;
  late bool _isDefault;

  bool get _isEditing => widget.variant != null;

  @override
  void initState() {
    super.initState();
    final variant = widget.variant;
    _variantNameController = TextEditingController(text: variant?.name ?? '');
    _skuController = TextEditingController(text: variant?.sku ?? '');
    _barcodeController = TextEditingController(text: variant?.barcode ?? '');
    _priceController = TextEditingController(
      text: variant == null ? '' : variant.unitPrice.toStringAsFixed(2),
    );
    _selectedOptionValues = _initialOptionValues(variant);
    _isActive = variant?.isActive ?? true;
    _isDefault = variant?.isDefault ?? false;
  }

  @override
  void dispose() {
    _variantNameController.dispose();
    _skuController.dispose();
    _barcodeController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        return Material(
          color: Theme.of(context).colorScheme.surface,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isEditing ? Icons.edit_outlined : Icons.add,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _isEditing
                              ? l10n.editVariantTitle
                              : l10n.newVariantTitle,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ProductVariantFormFields(
                    variantNameController: _variantNameController,
                    skuController: _skuController,
                    barcodeController: _barcodeController,
                    priceController: _priceController,
                    selectedOptionValues: _selectedOptionValues,
                    isActive: _isActive,
                    isDefault: _isDefault,
                    onPickOptionValues: _pickOptionValues,
                    onClearOptionValues: () =>
                        setState(() => _selectedOptionValues = []),
                    onActiveChanged: (value) =>
                        setState(() => _isActive = value),
                    onDefaultChanged: (value) =>
                        setState(() => _isDefault = value),
                    requiredValidator: (value) =>
                        _requiredValidator(context, value),
                    numberValidator: (value) =>
                        _numberValidator(context, value),
                  ),
                  if (_saveErrorKey != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _saveErrorKey == 'variant_update_error'
                          ? l10n.variantUpdateError
                          : l10n.variantCreateError,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: widget.viewModel.isSavingVariant
                        ? null
                        : _submit,
                    icon: widget.viewModel.isSavingVariant
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(_isEditing ? Icons.save_outlined : Icons.add),
                    label: Text(
                      widget.viewModel.isSavingVariant
                          ? l10n.savingVariantButton
                          : _isEditing
                          ? l10n.saveVariantButton
                          : l10n.createVariantButton,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String? get _saveErrorKey {
    final message = widget.viewModel.errorMessage;
    if (message == 'variant_create_error' ||
        message == 'variant_update_error') {
      return message;
    }
    return null;
  }

  List<AsyncSelectionOption<int>> _initialOptionValues(
    ProductVariant? variant,
  ) {
    if (variant == null) {
      return [];
    }
    if (variant.optionValues.isNotEmpty) {
      return [
        for (final optionValue in variant.optionValues)
          variantOptionValueOption(optionValue),
      ];
    }
    return [
      for (final id in variant.optionValueIds)
        AsyncSelectionOption<int>(id: id, label: '', subtitle: ''),
    ];
  }

  String? _requiredValidator(BuildContext context, String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.of(context)!.requiredField;
    }
    return null;
  }

  String? _numberValidator(BuildContext context, String? value) {
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
    final l10n = AppLocalizations.of(context)!;
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }

    final draft = ProductVariantDraft(
      productId: widget.viewModel.product.id,
      name: _variantNameController.text.trim(),
      sku: _skuController.text.trim(),
      barcode: _barcodeController.text.trim(),
      unitPrice: _parseNumber(_priceController.text)!,
      isActive: _isActive,
      isDefault: _isDefault,
      optionValueIds: [
        for (final optionValue in _selectedOptionValues) optionValue.id,
      ],
    );

    final variant = widget.variant;
    final saved = variant == null
        ? await widget.viewModel.createVariant(draft)
        : await widget.viewModel.updateVariant(id: variant.id, draft: draft);
    if (!mounted) {
      return;
    }
    if (saved) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              variant == null
                  ? l10n.variantCreatedMessage
                  : l10n.variantUpdatedMessage,
            ),
          ),
        );
      widget.onSaved?.call();
    }
  }

  Future<void> _pickOptionValues() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: variantOptionValuePickerStrings(l10n),
      selected: _selectedOptionValues,
      searchFieldKey: const ValueKey('variant_form_option_value_search_field'),
      applyButtonKey: const ValueKey('variant_form_option_value_apply_button'),
      optionKeyForId: (id) => ValueKey('variant_form_option_value_$id'),
      loadPage: (search, page) => loadVariantOptionValueSelectionPage(
        catalogRepository: widget.viewModel.catalogRepository,
        search: search,
        page: page,
      ),
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() => _selectedOptionValues = picked);
  }
}
