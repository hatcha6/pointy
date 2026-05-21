import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/product_update_draft.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/product_category_picker.dart';
import '../view_models/product_details_view_model.dart';
import 'product_form_fields.dart';
import 'variant_option_creation_dialogs.dart';
import 'variant_generation_fields.dart';

class ProductParentEditSheet extends StatefulWidget {
  const ProductParentEditSheet({
    super.key,
    required this.viewModel,
    this.onSaved,
  });

  final ProductDetailsViewModel viewModel;
  final VoidCallback? onSaved;

  @override
  State<ProductParentEditSheet> createState() => _ProductParentEditSheetState();
}

class _ProductParentEditSheetState extends State<ProductParentEditSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late List<AsyncSelectionOption<int>> _selectedCategories;
  List<VariantOption> _availableVariantOptions = [];
  late Set<int> _selectedVariantOptionIds;
  var _isLoadingVariantOptions = false;
  var _variantOptionsLoadFailed = false;
  late bool _isActive;

  List<VariantOption> get _selectedVariantOptions {
    return [
      for (final option in _availableVariantOptions)
        if (_selectedVariantOptionIds.contains(option.id)) option,
      for (final option in widget.viewModel.product.variantOptions)
        if (_selectedVariantOptionIds.contains(option.id) &&
            !_availableVariantOptions.any((item) => item.id == option.id))
          option,
    ];
  }

  @override
  void initState() {
    super.initState();
    final product = widget.viewModel.product;
    _nameController = TextEditingController(text: product.name);
    _descriptionController = TextEditingController(text: product.description);
    _selectedCategories = [
      for (final category in product.categories)
        productCategoryOption(category),
    ];
    _selectedVariantOptionIds = {
      for (final option in product.variantOptions) option.id,
    };
    _isActive = product.isActive;
    _loadVariantOptions();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
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
                        Icons.edit_outlined,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.editProductButton,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ProductParentFormFields(
                    nameController: _nameController,
                    descriptionController: _descriptionController,
                    selectedCategories: _selectedCategories,
                    isActive: _isActive,
                    onPickCategories: _pickCategories,
                    onClearCategories: () =>
                        setState(() => _selectedCategories = []),
                    onActiveChanged: (value) =>
                        setState(() => _isActive = value),
                    requiredValidator: (value) =>
                        _requiredValidator(context, value),
                  ),
                  const SizedBox(height: 12),
                  VariantOptionTemplateField(
                    availableOptions: _availableVariantOptions,
                    selectedOptions: _selectedVariantOptions,
                    isLoading: _isLoadingVariantOptions,
                    hasError: _variantOptionsLoadFailed,
                    onReload: _loadVariantOptions,
                    onToggleOption: _toggleVariantOption,
                    onCreateOption: _createVariantOption,
                  ),
                  if (widget.viewModel.errorMessage ==
                      'product_update_error') ...[
                    const SizedBox(height: 8),
                    Text(
                      l10n.productUpdateError,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: widget.viewModel.isSavingProduct
                        ? null
                        : _submit,
                    icon: widget.viewModel.isSavingProduct
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(
                      widget.viewModel.isSavingProduct
                          ? l10n.savingProductButton
                          : l10n.saveProductButton,
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

  String? _requiredValidator(BuildContext context, String? value) {
    if (value == null || value.trim().isEmpty) {
      return AppLocalizations.of(context)!.requiredField;
    }
    return null;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      return;
    }

    final updated = await widget.viewModel.updateProduct(
      ProductUpdateDraft(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        isActive: _isActive,
        categoryIds: [for (final category in _selectedCategories) category.id],
        variantOptionIds: [
          for (final optionId in _selectedVariantOptionIds) optionId,
        ],
      ),
    );
    if (!mounted) {
      return;
    }
    if (updated) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.productUpdatedMessage)));
      widget.onSaved?.call();
    }
  }

  Future<void> _pickCategories() async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showAsyncMultiSelectPicker<int>(
      context: context,
      strings: productCategoryPickerStrings(l10n),
      selected: _selectedCategories,
      searchFieldKey: const ValueKey('product_edit_category_search_field'),
      applyButtonKey: const ValueKey('product_edit_category_apply_button'),
      optionKeyForId: (id) => ValueKey('product_edit_category_option_$id'),
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

  Future<void> _loadVariantOptions() async {
    setState(() {
      _isLoadingVariantOptions = true;
      _variantOptionsLoadFailed = false;
    });

    final result = await widget.viewModel.catalogRepository
        .loadAllActiveVariantOptions();
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<List<VariantOption>>():
        setState(() {
          _availableVariantOptions = result.value;
          _isLoadingVariantOptions = false;
          _variantOptionsLoadFailed = false;
        });
      case Error<List<VariantOption>>():
        setState(() {
          _isLoadingVariantOptions = false;
          _variantOptionsLoadFailed = true;
        });
    }
  }

  void _toggleVariantOption(VariantOption option) {
    setState(() {
      if (!_selectedVariantOptionIds.remove(option.id)) {
        _selectedVariantOptionIds.add(option.id);
      }
    });
  }

  Future<void> _createVariantOption() async {
    final created = await showCreateVariantOptionDialog(
      context: context,
      catalogRepository: widget.viewModel.catalogRepository,
      existingOptions: _availableVariantOptions,
    );
    if (!mounted || created == null) {
      return;
    }
    setState(() {
      _availableVariantOptions = [..._availableVariantOptions, created]
        ..sort((a, b) {
          final order = a.displayOrder.compareTo(b.displayOrder);
          return order == 0 ? a.displayLabel.compareTo(b.displayLabel) : order;
        });
      _selectedVariantOptionIds.add(created.id);
    });
  }
}
