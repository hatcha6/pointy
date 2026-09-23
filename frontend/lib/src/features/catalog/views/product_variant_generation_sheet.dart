import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../core/result.dart';
import '../../../data/models/catalog_identity_conflict.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_draft.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/design/design.dart';
import '../view_models/product_details_view_model.dart';
import '../view_models/variant_generation.dart';
import 'auto_sku_filler.dart';
import 'variant_option_creation_dialogs.dart';
import 'variant_generation_fields.dart';
import '../../../shared/components/pointy_progress.dart';

class ProductVariantGenerationSheet extends StatefulWidget {
  const ProductVariantGenerationSheet({
    super.key,
    required this.viewModel,
    this.onSaved,
  });

  final ProductDetailsViewModel viewModel;
  final VoidCallback? onSaved;

  @override
  State<ProductVariantGenerationSheet> createState() =>
      _ProductVariantGenerationSheetState();
}

class _ProductVariantGenerationSheetState
    extends State<ProductVariantGenerationSheet> {
  final _formKey = GlobalKey<FormState>();
  final _skuPrefixController = TextEditingController();
  final _priceController = TextEditingController();
  final Map<String, TextEditingController> _nameControllers = {};
  final Map<String, TextEditingController> _skuControllers = {};
  final Map<String, TextEditingController> _barcodeControllers = {};
  final Map<String, TextEditingController> _priceControllers = {};
  final Map<String, bool> _activeBySignature = {};
  List<VariantOption> _availableOptions = [];
  late Set<int> _selectedOptionIds;
  late Map<int, Set<int>> _selectedValueIdsByOption;
  Set<int> _valueErrorOptionIds = {};
  var _isLoadingOptions = false;
  var _optionsLoadFailed = false;
  final _isVariantActive = true;
  String? _defaultSignature;
  String? _generationErrorKey;
  var _lastBasePrice = '';
  late final AutoSkuFiller _autoSku;

  List<VariantOption> get _selectedOptions {
    return [
      for (final option in _availableOptions)
        if (_selectedOptionIds.contains(option.id)) option,
      for (final option in widget.viewModel.product.variantOptions)
        if (_selectedOptionIds.contains(option.id) &&
            !_availableOptions.any((item) => item.id == option.id))
          option,
    ];
  }

  List<VariantCombination> get _combinations {
    return generateVariantCombinations(
      options: _selectedOptions,
      selectedValueIdsByOption: _selectedValueIdsByOption,
    );
  }

  /// Duplicate SKU/barcode errors per generated row, keyed by combination
  /// signature — filled by the in-form check and by a rejected save.
  final Map<String, Map<CatalogIdentityField, CatalogIdentityConflict>>
  _generatedConflicts = {};

  List<_GenerationCandidate> get _candidates {
    final existingSignatures = {
      for (final variant in widget.viewModel.variants)
        if (_signatureForVariant(variant).isNotEmpty)
          _signatureForVariant(variant),
    };
    final reusableVariants =
        [
          for (final variant in widget.viewModel.variants)
            if (_signatureForVariant(variant).isEmpty) variant,
        ]..sort((a, b) {
          if (a.isDefault != b.isDefault) {
            return a.isDefault ? -1 : 1;
          }
          return a.id.compareTo(b.id);
        });

    var reusableIndex = 0;
    final candidates = <_GenerationCandidate>[];
    for (final combination in _combinations) {
      if (existingSignatures.contains(combination.signature)) {
        continue;
      }
      final reusableVariant = reusableIndex < reusableVariants.length
          ? reusableVariants[reusableIndex++]
          : null;
      candidates.add(
        _GenerationCandidate(
          combination: combination,
          reusableVariant: reusableVariant,
        ),
      );
    }
    return candidates;
  }

  @override
  void initState() {
    super.initState();
    final product = widget.viewModel.product;
    // The prefix starts blank, so each new variant takes the shop's next
    // number like any new product. A shop that keeps a scheme types its
    // prefix (SHIRT → SHIRT-RED).
    _priceController.text = product.effectiveUnitPrice.toStringAsFixed(2);
    _lastBasePrice = _priceController.text;
    _autoSku = AutoSkuFiller(widget.viewModel.catalogRepository);
    _skuPrefixController.addListener(_fillSkus);
    _priceController.addListener(_syncPricesFromBase);
    _selectedOptionIds = {
      for (final option in product.variantOptions) option.id,
    };
    // An option carries every value the shop ever saved under it, not the
    // ones this product uses — so the values already on its variants are what
    // the sheet opens with, rather than the whole catalogue of them.
    final valueIdsInUse = {
      for (final variant in widget.viewModel.variants)
        ...variant.optionValueIds,
    };
    _selectedValueIdsByOption = {
      for (final option in product.variantOptions)
        option.id: {
          for (final value in option.values)
            if (value.isActive && valueIdsInUse.contains(value.id)) value.id,
        },
    };
    _loadVariantOptions();
    _syncControllers();
    unawaited(_refreshAutoSkus());
  }

  @override
  void dispose() {
    _skuPrefixController.removeListener(_fillSkus);
    _skuPrefixController.dispose();
    _priceController.removeListener(_syncPricesFromBase);
    _priceController.dispose();
    for (final controller in _nameControllers.values) {
      controller.dispose();
    }
    for (final controller in _skuControllers.values) {
      controller.dispose();
    }
    for (final controller in _barcodeControllers.values) {
      controller.dispose();
    }
    for (final controller in _priceControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        return Material(
          color: context.pointyColors.surface,
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
                        Icons.auto_awesome_motion_outlined,
                        color: context.pointyColors.primaryStrong,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l10n.generateVariantsTitle,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  VariantOptionField(
                    availableOptions: _availableOptions,
                    selectedOptions: _selectedOptions,
                    isLoading: _isLoadingOptions,
                    hasError: _optionsLoadFailed,
                    onReload: _loadVariantOptions,
                    onToggleOption: _toggleOption,
                    onCreateOption: _createVariantOption,
                  ),
                  const SizedBox(height: 12),
                  VariantOptionValuesField(
                    options: _selectedOptions,
                    selectedValueIdsByOption: _selectedValueIdsByOption,
                    errorOptionIds: _valueErrorOptionIds,
                    onToggleValue: _toggleOptionValue,
                    onCreateValue: _createVariantOptionValue,
                    onSelectAllValues: _selectAllOptionValues,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _skuPrefixController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: l10n.skuPrefixLabel,
                      hintText: l10n.skuPrefixHint,
                      prefixIcon: const Icon(Icons.qr_code_2),
                      helperText: l10n.skuOptionalHelper,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _priceController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [DecimalTextInputFormatter()],
                    decoration: InputDecoration(
                      labelText: l10n.generatedVariantPriceLabel,
                      prefixIcon: const Icon(Icons.sell_outlined),
                    ),
                    validator: _numberValidator,
                  ),
                  const SizedBox(height: 12),
                  GeneratedVariantsPreview(
                    combinations: [
                      for (final candidate in _candidates)
                        candidate.combination,
                    ],
                    nameControllers: _nameControllers,
                    skuControllers: _skuControllers,
                    barcodeControllers: _barcodeControllers,
                    priceControllers: _priceControllers,
                    activeBySignature: _activeBySignature,
                    defaultSignature: _defaultSignature,
                    onDefaultChanged: (signature) =>
                        setState(() => _defaultSignature = signature),
                    onActiveChanged: (signature, value) =>
                        setState(() => _activeBySignature[signature] = value),
                    numberValidator: _numberValidator,
                    conflictsBySignature: _generatedConflicts,
                  ),
                  if (_candidates.isEmpty && _combinations.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(l10n.generatedVariantsNoMissing),
                  ],
                  if (_generationErrorText(context) != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _generationErrorText(context)!,
                      style: TextStyle(color: context.pointyColors.danger),
                    ),
                  ],
                  if (widget.viewModel.errorMessage ==
                      'variant_generate_error') ...[
                    const SizedBox(height: 8),
                    Text(
                      l10n.variantGenerateError,
                      style: TextStyle(color: context.pointyColors.danger),
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
                            child: PointySpinner(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome_motion_outlined),
                    label: Text(
                      widget.viewModel.isSavingVariant
                          ? l10n.savingButton
                          : l10n.generateVariantsButton,
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

  Future<void> _loadVariantOptions() async {
    setState(() {
      _isLoadingOptions = true;
      _optionsLoadFailed = false;
    });

    final result = await widget.viewModel.catalogRepository
        .loadAllActiveVariantOptions();
    if (!mounted) {
      return;
    }
    switch (result) {
      case Ok<List<VariantOption>>():
        setState(() {
          _availableOptions = result.value;
          _isLoadingOptions = false;
          _optionsLoadFailed = false;
          for (final option in _selectedOptions) {
            _selectedValueIdsByOption.putIfAbsent(option.id, () => const {});
          }
          _syncControllers();
        });
      case Error<List<VariantOption>>():
        setState(() {
          _isLoadingOptions = false;
          _optionsLoadFailed = true;
        });
    }
  }

  void _toggleOption(VariantOption option) {
    setState(() {
      if (_selectedOptionIds.remove(option.id)) {
        _selectedValueIdsByOption.remove(option.id);
        _valueErrorOptionIds = {..._valueErrorOptionIds}..remove(option.id);
      } else {
        _selectedOptionIds.add(option.id);
        // Values are picked deliberately — see the create form's toggle.
        _selectedValueIdsByOption[option.id] = const {};
      }
      _generationErrorKey = null;
      _syncControllers();
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
      _syncControllers();
    });
  }

  void _syncControllers() {
    final candidates = _candidates;
    final signatures = {
      for (final candidate in candidates) candidate.combination.signature,
    };

    for (final entry in [..._nameControllers.entries]) {
      if (!signatures.contains(entry.key)) {
        entry.value.dispose();
        _nameControllers.remove(entry.key);
      }
    }
    for (final entry in [..._skuControllers.entries]) {
      if (!signatures.contains(entry.key)) {
        _autoSku.forget(entry.value);
        entry.value.dispose();
        _skuControllers.remove(entry.key);
      }
    }
    for (final entry in [..._barcodeControllers.entries]) {
      if (!signatures.contains(entry.key)) {
        entry.value.dispose();
        _barcodeControllers.remove(entry.key);
      }
    }
    for (final entry in [..._priceControllers.entries]) {
      if (!signatures.contains(entry.key)) {
        entry.value.dispose();
        _priceControllers.remove(entry.key);
      }
    }
    _activeBySignature.removeWhere(
      (signature, _) => !signatures.contains(signature),
    );

    for (final candidate in candidates) {
      final combination = candidate.combination;
      final reusableVariant = candidate.reusableVariant;
      final reusableName = candidate.reusableVariant?.name.trim() ?? '';
      _nameControllers.putIfAbsent(
        combination.signature,
        () => TextEditingController(
          text: reusableName.isNotEmpty ? reusableName : combination.autoName,
        ),
      );
      _skuControllers.putIfAbsent(
        combination.signature,
        () => TextEditingController(text: reusableVariant?.sku ?? ''),
      );
      _barcodeControllers.putIfAbsent(
        combination.signature,
        () => TextEditingController(text: reusableVariant?.barcode ?? ''),
      );
      _priceControllers.putIfAbsent(
        combination.signature,
        () => TextEditingController(
          text:
              reusableVariant?.unitPrice.toStringAsFixed(2) ??
              _priceController.text,
        ),
      );
      _activeBySignature.putIfAbsent(
        combination.signature,
        () => reusableVariant?.isActive ?? _isVariantActive,
      );
    }

    _GenerationCandidate? defaultCandidate;
    for (final candidate in candidates) {
      if (candidate.reusableVariant?.isDefault ?? false) {
        defaultCandidate = candidate;
        break;
      }
    }
    final currentDefaultExists = signatures.contains(_defaultSignature);
    if (!currentDefaultExists) {
      _defaultSignature = defaultCandidate?.combination.signature;
    }
    _fillSkus();
  }

  /// Asks which number the next new variant gets, and writes it into every
  /// new row the user has not typed a SKU into.
  Future<void> _refreshAutoSkus() async {
    await _autoSku.refresh();
    if (!mounted) {
      return;
    }
    _fillSkus();
  }

  /// Codes the rows that become new variants: from the prefix when the shop
  /// keeps a scheme, otherwise with a number each, counting up from the next
  /// one. A row that reuses an existing variant keeps the code it was saved
  /// with — the shop may have been printing it on labels.
  void _fillSkus() {
    final prefix = _skuPrefixController.text;
    var offset = 0;
    for (final candidate in _candidates) {
      if (candidate.reusableVariant != null) {
        continue;
      }
      final combination = candidate.combination;
      final controller = _skuControllers[combination.signature];
      if (controller == null) {
        continue;
      }
      _autoSku.fill(
        controller,
        prefix.trim().isEmpty
            ? _autoSku.numberAt(offset++)
            : combination.skuFromBase(prefix),
        barcode: _barcodeControllers[combination.signature],
      );
    }
  }

  void _syncPricesFromBase() {
    final nextPrice = _priceController.text;
    final previousPrice = _lastBasePrice;
    if (nextPrice == previousPrice) {
      return;
    }
    for (final candidate in _candidates) {
      final controller = _priceControllers[candidate.combination.signature];
      if (controller == null || candidate.reusableVariant != null) {
        continue;
      }
      if (controller.text.trim().isEmpty || controller.text == previousPrice) {
        controller.text = nextPrice;
      }
    }
    _lastBasePrice = nextPrice;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context)!;
    // A number filled in when the sheet opened may have gone to another till
    // since; untouched rows move to the next free ones before they are sent.
    await _refreshAutoSkus();
    if (!mounted) {
      return;
    }
    final isValid = _formKey.currentState?.validate() ?? false;
    _syncControllers();
    if (!isValid || !_validateGeneration()) {
      return;
    }

    final candidates = _candidates;
    final drafts = [
      for (final candidate in candidates)
        ProductVariantDraft(
          id: candidate.reusableVariant?.id,
          productId: widget.viewModel.product.id,
          name: _nameControllers[candidate.combination.signature]!.text.trim(),
          sku: _skuControllers[candidate.combination.signature]!.text.trim(),
          barcode: _barcodeControllers[candidate.combination.signature]!.text
              .trim(),
          unitPrice: _parseNumber(
            _priceControllers[candidate.combination.signature]!.text,
          )!,
          isActive: _activeBySignature[candidate.combination.signature] ?? true,
          isDefault: candidate.combination.signature == _defaultSignature,
          optionValueIds: candidate.combination.valueIds,
        ),
    ];

    final saved = await widget.viewModel.saveGeneratedVariants(
      variantOptionIds: [for (final option in _selectedOptions) option.id],
      variants: drafts,
    );
    if (!mounted) {
      return;
    }
    if (!saved) {
      _applyServerConflicts(candidates);
      return;
    }

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(l10n.variantsGeneratedMessage)));
    widget.onSaved?.call();
  }

  bool _validateGeneration() {
    final missingOptionIds = {
      for (final option in _selectedOptions)
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
    if (_selectedOptions.isNotEmpty && _combinations.isEmpty) {
      setState(() => _generationErrorKey = 'missing_values');
      return false;
    }
    if (_combinations.length > 200) {
      setState(() => _generationErrorKey = 'too_many');
      return false;
    }

    // Codes already spoken for — by one of the product's other variants, or by
    // an earlier row of this same list — are marked on the row that repeats
    // them, so the fix is one field away instead of a hunt down a long list.
    // Which of the two it is decides the wording, so they stay separate.
    final existingBySku = <String, ProductVariant>{
      for (final variant in widget.viewModel.variants)
        variant.sku.toUpperCase(): variant,
    };
    final existingByBarcode = <String, ProductVariant>{
      for (final variant in widget.viewModel.variants)
        if (variant.barcode.trim().isNotEmpty) variant.barcode.trim(): variant,
    };
    for (final candidate in _candidates) {
      // A row that rewrites an existing variant is not competing with itself.
      final reusableVariant = candidate.reusableVariant;
      if (reusableVariant != null) {
        existingBySku.remove(reusableVariant.sku.toUpperCase());
        existingByBarcode.remove(reusableVariant.barcode.trim());
      }
    }

    final conflicts =
        <String, Map<CatalogIdentityField, CatalogIdentityConflict>>{};
    final seenSkus = <String>{};
    final seenBarcodes = <String>{};
    for (final candidate in _candidates) {
      final signature = candidate.combination.signature;
      final sku = _skuControllers[signature]!.text.trim().toUpperCase();
      final skuConflict = _rowConflict(
        field: CatalogIdentityField.sku,
        value: sku,
        owner: existingBySku[sku],
        repeatedInForm: !seenSkus.add(sku),
      );
      if (skuConflict != null) {
        conflicts.putIfAbsent(signature, () => {})[CatalogIdentityField.sku] =
            skuConflict;
      }
      final barcode = _barcodeControllers[signature]!.text.trim();
      final barcodeConflict = _rowConflict(
        field: CatalogIdentityField.barcode,
        value: barcode,
        owner: existingByBarcode[barcode],
        repeatedInForm: !seenBarcodes.add(barcode),
      );
      if (barcodeConflict != null) {
        conflicts.putIfAbsent(
          signature,
          () => {},
        )[CatalogIdentityField.barcode] = barcodeConflict;
      }
    }

    setState(() {
      _generatedConflicts
        ..clear()
        ..addAll(conflicts);
      _generationErrorKey = conflicts.isEmpty ? null : 'duplicate_in_form';
      _valueErrorOptionIds = {};
    });
    return conflicts.isEmpty;
  }

  /// The conflict for one generated row's code: the variant of this product
  /// that already carries it, or a repeat of an earlier row. Null when free.
  CatalogIdentityConflict? _rowConflict({
    required CatalogIdentityField field,
    required String value,
    required ProductVariant? owner,
    required bool repeatedInForm,
  }) {
    if (value.isEmpty) {
      return null;
    }
    if (owner != null) {
      return CatalogIdentityConflict(
        field: field,
        kind: CatalogIdentityConflictKind.variant,
        target: CatalogIdentityTarget.variants,
        value: value,
        productName: widget.viewModel.product.name,
        variantName: owner.displayLabel,
        variantId: owner.id,
        variantSku: owner.sku,
      );
    }
    if (repeatedInForm) {
      return CatalogIdentityConflict(
        field: field,
        kind: CatalogIdentityConflictKind.payload,
        target: CatalogIdentityTarget.variants,
        value: value,
      );
    }
    return null;
  }

  /// Routes a rejected save's conflicts to the row that carries the value; the
  /// server indexes them by position in the submitted list.
  void _applyServerConflicts(List<_GenerationCandidate> candidates) {
    final conflicts =
        <String, Map<CatalogIdentityField, CatalogIdentityConflict>>{};
    for (final conflict in widget.viewModel.variantSaveConflicts) {
      final index = conflict.index;
      if (index == null || index < 0 || index >= candidates.length) {
        continue;
      }
      conflicts.putIfAbsent(
        candidates[index].combination.signature,
        () => {},
      )[conflict.field] = conflict;
    }
    setState(() {
      _generatedConflicts
        ..clear()
        ..addAll(conflicts);
      _generationErrorKey = conflicts.isEmpty ? null : 'duplicate_in_form';
    });
  }

  Future<void> _createVariantOption(String initialName) async {
    final created = await showCreateVariantOptionDialog(
      context: context,
      catalogRepository: widget.viewModel.catalogRepository,
      existingOptions: _availableOptions,
      initialName: initialName,
    );
    if (!mounted || created == null) {
      return;
    }
    setState(() {
      _availableOptions = [..._availableOptions, created]
        ..sort((a, b) {
          final order = a.displayOrder.compareTo(b.displayOrder);
          return order == 0 ? a.displayLabel.compareTo(b.displayLabel) : order;
        });
      _selectedOptionIds.add(created.id);
      _selectedValueIdsByOption[created.id] = const {};
      _generationErrorKey = null;
      _syncControllers();
    });
  }

  void _selectAllOptionValues(VariantOption option) {
    setState(() {
      _selectedValueIdsByOption[option.id] = {
        for (final value in option.values)
          if (value.isActive) value.id,
      };
      _valueErrorOptionIds = {..._valueErrorOptionIds}..remove(option.id);
      _generationErrorKey = null;
      _syncControllers();
    });
  }

  Future<void> _createVariantOptionValue(
    VariantOption option,
    String initialName,
  ) async {
    final created = await showCreateVariantOptionValueDialog(
      context: context,
      catalogRepository: widget.viewModel.catalogRepository,
      option: option,
      initialName: initialName,
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
      _syncControllers();
    });
  }

  void _replaceAvailableOption(VariantOption option) {
    if (_availableOptions.any((current) => current.id == option.id)) {
      _availableOptions = [
        for (final current in _availableOptions)
          if (current.id == option.id) option else current,
      ];
    } else {
      _availableOptions = [..._availableOptions, option];
    }
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
    return parseDecimal(value);
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
}

class _GenerationCandidate {
  const _GenerationCandidate({
    required this.combination,
    required this.reusableVariant,
  });

  final VariantCombination combination;
  final ProductVariant? reusableVariant;
}

String _signatureForVariant(ProductVariant variant) {
  final ids = [...variant.optionValueIds]..sort();
  return ids.join('|');
}
