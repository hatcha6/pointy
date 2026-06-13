import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/modifier_group.dart';
import '../../../data/models/product_draft.dart';
import '../../../data/models/product_variant_draft.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/product_category_picker.dart';
import '../view_models/catalog_view_model.dart';
import '../view_models/variant_generation.dart';
import 'product_form_fields.dart';
import 'modifier_group_selector.dart';
import 'product_form_section.dart';
import 'product_image_picker.dart';
import 'variant_option_creation_dialogs.dart';
import 'variant_generation_fields.dart';

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
  final Map<String, TextEditingController> _generatedNameControllers = {};
  final Map<String, TextEditingController> _generatedSkuControllers = {};
  final Map<String, TextEditingController> _generatedBarcodeControllers = {};
  final Map<String, TextEditingController> _generatedPriceControllers = {};
  final Map<String, bool> _generatedActiveBySignature = {};
  List<AsyncSelectionOption<int>> _selectedCategories = [];
  List<VariantOption> _availableVariantOptions = [];
  final Set<int> _selectedVariantOptionIds = {};
  List<ModifierGroup> _availableModifierGroups = [];
  final Set<int> _selectedModifierGroupIds = {};
  var _isLoadingModifierGroups = false;
  var _modifierGroupsLoadFailed = false;
  final Map<int, Set<int>> _selectedValueIdsByOption = {};
  Set<int> _valueErrorOptionIds = {};
  ProductImageSelection? _selectedImage;
  var _isProductActive = true;
  var _tracksExpiry = false;
  var _unit = 'piece';
  var _isService = false;
  var _isPrepared = false;
  var _isVariantActive = true;
  var _isDefaultVariant = true;
  var _isLoadingVariantOptions = false;
  var _variantOptionsLoadFailed = false;
  var _step = 0;
  String? _generationErrorKey;
  var _lastSkuPrefix = '';
  var _lastBasePrice = '';

  List<VariantOption> get _selectedVariantOptions {
    return [
      for (final option in _availableVariantOptions)
        if (_selectedVariantOptionIds.contains(option.id)) option,
    ];
  }

  bool get _usesGeneratedVariants => _selectedVariantOptions.isNotEmpty;

  List<VariantCombination> get _generatedCombinations {
    return generateVariantCombinations(
      options: _selectedVariantOptions,
      selectedValueIdsByOption: _selectedValueIdsByOption,
    );
  }

  String? _defaultGeneratedSignature;

  @override
  void initState() {
    super.initState();
    _lastSkuPrefix = _skuController.text;
    _lastBasePrice = _priceController.text;
    _nameController.addListener(_refreshImageSearchSeed);
    _skuController.addListener(_syncGeneratedSkusFromPrefix);
    _priceController.addListener(_syncGeneratedPricesFromBase);
    _loadVariantOptions();
    _loadModifierGroups();
  }

  @override
  void dispose() {
    _nameController.removeListener(_refreshImageSearchSeed);
    _nameController.dispose();
    _descriptionController.dispose();
    _variantNameController.dispose();
    _skuController.removeListener(_syncGeneratedSkusFromPrefix);
    _skuController.dispose();
    _barcodeController.dispose();
    _priceController.removeListener(_syncGeneratedPricesFromBase);
    _priceController.dispose();
    for (final controller in _generatedNameControllers.values) {
      controller.dispose();
    }
    for (final controller in _generatedSkuControllers.values) {
      controller.dispose();
    }
    for (final controller in _generatedBarcodeControllers.values) {
      controller.dispose();
    }
    for (final controller in _generatedPriceControllers.values) {
      controller.dispose();
    }
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
          child: Column(
            children: [
              Expanded(
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
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    ProductFormSection(
                                      icon: Icons.inventory_2_outlined,
                                      title: l10n.parentProductStepTitle,
                                      children: [
                                        ProductParentFormFields(
                                          nameController: _nameController,
                                          descriptionController:
                                              _descriptionController,
                                          selectedCategories:
                                              _selectedCategories,
                                          isActive: _isProductActive,
                                          tracksExpiry: _tracksExpiry,
                                          onPickCategories: _pickCategories,
                                          onClearCategories: () => setState(
                                            () => _selectedCategories = [],
                                          ),
                                          onActiveChanged: (value) => setState(
                                            () => _isProductActive = value,
                                          ),
                                          onTracksExpiryChanged: (value) =>
                                              setState(
                                                () => _tracksExpiry = value,
                                              ),
                                          unit: _unit,
                                          isService: _isService,
                                          isPrepared: _isPrepared,
                                          onUnitChanged: (value) => setState(
                                            () => _unit = value,
                                          ),
                                          onIsServiceChanged: (value) =>
                                              setState(
                                                () => _isService = value,
                                              ),
                                          onIsPreparedChanged: (value) =>
                                              setState(
                                                () => _isPrepared = value,
                                              ),
                                          requiredValidator: (value) =>
                                              _requiredValidator(
                                                context,
                                                value,
                                              ),
                                        ),
                                        const SizedBox(height: 12),
                                        ProductImageField(
                                          catalogRepository: widget
                                              .viewModel
                                              .catalogRepository,
                                          initialSearchQuery: _nameController
                                              .text
                                              .trim(),
                                          selection: _selectedImage,
                                          onChanged: (selection) => setState(
                                            () => _selectedImage = selection,
                                          ),
                                          enabled: !widget.viewModel.isSaving,
                                        ),
                                        const SizedBox(height: 12),
                                        VariantOptionTemplateField(
                                          availableOptions:
                                              _availableVariantOptions,
                                          selectedOptions:
                                              _selectedVariantOptions,
                                          isLoading: _isLoadingVariantOptions,
                                          hasError: _variantOptionsLoadFailed,
                                          onReload: _loadVariantOptions,
                                          onToggleOption: _toggleVariantOption,
                                          onCreateOption: _createVariantOption,
                                        ),
                                        const SizedBox(height: 12),
                                        ModifierGroupSelector(
                                          available: _availableModifierGroups,
                                          selectedIds: _selectedModifierGroupIds,
                                          isLoading: _isLoadingModifierGroups,
                                          hasError: _modifierGroupsLoadFailed,
                                          onReload: _loadModifierGroups,
                                          onToggle: _toggleModifierGroup,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              )
                            : Form(
                                key: _variantFormKey,
                                child: Column(
                                  key: const ValueKey('product_variant_step'),
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    ProductFormSection(
                                      icon: Icons.qr_code_2,
                                      title: l10n.defaultVariantStepTitle,
                                      children: [
                                        if (_usesGeneratedVariants)
                                          _GeneratedVariantFormStep(
                                            skuController: _skuController,
                                            priceController: _priceController,
                                            selectedOptions:
                                                _selectedVariantOptions,
                                            selectedValueIdsByOption:
                                                _selectedValueIdsByOption,
                                            errorOptionIds:
                                                _valueErrorOptionIds,
                                            combinations:
                                                _generatedCombinations,
                                            nameControllers:
                                                _generatedNameControllers,
                                            skuControllers:
                                                _generatedSkuControllers,
                                            barcodeControllers:
                                                _generatedBarcodeControllers,
                                            priceControllers:
                                                _generatedPriceControllers,
                                            activeBySignature:
                                                _generatedActiveBySignature,
                                            defaultSignature:
                                                _defaultGeneratedSignature,
                                            onToggleValue: _toggleOptionValue,
                                            onCreateValue:
                                                _createVariantOptionValue,
                                            onDefaultChanged: (signature) =>
                                                setState(
                                                  () =>
                                                      _defaultGeneratedSignature =
                                                          signature,
                                                ),
                                            onVariantActiveChanged:
                                                (signature, value) => setState(
                                                  () =>
                                                      _generatedActiveBySignature[signature] =
                                                          value,
                                                ),
                                            requiredValidator: (value) =>
                                                _requiredValidator(
                                                  context,
                                                  value,
                                                ),
                                            numberValidator: (value) =>
                                                _numberValidator(
                                                  context,
                                                  value,
                                                ),
                                            generationErrorText:
                                                _generationErrorText(context),
                                          )
                                        else
                                          ProductVariantFormFields(
                                            variantNameController:
                                                _variantNameController,
                                            skuController: _skuController,
                                            barcodeController:
                                                _barcodeController,
                                            priceController: _priceController,
                                            selectedOptionValues: const [],
                                            isActive: _isVariantActive,
                                            isDefault: _isDefaultVariant,
                                            onPickOptionValues: () {},
                                            onClearOptionValues: null,
                                            onActiveChanged: (value) =>
                                                setState(
                                                  () =>
                                                      _isVariantActive = value,
                                                ),
                                            onDefaultChanged: (value) =>
                                                setState(
                                                  () =>
                                                      _isDefaultVariant = value,
                                                ),
                                            requiredValidator: (value) =>
                                                _requiredValidator(
                                                  context,
                                                  value,
                                                ),
                                            numberValidator: (value) =>
                                                _numberValidator(
                                                  context,
                                                  value,
                                                ),
                                            showDefaultToggle: false,
                                            showOptionValues: false,
                                          ),
                                      ],
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
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
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
              ),
            ],
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

    _syncGeneratedVariantControllers();
    if (_usesGeneratedVariants && !_validateGeneratedVariants()) {
      return;
    }

    final unitPrice = _parseNumber(_priceController.text)!;
    final generatedVariants = _usesGeneratedVariants
        ? [
            for (final combination in _generatedCombinations)
              ProductVariantDraft(
                productId: 0,
                name: _generatedNameControllers[combination.signature]!.text
                    .trim(),
                sku: _generatedSkuControllers[combination.signature]!.text
                    .trim(),
                barcode: _generatedBarcodeControllers[combination.signature]!
                    .text
                    .trim(),
                unitPrice: _parseNumber(
                  _generatedPriceControllers[combination.signature]!.text,
                )!,
                isActive:
                    _generatedActiveBySignature[combination.signature] ?? true,
                isDefault: combination.signature == _defaultGeneratedSignature,
                optionValueIds: combination.valueIds,
              ),
          ]
        : const <ProductVariantDraft>[];

    final draft = ProductDraft(
      name: _nameController.text.trim(),
      description: _descriptionController.text.trim(),
      isActive: _isProductActive,
      tracksExpiry: _tracksExpiry,
      unit: _unit,
      isService: _isService,
      isPrepared: _isPrepared,
      variantName: _variantNameController.text.trim(),
      variantSku: _skuController.text.trim(),
      variantBarcode: _barcodeController.text.trim(),
      variantUnitPrice: unitPrice,
      variantOptionIds: [
        for (final option in _selectedVariantOptions) option.id,
      ],
      modifierGroupIds: _selectedModifierGroupIds.toList(),
      categoryIds: [for (final category in _selectedCategories) category.id],
      variants: generatedVariants,
    );

    final imageSelection = _selectedImage;
    final outcome = await widget.viewModel.createProduct(
      draft,
      imageUpload: imageSelection?.upload,
      imageImportToken: imageSelection?.importToken,
    );
    if (!mounted) {
      return;
    }

    if (outcome != ProductCreateOutcome.failed) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              outcome == ProductCreateOutcome.createdWithImageError
                  ? l10n.productCreatedImageAttachError
                  : l10n.productCreatedMessage,
            ),
          ),
        );
      widget.onCreated?.call();
    }
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

  Future<void> _loadModifierGroups() async {
    setState(() {
      _isLoadingModifierGroups = true;
      _modifierGroupsLoadFailed = false;
    });

    final result = await widget.viewModel.catalogRepository
        .loadAllModifierGroups();
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<List<ModifierGroup>>():
        setState(() {
          _availableModifierGroups = result.value;
          _isLoadingModifierGroups = false;
        });
      case Error<List<ModifierGroup>>():
        setState(() {
          _isLoadingModifierGroups = false;
          _modifierGroupsLoadFailed = true;
        });
    }
  }

  void _toggleModifierGroup(ModifierGroup group) {
    setState(() {
      if (!_selectedModifierGroupIds.remove(group.id)) {
        _selectedModifierGroupIds.add(group.id);
      }
    });
  }

  void _toggleVariantOption(VariantOption option) {
    setState(() {
      if (_selectedVariantOptionIds.remove(option.id)) {
        _selectedValueIdsByOption.remove(option.id);
        _valueErrorOptionIds = {..._valueErrorOptionIds}..remove(option.id);
      } else {
        _selectedVariantOptionIds.add(option.id);
        _selectedValueIdsByOption[option.id] = {
          for (final value in option.values)
            if (value.isActive) value.id,
        };
      }
      _generationErrorKey = null;
      _syncGeneratedVariantControllers();
    });
  }

  void _toggleOptionValue(VariantOption option, int valueId) {
    setState(() {
      final selected = {
        ...(_selectedValueIdsByOption[option.id] ?? const <int>{}),
      };
      if (!selected.remove(valueId)) {
        selected.add(valueId);
      }
      _selectedValueIdsByOption[option.id] = selected;
      _valueErrorOptionIds = {..._valueErrorOptionIds}..remove(option.id);
      _generationErrorKey = null;
      _syncGeneratedVariantControllers();
    });
  }

  void _syncGeneratedVariantControllers() {
    final combinations = _generatedCombinations;
    final signatures = {
      for (final combination in combinations) combination.signature,
    };

    for (final entry in [..._generatedNameControllers.entries]) {
      if (!signatures.contains(entry.key)) {
        entry.value.dispose();
        _generatedNameControllers.remove(entry.key);
      }
    }
    for (final entry in [..._generatedSkuControllers.entries]) {
      if (!signatures.contains(entry.key)) {
        entry.value.dispose();
        _generatedSkuControllers.remove(entry.key);
      }
    }
    for (final entry in [..._generatedBarcodeControllers.entries]) {
      if (!signatures.contains(entry.key)) {
        entry.value.dispose();
        _generatedBarcodeControllers.remove(entry.key);
      }
    }
    for (final entry in [..._generatedPriceControllers.entries]) {
      if (!signatures.contains(entry.key)) {
        entry.value.dispose();
        _generatedPriceControllers.remove(entry.key);
      }
    }
    _generatedActiveBySignature.removeWhere(
      (signature, _) => !signatures.contains(signature),
    );

    for (final combination in combinations) {
      _generatedNameControllers.putIfAbsent(
        combination.signature,
        () => TextEditingController(text: combination.autoName),
      );
      _generatedSkuControllers.putIfAbsent(
        combination.signature,
        () => TextEditingController(
          text: combination.skuFromBase(_skuController.text),
        ),
      );
      _generatedBarcodeControllers.putIfAbsent(
        combination.signature,
        () => TextEditingController(),
      );
      _generatedPriceControllers.putIfAbsent(
        combination.signature,
        () => TextEditingController(text: _priceController.text),
      );
      _generatedActiveBySignature.putIfAbsent(
        combination.signature,
        () => _isVariantActive,
      );
    }

    if (combinations.isEmpty) {
      _defaultGeneratedSignature = null;
    } else if (!signatures.contains(_defaultGeneratedSignature)) {
      _defaultGeneratedSignature = combinations.first.signature;
    }
  }

  void _syncGeneratedSkusFromPrefix() {
    final nextPrefix = _skuController.text;
    final previousPrefix = _lastSkuPrefix;
    if (nextPrefix == previousPrefix) {
      return;
    }
    for (final combination in _generatedCombinations) {
      final controller = _generatedSkuControllers[combination.signature];
      if (controller == null) {
        continue;
      }
      final previousAutoSku = combination.skuFromBase(previousPrefix);
      if (controller.text.trim().isEmpty ||
          controller.text == previousAutoSku) {
        controller.text = combination.skuFromBase(nextPrefix);
      }
    }
    _lastSkuPrefix = nextPrefix;
  }

  void _syncGeneratedPricesFromBase() {
    final nextPrice = _priceController.text;
    final previousPrice = _lastBasePrice;
    if (nextPrice == previousPrice) {
      return;
    }
    for (final combination in _generatedCombinations) {
      final controller = _generatedPriceControllers[combination.signature];
      if (controller == null) {
        continue;
      }
      if (controller.text.trim().isEmpty || controller.text == previousPrice) {
        controller.text = nextPrice;
      }
    }
    _lastBasePrice = nextPrice;
  }

  bool _validateGeneratedVariants() {
    final missingOptionIds = {
      for (final option in _selectedVariantOptions)
        if ((_selectedValueIdsByOption[option.id] ?? const {}).isEmpty)
          option.id,
    };
    if (missingOptionIds.isNotEmpty) {
      setState(() {
        _valueErrorOptionIds = missingOptionIds;
        _generationErrorKey = 'missing_values';
      });
      return false;
    }

    final combinations = _generatedCombinations;
    if (combinations.isEmpty) {
      setState(() => _generationErrorKey = 'missing_values');
      return false;
    }
    if (combinations.length > 200) {
      setState(() => _generationErrorKey = 'too_many');
      return false;
    }

    final skus = <String>{};
    for (final combination in combinations) {
      final sku = _generatedSkuControllers[combination.signature]!.text
          .trim()
          .toUpperCase();
      if (sku.isEmpty) {
        continue;
      }
      if (!skus.add(sku)) {
        setState(() => _generationErrorKey = 'duplicate_sku');
        return false;
      }
    }

    setState(() {
      _generationErrorKey = null;
      _valueErrorOptionIds = {};
    });
    return true;
  }

  String? _generationErrorText(BuildContext context) {
    final key = _generationErrorKey;
    if (key == null) {
      return null;
    }
    final l10n = AppLocalizations.of(context)!;
    return switch (key) {
      'duplicate_sku' => l10n.generatedVariantsDuplicateSku,
      'too_many' => l10n.generatedVariantsTooMany,
      _ => l10n.generatedVariantsMissingValues,
    };
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
      _selectedValueIdsByOption[created.id] = const {};
      _generationErrorKey = null;
      _syncGeneratedVariantControllers();
    });
  }

  Future<void> _createVariantOptionValue(VariantOption option) async {
    final created = await showCreateVariantOptionValueDialog(
      context: context,
      catalogRepository: widget.viewModel.catalogRepository,
      option: option,
    );
    if (!mounted || created == null) {
      return;
    }
    setState(() {
      _replaceAvailableOption(
        option.copyWith(values: [...option.values, created]),
      );
      _selectedValueIdsByOption.update(
        option.id,
        (ids) => {...ids, created.id},
        ifAbsent: () => {created.id},
      );
      _valueErrorOptionIds = {..._valueErrorOptionIds}..remove(option.id);
      _generationErrorKey = null;
      _syncGeneratedVariantControllers();
    });
  }

  void _replaceAvailableOption(VariantOption option) {
    _availableVariantOptions = [
      for (final current in _availableVariantOptions)
        if (current.id == option.id) option else current,
    ];
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

class _GeneratedVariantFormStep extends StatelessWidget {
  const _GeneratedVariantFormStep({
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
    required this.onDefaultChanged,
    required this.onVariantActiveChanged,
    required this.requiredValidator,
    required this.numberValidator,
    required this.generationErrorText,
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
  final Map<String, bool> activeBySignature;
  final String? defaultSignature;
  final void Function(VariantOption option, int valueId) onToggleValue;
  final void Function(VariantOption option) onCreateValue;
  final ValueChanged<String> onDefaultChanged;
  final void Function(String signature, bool value) onVariantActiveChanged;
  final FormFieldValidator<String> requiredValidator;
  final FormFieldValidator<String> numberValidator;
  final String? generationErrorText;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: skuController,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: l10n.skuPrefixLabel,
            hintText: l10n.skuPrefixHint,
            prefixIcon: const Icon(Icons.qr_code_2),
          ),
          validator: requiredValidator,
        ),
        const SizedBox(height: 12),
        TextFormField(
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
        const SizedBox(height: 12),
        VariantOptionValuesField(
          options: selectedOptions,
          selectedValueIdsByOption: selectedValueIdsByOption,
          errorOptionIds: errorOptionIds,
          onToggleValue: onToggleValue,
          onCreateValue: onCreateValue,
        ),
        if (generationErrorText != null) ...[
          const SizedBox(height: 8),
          Text(
            generationErrorText!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
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
          requiredValidator: requiredValidator,
          numberValidator: numberValidator,
        ),
      ],
    );
  }
}
