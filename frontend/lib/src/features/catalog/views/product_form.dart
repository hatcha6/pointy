import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_draft.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/product_category_picker.dart';
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
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _skuController = TextEditingController();
  final _barcodeController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  List<AsyncSelectionOption<int>> _selectedCategories = [];
  bool _isActive = true;

  @override
  void dispose() {
    _nameController.dispose();
    _skuController.dispose();
    _barcodeController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ColoredBox(
      color: Colors.white,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.newProductTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              ProductFormFields(
                nameController: _nameController,
                skuController: _skuController,
                barcodeController: _barcodeController,
                descriptionController: _descriptionController,
                priceController: _priceController,
                selectedCategories: _selectedCategories,
                isActive: _isActive,
                onPickCategories: _pickCategories,
                onClearCategories: () =>
                    setState(() => _selectedCategories = []),
                onActiveChanged: (value) => setState(() => _isActive = value),
                requiredValidator: (value) =>
                    _requiredValidator(context, value),
                numberValidator: (value) => _numberValidator(context, value),
              ),
              if (widget.viewModel.errorMessage == 'catalog_create_error') ...[
                const SizedBox(height: 8),
                Text(
                  l10n.productCreateError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: widget.viewModel.isSaving ? null : _submit,
                icon: widget.viewModel.isSaving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(
                  widget.viewModel.isSaving
                      ? l10n.creatingProductButton
                      : l10n.createProductButton,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

    final draft = ProductDraft(
      name: _nameController.text.trim(),
      sku: _skuController.text.trim(),
      barcode: _barcodeController.text.trim(),
      description: _descriptionController.text.trim(),
      unitPrice: _parseNumber(_priceController.text)!,
      isActive: _isActive,
      categoryIds: [for (final category in _selectedCategories) category.id],
    );

    final created = await widget.viewModel.createProduct(draft);
    if (!mounted) {
      return;
    }

    if (created) {
      _formKey.currentState?.reset();
      _nameController.clear();
      _skuController.clear();
      _barcodeController.clear();
      _descriptionController.clear();
      _priceController.clear();
      setState(() {
        _isActive = true;
        _selectedCategories = [];
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.productCreatedMessage)));
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
}
