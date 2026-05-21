import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_update_draft.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/product_category_picker.dart';
import '../view_models/product_details_view_model.dart';
import 'product_form_fields.dart';

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
  late bool _isActive;

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
    _isActive = product.isActive;
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
}
