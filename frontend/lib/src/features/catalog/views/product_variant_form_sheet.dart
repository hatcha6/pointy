import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/parsing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_draft.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../view_models/product_details_view_model.dart';
import 'product_form_fields.dart';
import 'product_form_section.dart';
import 'variant_option_creation_dialogs.dart';
import 'variant_generation_fields.dart';
import 'variant_identity_watcher.dart';

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
  final _skuFieldKey = GlobalKey();
  final _barcodeFieldKey = GlobalKey();
  late final TextEditingController _variantNameController;
  late final TextEditingController _skuController;
  late final TextEditingController _barcodeController;
  late final TextEditingController _priceController;
  late final VariantIdentityWatcher _identity;
  late Map<int, Set<int>> _selectedValueIdsByOption;
  late List<VariantOption> _variantOptions;
  Set<int> _valueErrorOptionIds = {};
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
    // Editing a variant excludes its own row, so its current SKU/barcode read
    // as free rather than as a clash with itself.
    _identity = VariantIdentityWatcher(
      catalogRepository: widget.viewModel.catalogRepository,
      skuController: _skuController,
      barcodeController: _barcodeController,
      excludeVariantId: variant?.id,
    );
    _selectedValueIdsByOption = _initialValueIdsByOption(variant);
    _variantOptions = widget.viewModel.product.variantOptions;
    _isActive = variant?.isActive ?? true;
    _isDefault = variant?.isDefault ?? false;
  }

  @override
  void dispose() {
    _identity.dispose();
    _variantNameController.dispose();
    _skuController.dispose();
    _barcodeController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  /// Anything the user would lose on an accidental dismiss. Evaluated fresh on
  /// every back/dismiss attempt, so text typed without a rebuild still counts.
  bool get _isDirty {
    final variant = widget.variant;
    if (variant == null) {
      return _variantNameController.text.trim().isNotEmpty ||
          _skuController.text.trim().isNotEmpty ||
          _barcodeController.text.trim().isNotEmpty ||
          _priceController.text.trim().isNotEmpty ||
          _selectedOptionValueIds.isNotEmpty;
    }
    return _variantNameController.text.trim() != variant.name.trim() ||
        _skuController.text.trim() != variant.sku.trim() ||
        _barcodeController.text.trim() != variant.barcode.trim() ||
        _parseNumber(_priceController.text) != variant.unitPrice ||
        _isActive != variant.isActive ||
        _isDefault != variant.isDefault ||
        !setEquals(
          _selectedOptionValueIds.toSet(),
          variant.optionValueIds.toSet(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    // The save path pops through onSaved (an explicit Navigator.pop), which
    // PopScope does not intercept — so saving still closes normally.
    return PointyUnsavedChangesGuard(
      isDirty: () => _isDirty,
      child: _buildSheet(context, l10n),
    );
  }

  Widget _buildSheet(BuildContext context, AppLocalizations l10n) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.viewModel, _identity]),
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
                  ProductFormSection(
                    icon: _isEditing ? Icons.edit_outlined : Icons.add,
                    title: _isEditing
                        ? l10n.editVariantTitle
                        : l10n.newVariantTitle,
                    children: [
                      ProductVariantFormFields(
                        variantNameController: _variantNameController,
                        skuController: _skuController,
                        barcodeController: _barcodeController,
                        priceController: _priceController,
                        selectedOptionValues: const [],
                        isActive: _isActive,
                        isDefault: _isDefault,
                        onPickOptionValues: () {},
                        onClearOptionValues: null,
                        onActiveChanged: (value) =>
                            setState(() => _isActive = value),
                        onDefaultChanged: (value) =>
                            setState(() => _isDefault = value),
                        requiredValidator: (value) =>
                            _requiredValidator(context, value),
                        numberValidator: (value) =>
                            _numberValidator(context, value),
                        showOptionValues: false,
                        skuState: _identity.skuState,
                        barcodeState: _identity.barcodeState,
                        skuFieldKey: _skuFieldKey,
                        barcodeFieldKey: _barcodeFieldKey,
                      ),
                      if (_variantOptions.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        VariantOptionValuesField(
                          options: _variantOptions,
                          selectedValueIdsByOption: _selectedValueIdsByOption,
                          errorOptionIds: _valueErrorOptionIds,
                          onToggleValue: _toggleOptionValue,
                          onCreateValue: _createVariantOptionValue,
                          showInactiveSelectedValues: true,
                        ),
                      ],
                    ],
                  ),
                  if (_saveErrorKey != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      // A rejected save with a known field conflict already
                      // marks the offending input; the footer only has to point
                      // at it rather than repeat a generic "could not save".
                      _identity.hasConflict
                          ? l10n.formFixHighlightedFieldsError
                          : _saveErrorKey == 'variant_update_error'
                          ? l10n.variantUpdateError
                          : l10n.variantCreateError,
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
                        : Icon(_isEditing ? Icons.save_outlined : Icons.add),
                    label: Text(
                      widget.viewModel.isSavingVariant
                          ? l10n.savingButton
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

  Map<int, Set<int>> _initialValueIdsByOption(ProductVariant? variant) {
    final selected = <int, Set<int>>{};
    for (final optionValue in variant?.optionValues ?? const []) {
      selected.putIfAbsent(optionValue.optionId, () => {}).add(optionValue.id);
    }
    return selected;
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
    // A code typed in the last few hundred milliseconds may still be
    // un-checked; settle it before the form decides it is valid.
    await _identity.refresh();
    if (!mounted) {
      return;
    }
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      _scrollToFirstConflict();
      return;
    }
    if (!_validateOptionValues()) {
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
      optionValueIds: _selectedOptionValueIds,
    );

    final variant = widget.variant;
    final saved = variant == null
        ? await widget.viewModel.createVariant(draft)
        : await widget.viewModel.updateVariant(id: variant.id, draft: draft);
    if (!mounted) {
      return;
    }
    if (!saved) {
      // The server re-checks every write: a clash it found (including one that
      // appeared between the live check and the save) lands on its field.
      _identity.applyConflicts(widget.viewModel.variantSaveConflicts);
      _scrollToFirstConflict();
      return;
    }

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

  List<int> get _selectedOptionValueIds {
    return [
      for (final option in _variantOptions)
        ...(_selectedValueIdsByOption[option.id] ?? const <int>{}),
    ];
  }

  void _toggleOptionValue(VariantOption option, int valueId) {
    setState(() {
      final selected = {
        ...(_selectedValueIdsByOption[option.id] ?? const <int>{}),
      };
      if (selected.contains(valueId)) {
        selected.clear();
      } else {
        selected
          ..clear()
          ..add(valueId);
      }
      _selectedValueIdsByOption[option.id] = selected;
      _valueErrorOptionIds = {..._valueErrorOptionIds}..remove(option.id);
    });
  }

  bool _validateOptionValues() {
    final options = _variantOptions;
    if (options.isEmpty) {
      return true;
    }
    final missing = {
      for (final option in options)
        if ((_selectedValueIdsByOption[option.id] ?? const {}).isEmpty)
          option.id,
    };
    setState(() => _valueErrorOptionIds = missing);
    return missing.isEmpty;
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
      _variantOptions = [
        for (final current in _variantOptions)
          if (current.id == option.id)
            current.copyWith(values: [...current.values, created])
          else
            current,
      ];
      _selectedValueIdsByOption.update(
        option.id,
        (ids) => {created.id},
        ifAbsent: () => {created.id},
      );
      _valueErrorOptionIds = {..._valueErrorOptionIds}..remove(option.id);
    });
  }
}
