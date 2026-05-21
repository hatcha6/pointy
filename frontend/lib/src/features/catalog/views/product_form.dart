import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_draft.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/variant_option_value_picker.dart';
import '../view_models/catalog_view_model.dart';
import 'product_form_fields.dart';

class ProductForm extends StatefulWidget {
  const ProductForm({super.key, required this.viewModel, this.onCreated});

  final CatalogViewModel viewModel;
  final VoidCallback? onCreated;

  @override
  State<ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<ProductForm> {
  final _parentFormKey = GlobalKey<FormState>();
  final _variantFormKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _variantNameController = TextEditingController();
  final _skuController = TextEditingController();
  final _barcodeController = TextEditingController();
  final _priceController = TextEditingController();
  List<AsyncSelectionOption<int>> _selectedCategories = [];
  List<AsyncSelectionOption<int>> _selectedOptionValues = [];
  var _isProductActive = true;
  var _isVariantActive = true;
  var _isDefaultVariant = true;
  var _step = 0;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
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
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.newProductTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Text(l10n.productWizardStepLabel(_step + 1, 2)),
                  ],
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(value: _step == 0 ? 0.5 : 1),
                const SizedBox(height: 18),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _step == 0
                      ? Form(
                          key: _parentFormKey,
                          child: Column(
                            key: const ValueKey('product_parent_step'),
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _StepHeader(
                                icon: Icons.inventory_2_outlined,
                                title: l10n.parentProductStepTitle,
                              ),
                              const SizedBox(height: 12),
                              ProductParentFormFields(
                                nameController: _nameController,
                                descriptionController: _descriptionController,
                                selectedCategories: _selectedCategories,
                                isActive: _isProductActive,
                                onPickCategories: _pickCategories,
                                onClearCategories: () =>
                                    setState(() => _selectedCategories = []),
                                onActiveChanged: (value) =>
                                    setState(() => _isProductActive = value),
                                requiredValidator: (value) =>
                                    _requiredValidator(context, value),
                              ),
                            ],
                          ),
                        )
                      : Form(
                          key: _variantFormKey,
                          child: Column(
                            key: const ValueKey('product_variant_step'),
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _StepHeader(
                                icon: Icons.qr_code_2,
                                title: l10n.defaultVariantStepTitle,
                              ),
                              const SizedBox(height: 12),
                              ProductVariantFormFields(
                                variantNameController: _variantNameController,
                                skuController: _skuController,
                                barcodeController: _barcodeController,
                                priceController: _priceController,
                                selectedOptionValues: _selectedOptionValues,
                                isActive: _isVariantActive,
                                isDefault: _isDefaultVariant,
                                onPickOptionValues: _pickOptionValues,
                                onClearOptionValues: () =>
                                    setState(() => _selectedOptionValues = []),
                                onActiveChanged: (value) =>
                                    setState(() => _isVariantActive = value),
                                onDefaultChanged: (value) =>
                                    setState(() => _isDefaultVariant = value),
                                requiredValidator: (value) =>
                                    _requiredValidator(context, value),
                                numberValidator: (value) =>
                                    _numberValidator(context, value),
                                showDefaultToggle: false,
                              ),
                            ],
                          ),
                        ),
                ),
                if (widget.viewModel.errorMessage ==
                    'catalog_create_error') ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.productCreateError,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (_step > 0)
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: widget.viewModel.isSaving
                              ? null
                              : () => setState(() => _step = 0),
                          icon: const Icon(Icons.arrow_back),
                          label: Text(l10n.backButton),
                        ),
                      ),
                    if (_step > 0) const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: widget.viewModel.isSaving
                            ? null
                            : _step == 0
                            ? _continueToVariant
                            : _submit,
                        icon: widget.viewModel.isSaving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                _step == 0 ? Icons.arrow_forward : Icons.add,
                              ),
                        label: Text(
                          widget.viewModel.isSaving
                              ? l10n.creatingProductButton
                              : _step == 0
                              ? l10n.nextButton
                              : l10n.createProductButton,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _continueToVariant() {
    final isValid = _parentFormKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }
    if (_variantNameController.text.trim().isEmpty) {
      _variantNameController.text = '';
    }
    setState(() => _step = 1);
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
    final isValid = _variantFormKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }

    final draft = ProductDraft(
      name: _nameController.text.trim(),
      description: _descriptionController.text.trim(),
      isActive: _isProductActive,
      variantName: _variantNameController.text.trim(),
      variantSku: _skuController.text.trim(),
      variantBarcode: _barcodeController.text.trim(),
      variantUnitPrice: _parseNumber(_priceController.text)!,
      optionValueIds: [
        for (final optionValue in _selectedOptionValues) optionValue.id,
      ],
      categoryIds: [for (final category in _selectedCategories) category.id],
    );

    final created = await widget.viewModel.createProduct(draft);
    if (!mounted) {
      return;
    }

    if (created) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.productCreatedMessage)));
      widget.onCreated?.call();
    }
  }

  Future<void> _pickCategories() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: productCategoryPickerStrings(l10n),
      selected: _selectedCategories,
      searchFieldKey: const ValueKey('product_form_category_search_field'),
      applyButtonKey: const ValueKey('product_form_category_apply_button'),
      optionKeyForId: (id) => ValueKey('product_form_category_option_$id'),
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

  Future<void> _pickOptionValues() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: variantOptionValuePickerStrings(l10n),
      selected: _selectedOptionValues,
      searchFieldKey: const ValueKey('variant_option_value_search_field'),
      applyButtonKey: const ValueKey('variant_option_value_apply_button'),
      optionKeyForId: (id) => ValueKey('variant_option_value_option_$id'),
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

class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
      ],
    );
  }
}
