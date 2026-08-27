import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../core/result.dart';
import '../../../data/models/catalog_identity_conflict.dart';
import '../../../data/models/modifier_group.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_draft.dart';
import '../../../data/models/product_unit.dart';
import '../../../data/models/product_variant_draft.dart';
import '../../../data/models/unit_of_measure.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/components/components.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../../../shared/product_category_picker.dart';
import '../view_models/catalog_view_model.dart';
import '../view_models/variant_generation.dart';
import 'product_form_fields.dart';
import 'modifier_group_selector.dart';
import 'product_form_section.dart';
import 'product_image_picker.dart';
import 'product_units_editor.dart';
import 'variant_option_creation_dialogs.dart';
import 'variant_generation_fields.dart';
import 'variant_identity_watcher.dart';

class ProductForm extends StatefulWidget {
  const ProductForm({
    super.key,
    required this.viewModel,
    this.onCreated,
    this.initialBarcode,
  });

  final CatalogViewModel viewModel;

  /// Called with the freshly created product once creation succeeds. The
  /// catalog closes its sheet; the purchasing workspace also adds the
  /// product's default variant to the current purchase order.
  final void Function(Product product)? onCreated;

  /// Prefills the default variant's barcode and SKU — used when the form is
  /// opened for a scanned code that matched no existing product, so the created
  /// product resolves on the next scan.
  final String? initialBarcode;

  @override
  State<ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<ProductForm> {
  final _parentFormKey = GlobalKey<FormState>();
  final _variantFormKey = GlobalKey<FormState>();
  final _skuFieldKey = GlobalKey();
  final _barcodeFieldKey = GlobalKey();
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
  List<UnitOfMeasure> _availableUnits = [];
  List<ProductUnit> _units = [];
  var _defaultSaleUnit = '';
  var _defaultPurchaseUnit = '';
  var _isLoadingUnits = false;
  var _unitsLoadFailed = false;
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
  late final VariantIdentityWatcher _identity;

  /// Per-generated-row identity errors, keyed by combination signature then
  /// field. Generated rows are not watched live (one product can generate
  /// dozens of them); they collect duplicates found in the form itself and
  /// whatever the server rejected.
  final Map<String, Map<CatalogIdentityField, CatalogIdentityConflict>>
  _generatedConflicts = {};

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
    final initialBarcode = widget.initialBarcode?.trim() ?? '';
    if (initialBarcode.isNotEmpty) {
      _barcodeController.text = initialBarcode;
      _skuController.text = initialBarcode;
    }
    _lastSkuPrefix = _skuController.text;
    _lastBasePrice = _priceController.text;
    _nameController.addListener(_refreshImageSearchSeed);
    _skuController.addListener(_syncGeneratedSkusFromPrefix);
    _priceController.addListener(_syncGeneratedPricesFromBase);
    // Watches the single default variant's codes. When the product generates
    // variants instead, these two inputs become a SKU *prefix* and a base
    // price, so the watcher is left idle — see _usesGeneratedVariants.
    _identity = VariantIdentityWatcher(
      catalogRepository: widget.viewModel.catalogRepository,
      skuController: _skuController,
      barcodeController: _barcodeController,
    );
    _loadVariantOptions();
    _loadModifierGroups();
    _loadUnits();
  }

  Future<void> _loadUnits() async {
    setState(() {
      _isLoadingUnits = true;
      _unitsLoadFailed = false;
    });
    final result = await widget.viewModel.catalogRepository.loadAllUnits();
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<List<UnitOfMeasure>>():
        setState(() {
          _availableUnits = result.value;
          _isLoadingUnits = false;
        });
      case Error<List<UnitOfMeasure>>():
        setState(() {
          _isLoadingUnits = false;
          _unitsLoadFailed = true;
        });
    }
  }

  @override
  void dispose() {
    _identity.dispose();
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

  /// Any entry the user would lose on an accidental dismiss. Used by the
  /// unsaved-changes guard (evaluated fresh on each back/dismiss attempt).
  bool get _isDirty =>
      _nameController.text.trim().isNotEmpty ||
      _descriptionController.text.trim().isNotEmpty ||
      _variantNameController.text.trim().isNotEmpty ||
      _skuController.text.trim().isNotEmpty ||
      _barcodeController.text.trim().isNotEmpty ||
      _priceController.text.trim().isNotEmpty ||
      _selectedImage != null ||
      _selectedCategories.isNotEmpty ||
      _selectedVariantOptionIds.isNotEmpty ||
      _selectedModifierGroupIds.isNotEmpty ||
      _units.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyUnsavedChangesGuard(
      isDirty: () => _isDirty,
      child: _buildForm(context, l10n),
    );
  }

  Widget _buildForm(BuildContext context, AppLocalizations l10n) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.viewModel, _identity]),
      builder: (context, _) {
        return Material(
          color: context.pointyColors.surface,
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
                      PointyProgressBar(value: _step == 0 ? 0.5 : 1),
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
                                          onUnitChanged: (value) =>
                                              setState(() => _unit = value),
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
                                        VariantOptionField(
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
                                          selectedIds:
                                              _selectedModifierGroupIds,
                                          isLoading: _isLoadingModifierGroups,
                                          hasError: _modifierGroupsLoadFailed,
                                          onReload: _loadModifierGroups,
                                          onToggle: _toggleModifierGroup,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    ProductFormSection(
                                      icon: Icons.straighten_outlined,
                                      title: l10n.productUnitsSectionTitle,
                                      children: [
                                        ProductUnitsEditor(
                                          availableUnits: _availableUnits,
                                          baseUnitCode: _unit,
                                          units: _units,
                                          defaultSaleUnit: _defaultSaleUnit,
                                          defaultPurchaseUnit:
                                              _defaultPurchaseUnit,
                                          enabled: !widget.viewModel.isSaving,
                                          isLoading: _isLoadingUnits,
                                          hasError: _unitsLoadFailed,
                                          onReload: _loadUnits,
                                          onUnitsChanged: (units) =>
                                              setState(() => _units = units),
                                          onDefaultSaleChanged: (code) =>
                                              setState(
                                                () => _defaultSaleUnit = code,
                                              ),
                                          onDefaultPurchaseChanged: (code) =>
                                              setState(
                                                () =>
                                                    _defaultPurchaseUnit = code,
                                              ),
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
                                            conflictsBySignature:
                                                _generatedConflicts,
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
                                            skuState: _identity.skuState,
                                            barcodeState:
                                                _identity.barcodeState,
                                            skuFieldKey: _skuFieldKey,
                                            barcodeFieldKey: _barcodeFieldKey,
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
                          // With a known field conflict the offending input is
                          // already marked — point at it instead of repeating a
                          // generic "could not create".
                          _hasFieldConflict
                              ? l10n.formFixHighlightedFieldsError
                              : l10n.productCreateError,
                          style: TextStyle(color: context.pointyColors.danger),
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
                                child: PointySpinner(strokeWidth: 2),
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
    return parseDecimal(value);
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    // Settle a code typed in the last few hundred milliseconds before the form
    // decides whether it is valid.
    await _identity.refresh();
    if (!mounted) {
      return;
    }
    final isValid = _variantFormKey.currentState?.validate() ?? false;
    if (!isValid) {
      _scrollToFirstConflict();
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
      defaultSaleUnit: _defaultSaleUnit,
      defaultPurchaseUnit: _defaultPurchaseUnit,
      units: _units,
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
    final result = await widget.viewModel.createProduct(
      draft,
      imageUpload: imageSelection?.upload,
      imageImportToken: imageSelection?.importToken,
    );
    if (!mounted) {
      return;
    }

    if (result.outcome == ProductCreateOutcome.failed) {
      // The server re-checks every write, so a clash it found — including one
      // that appeared between the live check and the save — lands on its field.
      _applyServerConflicts(widget.viewModel.saveConflicts);
      return;
    }

    final createdProduct = result.product;
    if (createdProduct != null) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              result.outcome == ProductCreateOutcome.createdWithImageError
                  ? l10n.productCreatedImageAttachError
                  : l10n.productCreatedMessage,
            ),
          ),
        );
      widget.onCreated?.call(createdProduct);
    }
  }

  /// Routes a rejected save's conflicts to the input that carries the value:
  /// the single default-variant fields, or the generated row named by the
  /// conflict's index.
  void _applyServerConflicts(List<CatalogIdentityConflict> conflicts) {
    final combinations = _generatedCombinations;
    final generated = <CatalogIdentityConflict>[];
    final single = <CatalogIdentityConflict>[];
    for (final conflict in conflicts) {
      if (conflict.target == CatalogIdentityTarget.variants) {
        generated.add(conflict);
      } else {
        single.add(conflict);
      }
    }

    setState(() {
      _generatedConflicts.clear();
      for (final conflict in generated) {
        final index = conflict.index;
        if (index == null || index < 0 || index >= combinations.length) {
          continue;
        }
        _generatedConflicts.putIfAbsent(
          combinations[index].signature,
          () => {},
        )[conflict.field] = conflict;
      }
    });
    _identity.applyConflicts(single);
    _scrollToFirstConflict();
  }

  /// Brings the first rejected identity field back into view — a long form can
  /// otherwise mark a field the user cannot see.
  void _scrollToFirstConflict() {
    final key = _identity.skuState.isTaken
        ? _skuFieldKey
        : _identity.barcodeState.isTaken
        ? _barcodeFieldKey
        : null;
    final target = key?.currentContext;
    if (target == null) {
      return;
    }
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 250),
      alignment: 0.2,
    );
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
      _syncIdentityWatcher();
    });
  }

  /// The SKU/barcode inputs only describe one real variant while the product
  /// has no options; once it generates variants they become a prefix and an
  /// unused field, so checking them would flag phantom duplicates.
  void _syncIdentityWatcher() {
    _identity.enabled = !_usesGeneratedVariants;
  }

  bool get _hasFieldConflict =>
      _identity.hasConflict || _generatedConflicts.isNotEmpty;

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
    _generatedConflicts.removeWhere(
      (signature, _) => !signatures.contains(signature),
    );

    for (final combination in combinations) {
      _generatedNameControllers.putIfAbsent(
        combination.signature,
        () => TextEditingController(text: combination.autoName),
      );
      _generatedSkuControllers.putIfAbsent(
        combination.signature,
        () => _watchedGeneratedController(
          combination.signature,
          CatalogIdentityField.sku,
          text: combination.skuFromBase(_skuController.text),
        ),
      );
      _generatedBarcodeControllers.putIfAbsent(
        combination.signature,
        () => _watchedGeneratedController(
          combination.signature,
          CatalogIdentityField.barcode,
        ),
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

    // Codes repeated across the generated rows are marked on the *second* row
    // that uses them, so the fix is one field away instead of a hunt through a
    // long list under a single "duplicate SKU" line.
    final duplicates = _duplicateGeneratedConflicts(combinations);
    setState(() {
      _generatedConflicts
        ..clear()
        ..addAll(duplicates);
      _generationErrorKey = duplicates.isEmpty ? null : 'duplicate_in_form';
      _valueErrorOptionIds = {};
    });
    return duplicates.isEmpty;
  }

  Map<String, Map<CatalogIdentityField, CatalogIdentityConflict>>
  _duplicateGeneratedConflicts(List<VariantCombination> combinations) {
    final conflicts =
        <String, Map<CatalogIdentityField, CatalogIdentityConflict>>{};
    final seen = <CatalogIdentityField, Map<String, String>>{
      CatalogIdentityField.sku: {},
      CatalogIdentityField.barcode: {},
    };
    final controllers = {
      CatalogIdentityField.sku: _generatedSkuControllers,
      CatalogIdentityField.barcode: _generatedBarcodeControllers,
    };

    for (final combination in combinations) {
      for (final field in CatalogIdentityField.values) {
        final raw = controllers[field]![combination.signature]?.text.trim();
        if (raw == null || raw.isEmpty) {
          continue;
        }
        // SKUs are stored upper-cased server-side, so "cof-1" and "COF-1" are
        // the same code; barcodes are compared as typed.
        final value = field == CatalogIdentityField.sku
            ? raw.toUpperCase()
            : raw;
        final owner = seen[field]![value];
        if (owner == null) {
          seen[field]![value] = combination.signature;
          continue;
        }
        conflicts.putIfAbsent(
          combination.signature,
          () => {},
        )[field] = CatalogIdentityConflict(
          field: field,
          kind: CatalogIdentityConflictKind.payload,
          target: CatalogIdentityTarget.variants,
          value: value,
        );
      }
    }
    return conflicts;
  }

  void _clearGeneratedConflict(String signature, CatalogIdentityField field) {
    if (!mounted) {
      return;
    }
    final row = _generatedConflicts[signature];
    if (row == null || !row.containsKey(field)) {
      return;
    }
    setState(() {
      row.remove(field);
      if (row.isEmpty) {
        _generatedConflicts.remove(signature);
      }
      if (_generatedConflicts.isEmpty &&
          _generationErrorKey == 'duplicate_in_form') {
        _generationErrorKey = null;
      }
    });
  }

  TextEditingController _watchedGeneratedController(
    String signature,
    CatalogIdentityField field, {
    String text = '',
  }) {
    final controller = TextEditingController(text: text);
    // Editing a marked row clears its own error immediately, so the red text
    // never outlives the value it described.
    controller.addListener(() => _clearGeneratedConflict(signature, field));
    return controller;
  }

  String? _generationErrorText(BuildContext context) {
    final key = _generationErrorKey;
    if (key == null) {
      return null;
    }
    final l10n = AppLocalizations.of(context)!;
    return switch (key) {
      'duplicate_in_form' => l10n.formFixHighlightedFieldsError,
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
      _syncIdentityWatcher();
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
    required this.conflictsBySignature,
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
  final Map<String, Map<CatalogIdentityField, CatalogIdentityConflict>>
  conflictsBySignature;

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
          requiredValidator: requiredValidator,
          numberValidator: numberValidator,
          conflictsBySignature: conflictsBySignature,
        ),
      ],
    );
  }
}
