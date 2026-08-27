import 'package:flutter/material.dart';

import '../../../core/parsing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../data/models/product_variant_draft.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/design/design.dart';
import '../view_models/product_details_view_model.dart';
import 'product_form_fields.dart';
import 'product_form_section.dart';
import 'variant_option_creation_dialogs.dart';
import 'variant_generation_fields.dart';
import '../../../shared/components/pointy_progress.dart';

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
    _selectedValueIdsByOption = _initialValueIdsByOption(variant);
    _variantOptions = widget.viewModel.product.variantOptions;
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
                      _saveErrorKey == 'variant_update_error'
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
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
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
