import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/result.dart';
import '../../../data/models/customer_asset.dart';
import '../../../data/models/modifier_group.dart';
import '../../../data/models/product_tracking.dart';
import '../../../data/models/product_unit.dart';
import '../../../data/models/product_update_draft.dart';
import '../../../data/models/tracking_mode.dart';
import '../../../data/models/unit_of_measure.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/tracking/tracking_features.dart';
import '../../../shared/tracking/tracking_labels.dart';
import '../view_models/product_details_view_model.dart';
import '../view_models/tracking_mode_refusal.dart';
import 'modifier_group_selector.dart';
import 'pricing_currency_field.dart';
import 'product_form_fields.dart';
import 'product_form_section.dart';
import 'product_image_picker.dart';
import 'product_tracking_fields.dart';
import 'product_units_editor.dart';
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
  List<ModifierGroup> _availableModifierGroups = [];
  late Set<int> _selectedModifierGroupIds;
  var _isLoadingModifierGroups = false;
  var _modifierGroupsLoadFailed = false;
  ProductImageSelection? _selectedImage;
  var _isLoadingVariantOptions = false;
  var _variantOptionsLoadFailed = false;
  List<UnitOfMeasure> _availableUnits = [];
  late List<ProductUnit> _units;
  late String _defaultSaleUnit;
  late String _defaultPurchaseUnit;
  var _isLoadingUnits = false;
  var _unitsLoadFailed = false;
  late bool _isActive;
  late ProductTracking _tracking;
  var _features = TrackingFeatures.none;
  var _assetTypesRequested = false;
  List<CustomerAssetType> _assetTypes = [];
  var _isLoadingAssetTypes = false;
  var _assetTypesLoadFailed = false;
  late String _unit;
  late String _pricingCurrency;
  late bool _isService;
  late bool _isPrepared;
  late final String _initialSignature;

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
    _selectedModifierGroupIds = {
      for (final group in product.modifierGroups) group.id,
    };
    _isActive = product.isActive;
    _tracking = product.tracking;
    _unit = product.unit;
    _pricingCurrency = product.pricingCurrency;
    _isService = product.isService;
    _isPrepared = product.isPrepared;
    _units = product.units;
    _defaultSaleUnit = product.defaultSaleUnit;
    _defaultPurchaseUnit = product.defaultPurchaseUnit;
    _nameController.addListener(_refreshImageSearchSeed);
    _initialSignature = _formSignature();
    _loadVariantOptions();
    _loadModifierGroups();
    _loadUnits();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _features = TrackingFeaturesScope.of(context);
    if (_showsTrackingSection &&
        (_features.serial || _tracking.mode.tracksUnits) &&
        !_assetTypesRequested) {
      _assetTypesRequested = true;
      _loadAssetTypes();
    }
  }

  /// The whole tracking choice, once the shop identifies stock at all — or for
  /// a product already serial, whose articles must stay explained even in a
  /// shop that has since switched the trade off. Otherwise the expiry switch.
  bool get _showsTrackingSection =>
      _features.any || widget.viewModel.product.trackingMode.tracksUnits;

  /// What is saved: a service or a dish is never tracked.
  ProductTracking get _effectiveTracking => _isService || _isPrepared
      ? _tracking.copyWith(mode: TrackingMode.quantity)
      : _tracking;

  Future<void> _loadAssetTypes() async {
    setState(() {
      _isLoadingAssetTypes = true;
      _assetTypesLoadFailed = false;
    });
    final result = await widget.viewModel.catalogRepository.loadAssetTypes();
    if (!mounted) {
      return;
    }
    setState(() {
      _isLoadingAssetTypes = false;
      switch (result) {
        case Ok<List<CustomerAssetType>>(value: final types):
          _assetTypes = types;
        case Error<List<CustomerAssetType>>():
          _assetTypesLoadFailed = true;
      }
    });
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

  /// A stable string of every editable field, compared against
  /// [_initialSignature] to detect unsaved edits. The async loaders only fill
  /// the *available* option/unit lists, never the selections below, so a load
  /// completing can never make the sheet look dirty on its own.
  String _formSignature() {
    String sortedIds(Iterable<int> ids) => (ids.toList()..sort()).join(',');
    return <Object?>[
      _nameController.text,
      _descriptionController.text,
      sortedIds(_selectedCategories.map((category) => category.id)),
      sortedIds(_selectedVariantOptionIds),
      sortedIds(_selectedModifierGroupIds),
      _selectedImage != null,
      _isActive,
      _tracking.toJson(),
      _unit,
      _pricingCurrency,
      _isService,
      _isPrepared,
      _defaultSaleUnit,
      _defaultPurchaseUnit,
      _units
          .map(
            (unit) => [
              unit.code,
              unit.factorToBase,
              unit.price,
              unit.isSellable,
              unit.isPurchasable,
              unit.displayOrder,
              unit.barcodes.join('/'),
            ].join(':'),
          )
          .join(','),
    ].join('|');
  }

  /// Anything the user would lose on an accidental dismiss. Evaluated fresh on
  /// every back/dismiss attempt, so text typed without a rebuild still counts.
  bool get _isDirty => _formSignature() != _initialSignature;

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
      listenable: widget.viewModel,
      builder: (context, _) {
        return Material(
          color: context.pointyColors.surface,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
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
                              tracksExpiry: _tracking.mode.tracksLots,
                              onPickCategories: _pickCategories,
                              onClearCategories: () =>
                                  setState(() => _selectedCategories = []),
                              onActiveChanged: (value) =>
                                  setState(() => _isActive = value),
                              onTracksExpiryChanged: _showsTrackingSection
                                  ? null
                                  : (value) => setState(
                                      () => _tracking = _tracking.copyWith(
                                        mode: value
                                            ? TrackingMode.batch
                                            : TrackingMode.quantity,
                                      ),
                                    ),
                              unit: _unit,
                              isService: _isService,
                              isPrepared: _isPrepared,
                              onUnitChanged: (value) =>
                                  setState(() => _unit = value),
                              onIsServiceChanged: (value) =>
                                  setState(() => _isService = value),
                              onIsPreparedChanged: (value) =>
                                  setState(() => _isPrepared = value),
                              requiredValidator: (value) =>
                                  _requiredValidator(context, value),
                            ),
                            if (widget
                                .viewModel
                                .pricingCurrencies
                                .isNotEmpty) ...[
                              const SizedBox(height: 12),
                              PricingCurrencyField(
                                currencies: widget.viewModel.pricingCurrencies,
                                baseCurrencyCode:
                                    widget.viewModel.baseCurrencyCode,
                                selectedCode: _pricingCurrency,
                                onChanged: (code) =>
                                    setState(() => _pricingCurrency = code),
                                rate: _pricingCurrency.isEmpty
                                    ? null
                                    : widget.viewModel.rateFor(
                                        _pricingCurrency,
                                      ),
                                // No price field on this sheet — prices live on
                                // the variants — so the preview shows the rate
                                // rather than a converted amount.
                                enteredAmount: null,
                              ),
                            ],
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
                              productId: widget.viewModel.product.id,
                              productName: widget.viewModel.product.name,
                              onCompanionCaptured: widget.viewModel.loadProduct,
                            ),
                            const SizedBox(height: 12),
                            VariantOptionField(
                              availableOptions: _availableVariantOptions,
                              selectedOptions: _selectedVariantOptions,
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
                        if (_showsTrackingSection) ...[
                          const SizedBox(height: 12),
                          ProductFormSection(
                            icon: Icons.qr_code_scanner_outlined,
                            title: l10n.productTrackingSectionTitle,
                            children: [
                              ProductTrackingFields(
                                value: _tracking,
                                onChanged: (tracking) =>
                                    setState(() => _tracking = tracking),
                                features: _features,
                                savedMode:
                                    widget.viewModel.product.tracking.mode,
                                assetTypes: _assetTypes,
                                assetTypesLoading: _isLoadingAssetTypes,
                                assetTypesFailed: _assetTypesLoadFailed,
                                onReloadAssetTypes: _loadAssetTypes,
                                doesNotKeepStock: _isService || _isPrepared,
                                errorText: widget.viewModel.trackingModeError,
                                enabled: !widget.viewModel.isSavingProduct,
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        // Same units section as the create flow — conversions,
                        // per-unit prices, and defaults stay user-editable
                        // after a product exists.
                        ProductFormSection(
                          icon: Icons.straighten_outlined,
                          title: l10n.productUnitsSectionTitle,
                          children: [
                            ProductUnitsEditor(
                              availableUnits: _availableUnits,
                              baseUnitCode: _unit,
                              units: _units,
                              defaultSaleUnit: _defaultSaleUnit,
                              defaultPurchaseUnit: _defaultPurchaseUnit,
                              enabled: !widget.viewModel.isSavingProduct,
                              isLoading: _isLoadingUnits,
                              hasError: _unitsLoadFailed,
                              onReload: _loadUnits,
                              onUnitsChanged: (units) =>
                                  setState(() => _units = units),
                              onDefaultSaleChanged: (code) =>
                                  setState(() => _defaultSaleUnit = code),
                              onDefaultPurchaseChanged: (code) =>
                                  setState(() => _defaultPurchaseUnit = code),
                            ),
                          ],
                        ),
                        if (widget.viewModel.errorMessage ==
                            'product_update_error') ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.productUpdateError,
                            style: TextStyle(
                              color: context.pointyColors.danger,
                            ),
                          ),
                        ],
                        if (widget.viewModel.errorMessage ==
                            'product_image_attach_error') ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.productImageAttachError,
                            style: TextStyle(
                              color: context.pointyColors.danger,
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
                              child: PointySpinner(strokeWidth: 2),
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
    final tracking = _effectiveTracking;
    // As the form read it: a product an older server sent with only
    // `tracks_expiry` is already lot-tracked, not a change to confirm.
    final savedMode = widget.viewModel.product.tracking.mode;
    // Never a silent flip: a new mode re-labels how everything this product
    // receives and sells is recorded from now on. Over a stocked shelf the
    // server asks the sharper question — what becomes of that stock — and it
    // is asked instead of this one, never as well.
    if (tracking.mode != savedMode &&
        !_serverAsksAboutStock(savedMode, tracking.mode)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => PointyConfirmationDialog(
          title: l10n.productTrackingChangeTitle,
          message: l10n.productTrackingChangeBody(
            trackingModeLabel(l10n, savedMode),
            trackingModeLabel(l10n, tracking.mode),
          ),
          confirmLabel: l10n.productTrackingChangeConfirm,
          icon: Icons.qr_code_scanner_outlined,
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
    }

    final draft = ProductUpdateDraft(
      name: _nameController.text.trim(),
      description: _descriptionController.text.trim(),
      isActive: _isActive,
      tracksExpiry: tracking.mode.tracksLots,
      tracking: tracking,
      unit: _unit,
      pricingCurrency: _pricingCurrency,
      isService: _isService,
      isPrepared: _isPrepared,
      defaultSaleUnit: _defaultSaleUnit,
      defaultPurchaseUnit: _defaultPurchaseUnit,
      units: _units,
      categoryIds: [for (final category in _selectedCategories) category.id],
      variantOptionIds: [
        for (final optionId in _selectedVariantOptionIds) optionId,
      ],
      modifierGroupIds: [
        for (final groupId in _selectedModifierGroupIds) groupId,
      ],
    );
    var updated = await widget.viewModel.updateProduct(draft);
    if (!mounted) {
      return;
    }
    // The server held the save back to ask what becomes of the stock already
    // on the shelf. Ask, then send the same edit again with the answer.
    if (widget.viewModel.pendingTrackingIdentification case final question?) {
      final confirmed = await _confirmIdentifyLater(question);
      if (!mounted) {
        return;
      }
      if (!confirmed) {
        // Back on the saved mode, so the sheet and the shop agree about what
        // is in force; the rest of the edit is still here to save.
        setState(() => _tracking = _tracking.copyWith(mode: savedMode));
        return;
      }
      updated = await widget.viewModel.updateProduct(
        draft.identifyingStockLater(),
      );
      if (!mounted) {
        return;
      }
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

  /// Whether the server, not this sheet, should ask about the change: turning
  /// serials or lots on over a stocked shelf is answered by its question about
  /// that stock. The shelf is the one this sheet last saw; a stale zero only
  /// means the generic question comes first.
  bool _serverAsksAboutStock(TrackingMode from, TrackingMode to) =>
      from == TrackingMode.quantity &&
      (to == TrackingMode.serial || to == TrackingMode.batch) &&
      widget.viewModel.product.quantityOnHand > 0;

  /// What turning tracking on does to the stock already on the shelf: serials
  /// wait «بانتظار المعرّف», unsellable until each is scanned; lots land in
  /// one lot with no number and keep selling.
  Future<bool> _confirmIdentifyLater(
    TrackingIdentificationRequest question,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final quantity = question.onHand.isNotEmpty
        ? question.onHand
        : formatPrintedQuantity(widget.viewModel.product.quantityOnHand);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => PointyConfirmationDialog(
        key: const ValueKey('product_tracking_identify_later_dialog'),
        title: l10n.productTrackingIdentifyLaterTitle,
        message: question.requestedMode.tracksUnits
            ? l10n.productTrackingIdentifyLaterUnitsBody(quantity)
            : l10n.productTrackingIdentifyLaterLotsBody(quantity),
        confirmLabel: l10n.productTrackingIdentifyLaterConfirm,
        icon: Icons.pending_actions_outlined,
      ),
    );
    return confirmed == true;
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

  void _toggleModifierGroup(ModifierGroup group) {
    setState(() {
      if (!_selectedModifierGroupIds.remove(group.id)) {
        _selectedModifierGroupIds.add(group.id);
      }
    });
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

  Future<void> _createVariantOption(String initialName) async {
    final created = await showCreateVariantOptionDialog(
      context: context,
      catalogRepository: widget.viewModel.catalogRepository,
      existingOptions: _availableVariantOptions,
      initialName: initialName,
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
