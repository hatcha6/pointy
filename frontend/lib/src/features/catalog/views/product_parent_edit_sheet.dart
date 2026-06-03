import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/product_update_draft.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/product_category_picker.dart';
import '../view_models/product_details_view_model.dart';
import 'product_form_fields.dart';
import 'product_form_section.dart';
import 'product_image_picker.dart';
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
  ProductImageSelection? _selectedImage;
  var _isLoadingVariantOptions = false;
  var _variantOptionsLoadFailed = false;
  late bool _isActive;
  late bool _tracksExpiry;

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
    _tracksExpiry = product.tracksExpiry;
    _nameController.addListener(_refreshImageSearchSeed);
    _loadVariantOptions();
  }

  @override
  void dispose() {
    _nameController.removeListener(_refreshImageSearchSeed);
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _refreshImageSearchSeed() {
    if (_selectedImage == null && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        return Material(
          color: Theme.of(context).colorScheme.surface,
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ProductFormSection(
                          icon: Icons.edit_outlined,
                          title: l10n.editProductButton,
                          children: [
                            ProductParentFormFields(
                              nameController: _nameController,
                              descriptionController: _descriptionController,
                              selectedCategories: _selectedCategories,
                              isActive: _isActive,
                              tracksExpiry: _tracksExpiry,
                              onPickCategories: _pickCategories,
                              onClearCategories: () =>
                                  setState(() => _selectedCategories = []),
                              onActiveChanged: (value) =>
                                  setState(() => _isActive = value),
                              onTracksExpiryChanged: (value) =>
                                  setState(() => _tracksExpiry = value),
                              requiredValidator: (value) =>
                                  _requiredValidator(context, value),
                            ),
                            const SizedBox(height: 12),
                            ProductImageField(
                              catalogRepository:
                                  widget.viewModel.catalogRepository,
                              initialSearchQuery: _nameController.text.trim(),
                              currentImage:
                                  widget.viewModel.product.primaryImage,
                              selection: _selectedImage,
                              onChanged: (selection) =>
                                  setState(() => _selectedImage = selection),
                              enabled:
                                  !widget.viewModel.isSavingProduct &&
                                  !widget.viewModel.isSavingImage,
                              isSaving: widget.viewModel.isSavingImage,
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
                          ],
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
                        if (widget.viewModel.errorMessage ==
                            'product_image_attach_error') ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.productImageAttachError,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          widget.viewModel.isSavingProduct ||
                              widget.viewModel.isSavingImage
                          ? null
                          : _submit,
                      icon:
                          widget.viewModel.isSavingProduct ||
                              widget.viewModel.isSavingImage
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: Text(
                        widget.viewModel.isSavingProduct ||
                                widget.viewModel.isSavingImage
                            ? l10n.savingButton
                            : l10n.saveProductButton,
                      ),
                    ),
                  ),
                ),
              ],
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
        tracksExpiry: _tracksExpiry,
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
      final imageSaved = await _saveSelectedImage();
      if (!mounted) {
        return;
      }
      if (!imageSaved) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(l10n.productImageAttachError)));
        return;
      }
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.productUpdatedMessage)));
      widget.onSaved?.call();
    }
  }

  Future<bool> _saveSelectedImage() async {
    final selected = _selectedImage;
    if (selected == null) {
      return true;
    }
    final upload = selected.upload;
    if (upload != null) {
      return widget.viewModel.uploadProductImage(upload);
    }
    final token = selected.importToken;
    if (token != null && token.isNotEmpty) {
      return widget.viewModel.importProductImage(token);
    }
    return true;
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
