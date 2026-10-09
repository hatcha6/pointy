import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/parsing.dart';
import '../../../core/result.dart';
import '../../../data/models/catalog_identity_conflict.dart';
import '../../../data/models/customer_asset.dart';
import '../../../data/models/modifier_group.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_draft.dart';
import '../../../data/models/product_tracking.dart';
import '../../../data/models/product_unit.dart';
import '../../../data/models/product_variant_draft.dart';
import '../../../data/models/tracking_mode.dart';
import '../../../data/models/unit_of_measure.dart';
import '../../../data/models/variant_option.dart';
import '../../../shared/async_selection/async_multi_select_picker.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/keyboard/route_keyboard_shortcuts.dart';
import '../../../shared/product_category_picker.dart';
import '../../../shared/tracking/tracking_features.dart';
import '../view_models/catalog_view_model.dart';
import '../view_models/product_entry_run.dart';
import '../view_models/similar_product.dart';
import '../view_models/variant_generation.dart';
import 'auto_sku_filler.dart';
import 'modifier_group_selector.dart';
import 'opening_stock_fields.dart';
import 'pricing_currency_field.dart';
import 'product_entry_pins.dart';
import 'product_entry_status.dart';
import 'product_essentials_fields.dart';
import 'product_form_actions.dart';
import 'product_form_section.dart';
import 'product_form_shortcuts.dart';
import 'product_generated_variants_step.dart';
import 'product_image_picker.dart';
import 'product_more_details.dart';
import 'product_tracking_fields.dart';
import 'product_units_editor.dart';
import 'variant_generation_fields.dart';
import 'variant_identity_watcher.dart';
import 'variant_gtin_field.dart';
import 'variant_option_creation_dialogs.dart';

/// The new-product form.
///
/// One page for a simple product — barcode, name, price and what a shelf
/// shares first, the rest folded away — and a second step only when the
/// product generates variants. Keyboard-first: Enter walks the essential
/// fields onto the save button, Ctrl+Enter creates, and a scan from any field
/// lands in the barcode.
///
/// Where the caller offers it, «إنشاء وإضافة آخر» saves and starts the next
/// product in the same panel, carrying over whichever fields are pinned — for
/// a shop typing in its whole catalogue, product after product.
class ProductForm extends StatefulWidget {
  const ProductForm({
    super.key,
    required this.viewModel,
    this.onCreated,
    this.offerAddAnother = false,
    this.onCreatedAnother,
    this.onOpenCreated,
    this.initialBarcode,
    this.showOpeningStock = false,
    this.similarTo,
    this.trackingFeatures,
  });

  final CatalogViewModel viewModel;

  /// Called with the freshly created product once a plain create succeeds.
  /// The panel closes on it (see `showProductCreateSurface`).
  final void Function(Product product)? onCreated;

  /// Offers «إنشاء وإضافة آخر», which creates the product and starts the next
  /// one in the same panel instead of calling [onCreated]. Off where the form
  /// was opened for one scanned code: that scan wants its product and no more.
  final bool offerAddAnother;

  /// Called with each product «إنشاء وإضافة آخر» creates, while the panel
  /// stays open for the next — a purchase order puts every one on the order.
  final ValueChanged<Product>? onCreatedAnother;

  /// Opens a product created by «إنشاء وإضافة آخر» — the panel's way back to
  /// the one just saved, to fix it without losing the run.
  final ValueChanged<Product>? onOpenCreated;

  /// Prefills the default variant's barcode — used when the form is opened for
  /// a scanned code that matched no existing product, so the created product
  /// resolves on the next scan. The SKU is numbered like any new product's.
  final String? initialBarcode;

  /// Whether to offer an opening quantity and cost for stock the shop already
  /// has. Off by default, and off in particular when the form is opened from
  /// inside a purchase order: that order is about to bring the stock in at a
  /// cost of its own, and entering it twice would double the shelf.
  ///
  /// The caller passes the caller's own permission — the server checks it
  /// again, since a hidden field is a courtesy and not a control.
  final bool showOpeningStock;

  /// Starts from an existing product — «منتج مشابه»: whatever describes it is
  /// filled in and marked as copied, nothing that identifies it (see
  /// [SimilarProduct]). Nothing is saved until the owner creates it, so a
  /// copy changed their mind about leaves no product behind.
  final Product? similarTo;

  /// Which identified-stock trades the shop has switched on. With either on,
  /// the form offers the whole tracking choice — serial, lots, both — in a
  /// section of its own; with neither, the single expiry switch it always had.
  ///
  /// Read from [TrackingFeaturesScope] when not given; given only by previews
  /// and tests, which have no session to read it from.
  final TrackingFeatures? trackingFeatures;

  @override
  State<ProductForm> createState() => _ProductFormState();
}

/// What the form holds, compared against what it held after opening or after
/// the last «إنشاء وإضافة آخر» — anything different is work an accidental
/// dismiss would lose.
typedef _FormSnapshot = ({
  String text,
  String selections,
  bool hasImage,
  int units,
});

class _ProductFormState extends State<ProductForm> {
  final _detailsFormKey = GlobalKey<FormState>();
  final _variantsFormKey = GlobalKey<FormState>();
  final _skuFieldKey = GlobalKey();
  final _barcodeFieldKey = GlobalKey();
  final _scrollController = ScrollController();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _variantNameController = TextEditingController();
  final _skuController = TextEditingController();
  // Its own controller, not the SKU's: a prefix is a scheme the shop types
  // (SHIRT → SHIRT-RED), and the number filled into the single SKU field is
  // not one — carried over, it would code every variant "1042-RED".
  final _skuPrefixController = TextEditingController();
  final _barcodeController = TextEditingController();

  /// The default variant's GS1 number, offered with the lot policy only. A
  /// code, so like the barcode it is never carried or copied.
  final _gtinController = TextEditingController();
  String? _gtinError;
  final _priceController = TextEditingController();
  final _openingQuantityController = TextEditingController();
  final _openingCostController = TextEditingController();
  final Map<String, TextEditingController> _generatedNameControllers = {};
  final Map<String, TextEditingController> _generatedSkuControllers = {};
  final Map<String, TextEditingController> _generatedBarcodeControllers = {};
  final Map<String, TextEditingController> _generatedPriceControllers = {};
  final Map<String, TextEditingController>
  _generatedOpeningQuantityControllers = {};
  final Map<String, TextEditingController> _generatedOpeningCostControllers =
      {};
  final Map<String, bool> _generatedActiveBySignature = {};

  // The Enter path, and the buttons it ends on.
  final _barcodeFocusNode = FocusNode(debugLabel: 'product_form_barcode');
  final _nameFocusNode = FocusNode(debugLabel: 'product_form_name');
  final _priceFocusNode = FocusNode(debugLabel: 'product_form_price');
  final _openingQuantityFocusNode = FocusNode(
    debugLabel: 'product_form_opening_quantity',
  );
  final _openingCostFocusNode = FocusNode(
    debugLabel: 'product_form_opening_cost',
  );
  final _primaryActionFocusNode = FocusNode(
    debugLabel: 'product_form_primary_action',
  );
  final _addAnotherFocusNode = FocusNode(
    debugLabel: 'product_form_add_another',
  );

  /// One per carried field: whether focus is inside it, for the pin key.
  final Map<ProductCarryField, FocusNode> _pinScopes = {
    for (final field in ProductCarryField.values)
      field: FocusNode(
        debugLabel: 'product_form_pin_scope_${field.name}',
        canRequestFocus: false,
        skipTraversal: true,
      ),
  };

  /// Blank = the shop's own currency, which is every product unless said
  /// otherwise. Holds an ISO code once the owner picks a price-sheet currency.
  String _pricingCurrency = '';
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

  /// How the product's stock is identified. Behind the expiry switch it is
  /// quantity or lots and nothing else.
  var _tracking = const ProductTracking();
  var _features = TrackingFeatures.none;
  var _assetTypesRequested = false;
  List<CustomerAssetType> _assetTypes = [];
  var _isLoadingAssetTypes = false;
  var _assetTypesLoadFailed = false;
  var _unit = 'piece';
  var _isService = false;
  var _isPrepared = false;
  var _isVariantActive = true;
  var _isLoadingVariantOptions = false;
  var _variantOptionsLoadFailed = false;
  var _step = 0;
  var _moreDetailsExpanded = false;
  String? _generationErrorKey;
  var _lastBasePrice = '';
  late final VariantIdentityWatcher _identity;
  late final AutoSkuFiller _autoSku;

  /// Products created back to back in this panel, and what carries over.
  final _run = ProductEntryRun();
  var _pinsHintDismissed = false;

  /// The product a «منتج مشابه» copies. Its variant grid is laid out once the
  /// variant options load, so the rows can be matched to its variants.
  SimilarProduct? _similar;
  var _similarGridApplied = false;

  /// The owner tried to save a name still identical to the previous product's
  /// and was asked to confirm; the next save goes through.
  var _confirmedRepeatedName = false;
  var _lastNameText = '';

  /// The save in flight came from «إنشاء وإضافة آخر».
  var _savingAddAnother = false;

  /// Bumped on each «إنشاء وإضافة آخر», so a sub-form keeping state of its own
  /// (the packaging units) starts over with the product.
  var _entryGeneration = 0;

  /// When the last scan landed. A consumed scan's Enter still reaches the
  /// focused widget, so a button focused at that moment must not take it as a
  /// press.
  DateTime? _lastScanAt;
  late _FormSnapshot _baseline;

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

  /// The barcode, SKU and price on the first page describe the one variant a
  /// simple product has; a product that generates variants gives each row its
  /// own instead.
  bool get _showsSellingFields => !_usesGeneratedVariants;

  /// Opening stock is offered only for products that actually keep stock. A
  /// service has no shelf and a made-to-order dish is assembled when it is
  /// ordered, so the server refuses the pair for both — the form agrees rather
  /// than letting somebody type a number that will be rejected.
  bool get _showsOpeningStock =>
      widget.showOpeningStock && !_isService && !_isPrepared;

  /// The whole tracking choice, in its own section, once the shop identifies
  /// stock at all — or when the product in hand is serial anyway, copied from
  /// one in a shop that has since switched the trade off, so nothing is saved
  /// that the form did not show. Otherwise the expiry switch among the
  /// essentials.
  bool get _showsTrackingSection => _features.any || _tracking.mode.tracksUnits;

  /// What is saved: a product with no shelf — a service, a dish — is never
  /// tracked, whatever was chosen before it became one.
  ProductTracking get _effectiveTracking => _isService || _isPrepared
      ? _tracking.copyWith(mode: TrackingMode.quantity)
      : _tracking;

  bool get _isFinalStep => !_usesGeneratedVariants || _step == 1;

  List<VariantCombination> get _generatedCombinations {
    return generateVariantCombinations(
      options: _selectedVariantOptions,
      selectedValueIdsByOption: _selectedValueIdsByOption,
    );
  }

  String? _defaultGeneratedSignature;

  void _refreshPricePreview() {
    if (_pricingCurrency.isEmpty || !mounted) {
      return;
    }
    setState(() {});
  }

  void _onPricingCurrencyChanged(String code) {
    setState(() {
      _pricingCurrency = code;
      _run.unkeep(ProductCarryField.price);
    });
  }

  @override
  void initState() {
    super.initState();
    final initialBarcode = widget.initialBarcode?.trim() ?? '';
    if (initialBarcode.isNotEmpty) {
      _barcodeController.text = initialBarcode;
    }
    if (widget.similarTo case final source?) {
      _startFromSimilar(SimilarProduct.of(source));
    }
    _lastBasePrice = _priceController.text;
    _nameController.addListener(_onNameChanged);
    _skuPrefixController.addListener(_fillGeneratedSkus);
    _priceController.addListener(_syncGeneratedPricesFromBase);
    // Redraws the conversion preview as the price is typed.
    _priceController.addListener(_refreshPricePreview);
    _priceController.addListener(_onPriceChanged);
    _openingCostController.addListener(_onOpeningCostChanged);
    // Fire-and-forget: the picker stays hidden until (and unless) this lands,
    // so a slow or unreachable rate endpoint never delays the form.
    unawaited(widget.viewModel.loadPricingCurrencies());
    // Watches the single default variant's codes. When the product generates
    // variants instead, these two inputs become a SKU *prefix* and a base
    // price, so the watcher is left idle — see _usesGeneratedVariants.
    _identity = VariantIdentityWatcher(
      catalogRepository: widget.viewModel.catalogRepository,
      skuController: _skuController,
      barcodeController: _barcodeController,
    );
    _autoSku = AutoSkuFiller(widget.viewModel.catalogRepository);
    unawaited(_refreshAutoSkus());
    _loadVariantOptions();
    _loadModifierGroups();
    _loadUnits();
    // A code the form was opened for is the scanner's, not the owner's work:
    // closing such a form unchanged asks nothing.
    _baseline = _snapshot();
    // Scanned in already, the name is next; otherwise the barcode, so the
    // first scan needs no click.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      (initialBarcode.isEmpty ? _barcodeFocusNode : _nameFocusNode)
          .requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _features = widget.trackingFeatures ?? TrackingFeaturesScope.of(context);
    // Only a shop with serial tracking has a «نوع الجهاز» to choose.
    if (_features.serial && !_assetTypesRequested) {
      _assetTypesRequested = true;
      unawaited(_loadAssetTypes());
    }
  }

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
    _nameController.removeListener(_onNameChanged);
    _nameController.dispose();
    _descriptionController.dispose();
    _variantNameController.dispose();
    _skuController.dispose();
    _skuPrefixController.removeListener(_fillGeneratedSkus);
    _skuPrefixController.dispose();
    _barcodeController.dispose();
    _gtinController.dispose();
    _priceController.removeListener(_syncGeneratedPricesFromBase);
    _priceController.removeListener(_refreshPricePreview);
    _priceController.removeListener(_onPriceChanged);
    _priceController.dispose();
    _openingQuantityController.dispose();
    _openingCostController.removeListener(_onOpeningCostChanged);
    _openingCostController.dispose();
    for (final controller in [
      ..._generatedNameControllers.values,
      ..._generatedSkuControllers.values,
      ..._generatedBarcodeControllers.values,
      ..._generatedPriceControllers.values,
      ..._generatedOpeningQuantityControllers.values,
      ..._generatedOpeningCostControllers.values,
    ]) {
      controller.dispose();
    }
    for (final node in [
      _barcodeFocusNode,
      _nameFocusNode,
      _priceFocusNode,
      _openingQuantityFocusNode,
      _openingCostFocusNode,
      _primaryActionFocusNode,
      _addAnotherFocusNode,
      ..._pinScopes.values,
    ]) {
      node.dispose();
    }
    _scrollController.dispose();
    super.dispose();
  }

  /// Redraws on every edit: the image search follows the name, and so does
  /// the warning that the name is still the previous product's.
  ///
  /// The controller also reports a cursor that merely moved — which focusing
  /// the field does on web and desktop — and that is not an edit: it must not
  /// take back a confirmation the owner was just asked for.
  void _onNameChanged() {
    final text = _nameController.text;
    if (!mounted || text == _lastNameText) {
      return;
    }
    _lastNameText = text;
    final previous = _run.previous;
    if (previous != null && text.trim() != previous.name) {
      _run.unkeep(ProductCarryField.name);
    }
    setState(() => _confirmedRepeatedName = false);
  }

  void _onPriceChanged() {
    final previous = _run.previous;
    if (previous != null &&
        _priceController.text.trim() != previous.price &&
        _run.unkeep(ProductCarryField.price) &&
        mounted) {
      setState(() {});
    }
  }

  void _onOpeningCostChanged() {
    final previous = _run.previous;
    if (previous != null &&
        _openingCostController.text.trim() != previous.openingCost &&
        _run.unkeep(ProductCarryField.openingCost) &&
        mounted) {
      setState(() {});
    }
  }

  _FormSnapshot _snapshot() {
    return (
      text: [
        _nameController.text.trim(),
        _descriptionController.text.trim(),
        _variantNameController.text.trim(),
        // The number the form filled in is not the user's work.
        _autoSku.holdsFilledValue(_skuController)
            ? ''
            : _skuController.text.trim(),
        _skuPrefixController.text.trim(),
        _barcodeController.text.trim(),
        _gtinController.text.trim(),
        _priceController.text.trim(),
        _openingQuantityController.text.trim(),
        _openingCostController.text.trim(),
        _pricingCurrency,
        _unit,
      ].join('\u0000'),
      selections: [
        for (final category in _selectedCategories) 'c${category.id}',
        for (final id in _selectedVariantOptionIds) 'o$id',
        for (final id in _selectedModifierGroupIds) 'm$id',
        't${_tracking.toJson()}',
        's$_isService',
        'p$_isPrepared',
        'a$_isProductActive$_isVariantActive',
      ].join(','),
      hasImage: _selectedImage != null,
      units: _units.length,
    );
  }

  /// Any entry the user would lose on an accidental dismiss. Used by the
  /// unsaved-changes guard (evaluated fresh on each back/dismiss attempt).
  bool get _isDirty => _snapshot() != _baseline;

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
        final isSaving = widget.viewModel.isSaving;
        return RouteKeyboardShortcuts(
          enabled: !isSaving,
          bindings: _shortcutBindings(),
          child: BarcodeScanListener(
            enabled: !isSaving,
            onBarcodeScanned: _onBarcodeScanned,
            child: Material(
              color: context.pointyColors.surface,
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHeader(context, l10n),
                          const SizedBox(height: 16),
                          if (_showsPins && !_pinsHintDismissed) ...[
                            ProductEntryPinsHint(
                              onDismiss: () =>
                                  setState(() => _pinsHintDismissed = true),
                            ),
                            const SizedBox(height: 12),
                          ],
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            child: _step == 0
                                ? _buildDetailsPage(context, l10n)
                                : _buildVariantsPage(context, l10n),
                          ),
                          if (widget.viewModel.errorMessage ==
                              'catalog_create_error') ...[
                            const SizedBox(height: 8),
                            Text(
                              // With a known field conflict the offending
                              // input is already marked — point at it instead
                              // of repeating a generic "could not create".
                              _hasFieldConflict
                                  ? l10n.formFixHighlightedFieldsError
                                  : l10n.productCreateError,
                              style: TextStyle(
                                color: context.pointyColors.danger,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  _buildFooter(context, l10n),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, AppLocalizations l10n) {
    return Column(
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
            if (_run.createdCount > 0) ...[
              ProductEntryCountPill(count: _run.createdCount),
              const SizedBox(width: 8),
            ],
            if (_usesGeneratedVariants)
              Text(l10n.productWizardStepLabel(_step + 1, 2)),
            if (_showsShortcutHints(context))
              IconButton(
                tooltip: l10n.productFormShortcutsTooltip,
                onPressed: () => showProductFormShortcutsSheet(
                  context,
                  offersAddAnother: widget.offerAddAnother,
                ),
                icon: const Icon(Icons.keyboard_outlined),
              ),
          ],
        ),
        if (_usesGeneratedVariants) ...[
          const SizedBox(height: 10),
          PointyProgressBar(value: _step == 0 ? 0.5 : 1),
        ],
        if (_similar case final similar? when _run.copiesProduct) ...[
          const SizedBox(height: 10),
          PointyInlineMessage(
            message: l10n.similarProductNotice(similar.sourceName),
            icon: Icons.copy_all_outlined,
          ),
        ],
      ],
    );
  }

  /// Pins arrive with the first «إنشاء وإضافة آخر», when there is a next
  /// product for them to keep a value for. Until then a «منتج مشابه» only
  /// marks what it copied.
  bool get _showsPins => _run.createdCount > 0;

  Widget _buildDetailsPage(BuildContext context, AppLocalizations l10n) {
    final isSaving = widget.viewModel.isSaving;
    final copies = _run.copiesProduct;
    final pins = <ProductCarryField, FieldPin>{
      if (_run.hasStarted)
        for (final field in ProductCarryField.values)
          field: FieldPin(
            pinned: _run.isPinned(field),
            kept: _run.isKept(field),
            onToggle: _showsPins ? () => _togglePin(field) : null,
            keptLabel: copies ? l10n.productFieldCopiedLabel : null,
          ),
    };
    return Form(
      key: _detailsFormKey,
      child: Column(
        key: const ValueKey('product_details_page'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProductFormSection(
            icon: Icons.inventory_2_outlined,
            title: l10n.parentProductStepTitle,
            children: [
              ProductEssentialsFields(
                showsSellingFields: _showsSellingFields,
                barcodeController: _barcodeController,
                barcodeFocusNode: _barcodeFocusNode,
                barcodeFieldKey: _barcodeFieldKey,
                barcodeState: _identity.barcodeState,
                skuController: _skuController,
                skuFieldKey: _skuFieldKey,
                skuState: _identity.skuState,
                skuIsAutomatic: _autoSku.holdsFilledValue(_skuController),
                nameController: _nameController,
                nameFocusNode: _nameFocusNode,
                priceController: _priceController,
                priceFocusNode: _priceFocusNode,
                selectedCategories: _selectedCategories,
                onPickCategories: _pickCategories,
                onClearCategories: () => _setCategories(const []),
                unit: _unit,
                onUnitChanged: (value) => setState(() {
                  _unit = value;
                  _run.unkeep(ProductCarryField.unit);
                }),
                tracksExpiry: _tracking.mode.tracksLots,
                // With the tracking section shown, the switch would be a
                // second control over the same choice.
                onTracksExpiryChanged: _showsTrackingSection
                    ? null
                    : (value) => _setTracking(
                        _tracking.copyWith(
                          mode: value
                              ? TrackingMode.batch
                              : TrackingMode.quantity,
                          // «يتابع تاريخ الانتهاء» says the date is owed at
                          // receiving — what the switch always meant.
                          expiryRequired: value,
                        ),
                      ),
                onEnter: _advanceFrom,
                requiredValidator: (value) =>
                    _requiredValidator(context, value),
                numberValidator: (value) => _numberValidator(context, value),
                pricingCurrencyField: widget.viewModel.pricingCurrencies.isEmpty
                    ? null
                    : PricingCurrencyField(
                        currencies: widget.viewModel.pricingCurrencies,
                        baseCurrencyCode: widget.viewModel.baseCurrencyCode,
                        selectedCode: _pricingCurrency,
                        onChanged: _onPricingCurrencyChanged,
                        rate: _pricingCurrency.isEmpty
                            ? null
                            : widget.viewModel.rateFor(_pricingCurrency),
                        enteredAmount: _parseNumber(_priceController.text),
                      ),
                pins: pins,
                pinScopes: _pinScopes,
                nameWarning: !_run.repeatsPreviousName(_nameController.text)
                    ? null
                    : copies
                    ? l10n.similarProductNameUnchangedWarning
                    : l10n.productNameUnchangedWarning,
              ),
            ],
          ),
          if (_showsTrackingSection) ...[
            const SizedBox(height: 20),
            ProductFormSection(
              icon: Icons.qr_code_scanner_outlined,
              title: l10n.productTrackingSectionTitle,
              children: [
                PinnableField(
                  pin: pins[ProductCarryField.tracksExpiry],
                  focusScope: _pinScopes[ProductCarryField.tracksExpiry],
                  child: ProductTrackingFields(
                    key: ValueKey('product_tracking_$_entryGeneration'),
                    value: _tracking,
                    onChanged: _setTracking,
                    features: _features,
                    assetTypes: _assetTypes,
                    assetTypesLoading: _isLoadingAssetTypes,
                    assetTypesFailed: _assetTypesLoadFailed,
                    onReloadAssetTypes: _loadAssetTypes,
                    doesNotKeepStock: _isService || _isPrepared,
                    enabled: !isSaving,
                    // One variant's number: a product generating several
                    // gives each its own from the variant editor instead.
                    gtinField: _showsSellingFields
                        ? VariantGtinField(
                            controller: _gtinController,
                            errorText: _gtinError,
                            enabled: !isSaving,
                            onChanged: (_) {
                              if (_gtinError != null) {
                                setState(() => _gtinError = null);
                              }
                            },
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ],
          if (_showsOpeningStock && _showsSellingFields) ...[
            const SizedBox(height: 20),
            ProductFormSection(
              icon: Icons.play_circle_outline,
              title: l10n.openingStockSectionTitle,
              children: [
                if (_effectiveTracking.mode.isTracked) ...[
                  PointyInlineMessage(
                    key: const ValueKey('product_opening_stock_tracked_hint'),
                    message: _effectiveTracking.mode.tracksUnits
                        ? l10n.productTrackingOpeningUnitsHint
                        : l10n.productTrackingOpeningLotsHint,
                    icon: Icons.info_outline,
                    compact: true,
                  ),
                  const SizedBox(height: 12),
                ],
                OpeningStockFields(
                  key: const ValueKey('product_opening_stock'),
                  quantityController: _openingQuantityController,
                  costController: _openingCostController,
                  quantityFocusNode: _openingQuantityFocusNode,
                  costFocusNode: _openingCostFocusNode,
                  onQuantityEditingComplete: () =>
                      _advanceFrom(_openingQuantityFocusNode),
                  onCostEditingComplete: () =>
                      _advanceFrom(_openingCostFocusNode),
                  costPin: pins[ProductCarryField.openingCost],
                  costPinScope: _pinScopes[ProductCarryField.openingCost],
                ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          ProductMoreDetails(
            expanded: _moreDetailsExpanded,
            onToggle: () =>
                setState(() => _moreDetailsExpanded = !_moreDetailsExpanded),
            children: [
              TextFormField(
                controller: _descriptionController,
                minLines: 2,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: l10n.descriptionLabel,
                  hintText: l10n.descriptionHint,
                  prefixIcon: const Icon(Icons.notes_outlined),
                ),
              ),
              const SizedBox(height: 12),
              if (_showsSellingFields) ...[
                TextFormField(
                  controller: _variantNameController,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: l10n.variantNameLabel,
                    hintText: l10n.variantNameHint,
                    prefixIcon: const Icon(Icons.tune_outlined),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              ProductImageField(
                catalogRepository: widget.viewModel.catalogRepository,
                initialSearchQuery: _nameController.text.trim(),
                selection: _selectedImage,
                onChanged: (selection) =>
                    setState(() => _selectedImage = selection),
                enabled: !isSaving,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.activeProductLabel),
                value: _isProductActive,
                onChanged: (value) => setState(() => _isProductActive = value),
              ),
              if (_showsSellingFields)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.activeVariantLabel),
                  value: _isVariantActive,
                  onChanged: (value) =>
                      setState(() => _isVariantActive = value),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.productIsPreparedTitle),
                subtitle: Text(l10n.productIsPreparedDescription),
                value: _isPrepared,
                onChanged: (value) => setState(() => _isPrepared = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.productIsServiceTitle),
                subtitle: Text(l10n.productIsServiceDescription),
                value: _isService,
                onChanged: (value) => setState(() => _isService = value),
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
          const SizedBox(height: 16),
          VariantOptionField(
            availableOptions: _availableVariantOptions,
            selectedOptions: _selectedVariantOptions,
            isLoading: _isLoadingVariantOptions,
            hasError: _variantOptionsLoadFailed,
            onReload: _loadVariantOptions,
            onToggleOption: _toggleVariantOption,
            onCreateOption: _createVariantOption,
          ),
          const SizedBox(height: 20),
          ProductFormSection(
            icon: Icons.straighten_outlined,
            title: l10n.productUnitsSectionTitle,
            children: [
              ProductUnitsEditor(
                // Holds rows of its own; a new product starts with none.
                key: ValueKey('product_units_$_entryGeneration'),
                availableUnits: _availableUnits,
                baseUnitCode: _unit,
                units: _units,
                defaultSaleUnit: _defaultSaleUnit,
                defaultPurchaseUnit: _defaultPurchaseUnit,
                enabled: !isSaving,
                isLoading: _isLoadingUnits,
                hasError: _unitsLoadFailed,
                onReload: _loadUnits,
                onUnitsChanged: (units) => setState(() => _units = units),
                onDefaultSaleChanged: (code) =>
                    setState(() => _defaultSaleUnit = code),
                onDefaultPurchaseChanged: (code) =>
                    setState(() => _defaultPurchaseUnit = code),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVariantsPage(BuildContext context, AppLocalizations l10n) {
    return Form(
      key: _variantsFormKey,
      child: Column(
        key: const ValueKey('product_variants_page'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProductFormSection(
            icon: Icons.qr_code_2,
            title: l10n.defaultVariantStepTitle,
            children: [
              ProductGeneratedVariantsStep(
                skuController: _skuPrefixController,
                priceController: _priceController,
                selectedOptions: _selectedVariantOptions,
                selectedValueIdsByOption: _selectedValueIdsByOption,
                errorOptionIds: _valueErrorOptionIds,
                combinations: _generatedCombinations,
                nameControllers: _generatedNameControllers,
                skuControllers: _generatedSkuControllers,
                barcodeControllers: _generatedBarcodeControllers,
                priceControllers: _generatedPriceControllers,
                activeBySignature: _generatedActiveBySignature,
                defaultSignature: _defaultGeneratedSignature,
                onToggleValue: _toggleOptionValue,
                onCreateValue: _createVariantOptionValue,
                onSelectAllValues: _selectAllVariantOptionValues,
                onDefaultChanged: (signature) =>
                    setState(() => _defaultGeneratedSignature = signature),
                onVariantActiveChanged: (signature, value) => setState(
                  () => _generatedActiveBySignature[signature] = value,
                ),
                numberValidator: (value) => _numberValidator(context, value),
                generationErrorText: _generationErrorText(context),
                conflictsBySignature: _generatedConflicts,
                openingQuantityControllers: _showsOpeningStock
                    ? _generatedOpeningQuantityControllers
                    : null,
                openingCostControllers: _showsOpeningStock
                    ? _generatedOpeningCostControllers
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context, AppLocalizations l10n) {
    final lastCreated = _run.lastCreated;
    final Widget? status = _confirmedRepeatedName
        ? PointyInlineMessage.warning(
            message: _run.copiesProduct
                ? l10n.similarProductNameUnchangedConfirm
                : l10n.productNameUnchangedConfirm,
            compact: true,
          )
        : lastCreated == null
        ? null
        : ProductEntryLastCreated(
            name: lastCreated.name,
            imageFailed: _run.lastCreatedImageFailed,
            onEdit: widget.onOpenCreated == null ? null : _openLastCreated,
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (status != null) ...[status, const SizedBox(height: 10)],
          ProductFormActions(
            isSaving: widget.viewModel.isSaving,
            isFinalStep: _isFinalStep,
            primaryFocusNode: _primaryActionFocusNode,
            onPrimary: () => _onActionPressed(addAnother: false),
            showShortcutHints: _showsShortcutHints(context),
            savingAddAnother: _savingAddAnother,
            onBack: _step > 0 ? () => setState(() => _step = 0) : null,
            addAnotherFocusNode: _addAnotherFocusNode,
            onAddAnother: widget.offerAddAnother
                ? () => _onActionPressed(addAnother: true)
                : null,
          ),
        ],
      ),
    );
  }

  /// Shortcut hints are for a machine with a keyboard; a phone has none.
  bool _showsShortcutHints(BuildContext context) {
    return switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      _ => false,
    };
  }

  Map<ShortcutActivator, bool Function()> _shortcutBindings() {
    bool create() {
      unawaited(_submit(addAnother: false));
      return true;
    }

    bool createAnother() {
      unawaited(_submit(addAnother: widget.offerAddAnother));
      return true;
    }

    return {
      for (final enter in const [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
      ]) ...{
        SingleActivator(enter, control: true, shift: true): createAnother,
        SingleActivator(enter, meta: true, shift: true): createAnother,
        SingleActivator(enter, control: true): create,
        SingleActivator(enter, meta: true): create,
      },
      // F8 is the counter camera's preview, anywhere in the app.
      const SingleActivator(LogicalKeyboardKey.f7): _togglePinOfFocusedField,
    };
  }

  /// Enter in an essential field: on to the next one, and from the last onto
  /// the button a run of products presses — never through the category,
  /// unit or switches, which Tab still visits.
  void _advanceFrom(FocusNode node) {
    final path = [
      if (_showsSellingFields) _barcodeFocusNode,
      _nameFocusNode,
      if (_showsSellingFields) _priceFocusNode,
      if (_showsSellingFields && _showsOpeningStock) ...[
        _openingQuantityFocusNode,
        _openingCostFocusNode,
      ],
    ];
    final index = path.indexOf(node);
    if (index >= 0 && index < path.length - 1) {
      path[index + 1].requestFocus();
      return;
    }
    (widget.offerAddAnother && _isFinalStep
            ? _addAnotherFocusNode
            : _primaryActionFocusNode)
        .requestFocus();
  }

  /// A scan typed into any field of the first page goes to the barcode, and
  /// the field it landed in is put back as it was (the listener does that).
  /// Whoever was typing elsewhere keeps their place; from the barcode itself,
  /// or from nowhere, the name is next.
  void _onBarcodeScanned(String code) {
    _lastScanAt = DateTime.now();
    if (!_showsSellingFields || _step != 0) {
      // Each generated row holds its own barcode, scanned into that row.
      return;
    }
    final focus = FocusManager.instance.primaryFocus;
    final typingElsewhere =
        focus != null && focus != _barcodeFocusNode && _isTextField(focus);
    _barcodeController.text = code;
    if (!typingElsewhere) {
      _nameFocusNode.requestFocus();
    }
  }

  static bool _isTextField(FocusNode node) {
    final context = node.context;
    if (context == null) {
      return false;
    }
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool get _scanJustLanded {
    final lastScanAt = _lastScanAt;
    return lastScanAt != null &&
        DateTime.now().difference(lastScanAt) <
            const Duration(milliseconds: 300);
  }

  void _onActionPressed({required bool addAnother}) {
    // The Enter ending a scan reaches a focused button even after the
    // listener consumed it; that is not somebody pressing it.
    if (_scanJustLanded) {
      return;
    }
    unawaited(_submit(addAnother: addAnother));
  }

  void _openLastCreated() {
    final product = _run.lastCreated;
    if (product == null || _scanJustLanded) {
      return;
    }
    widget.onOpenCreated?.call(product);
  }

  void _continueToVariant() {
    final isValid = _detailsFormKey.currentState?.validate() ?? false;
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

  Future<void> _submit({required bool addAnother}) async {
    if (widget.viewModel.isSaving) {
      return;
    }
    if (!_isFinalStep) {
      _continueToVariant();
      return;
    }
    final continueAdding = addAnother && widget.offerAddAnother;
    final l10n = AppLocalizations.of(context)!;
    // The number filled in when the form opened may have gone to another till
    // since; an untouched field moves to the next free one before it is sent.
    await _refreshAutoSkus();
    if (!mounted) {
      return;
    }
    // Settle a code typed in the last few hundred milliseconds before the form
    // decides whether it is valid.
    await _identity.refresh();
    if (!mounted) {
      return;
    }
    final formKey = _usesGeneratedVariants ? _variantsFormKey : _detailsFormKey;
    final isValid = formKey.currentState?.validate() ?? false;
    if (!isValid) {
      _scrollToFirstConflict();
      return;
    }

    _syncGeneratedVariantControllers();
    if (_usesGeneratedVariants && !_validateGeneratedVariants()) {
      return;
    }

    // A name carried over and never edited gives two products the same name.
    // Said once; saving again means it was meant.
    if (_run.repeatsPreviousName(_nameController.text) &&
        !_confirmedRepeatedName) {
      setState(() => _confirmedRepeatedName = true);
      if (_step == 0) {
        _nameFocusNode.requestFocus();
      }
      return;
    }

    final enteredPrice = _parseNumber(_priceController.text)!;
    // With a pricing currency set, what the owner typed IS the foreign price.
    // It is sent as `price_amount` and the server derives the base price at the
    // rate it resolves — the client never computes a stored price itself, so
    // there is exactly one place the conversion happens.
    final isForeignPriced = _pricingCurrency.isNotEmpty;
    final unitPrice = isForeignPriced ? 0.0 : enteredPrice;
    final foreignPrice = isForeignPriced ? enteredPrice : null;
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
                unitPrice: isForeignPriced
                    ? 0
                    : _parseNumber(
                        _generatedPriceControllers[combination.signature]!.text,
                      )!,
                priceAmount: isForeignPriced
                    ? _parseNumber(
                        _generatedPriceControllers[combination.signature]!.text,
                      )
                    : null,
                isActive:
                    _generatedActiveBySignature[combination.signature] ?? true,
                isDefault: combination.signature == _defaultGeneratedSignature,
                optionValueIds: combination.valueIds,
                openingQuantity: _showsOpeningStock
                    ? _parseNumber(
                        _generatedOpeningQuantityControllers[combination
                                .signature]
                            ?.text,
                      )
                    : null,
                openingUnitCost: _showsOpeningStock
                    ? _parseNumber(
                        _generatedOpeningCostControllers[combination.signature]
                            ?.text,
                      )
                    : null,
              ),
          ]
        : const <ProductVariantDraft>[];

    final tracking = _effectiveTracking;
    final draft = ProductDraft(
      name: _nameController.text.trim(),
      description: _descriptionController.text.trim(),
      isActive: _isProductActive,
      tracksExpiry: tracking.mode.tracksLots,
      tracking: tracking,
      unit: _unit,
      defaultSaleUnit: _defaultSaleUnit,
      defaultPurchaseUnit: _defaultPurchaseUnit,
      units: _units,
      isService: _isService,
      isPrepared: _isPrepared,
      variantName: _variantNameController.text.trim(),
      variantSku: _skuController.text.trim(),
      variantBarcode: _barcodeController.text.trim(),
      // Sent only where the field is shown, so a product that is not
      // lot-tracked never writes one.
      variantGtin: _showsSellingFields && tracking.mode.tracksLots
          ? gtinFieldValue(_gtinController.text)
          : null,
      variantUnitPrice: unitPrice,
      pricingCurrency: _pricingCurrency,
      variantPriceAmount: foreignPrice,
      variantOptionIds: [
        for (final option in _selectedVariantOptions) option.id,
      ],
      modifierGroupIds: _selectedModifierGroupIds.toList(),
      categoryIds: [for (final category in _selectedCategories) category.id],
      variants: generatedVariants,
      openingQuantity: _showsOpeningStock
          ? _parseNumber(_openingQuantityController.text)
          : null,
      openingUnitCost: _showsOpeningStock
          ? _parseNumber(_openingCostController.text)
          : null,
    );

    final imageSelection = _selectedImage;
    setState(() => _savingAddAnother = continueAdding);
    final result = await widget.viewModel.createProduct(
      draft,
      imageUpload: imageSelection?.upload,
      imageImportToken: imageSelection?.importToken,
      // The next product should not wait on the catalogue list redrawing.
      waitForListRefresh: !continueAdding,
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
    if (createdProduct == null) {
      return;
    }
    final imageFailed =
        result.outcome == ProductCreateOutcome.createdWithImageError;
    if (continueAdding) {
      widget.onCreatedAnother?.call(createdProduct);
      _startNextProduct(createdProduct, imageFailed: imageFailed);
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            imageFailed
                ? l10n.productCreatedImageAttachError
                : l10n.productCreatedMessage,
          ),
        ),
      );
    widget.onCreated?.call(createdProduct);
  }

  /// After «إنشاء وإضافة آخر»: the panel stays, the product just created is
  /// named in it, and the form starts the next one — pinned fields carried
  /// over and marked as the previous product's, everything else as a fresh
  /// form has it.
  void _startNextProduct(Product created, {required bool imageFailed}) {
    final carried = ProductCarryOverValues(
      name: _nameController.text.trim(),
      price: _priceController.text.trim(),
      pricingCurrency: _pricingCurrency,
      categories: List.of(_selectedCategories),
      unit: _unit,
      tracksExpiry: _tracking.mode.tracksLots,
      tracking: _tracking,
      openingCost: _openingCostController.text.trim(),
    );
    _run.recordCreated(created, carried, imageFailed: imageFailed);
    bool carries(ProductCarryField field) => _run.isPinned(field);

    _setText(
      _nameController,
      carries(ProductCarryField.name) ? carried.name : '',
    );
    _setText(
      _priceController,
      carries(ProductCarryField.price) ? carried.price : '',
    );
    _setText(
      _openingCostController,
      carries(ProductCarryField.openingCost) ? carried.openingCost : '',
    );
    // Codes belong to one product, a picture to one product, and a shelf is
    // counted rather than copied — none of these ever carry.
    _barcodeController.clear();
    _gtinController.clear();
    _gtinError = null;
    _skuController.clear();
    _skuPrefixController.clear();
    _variantNameController.clear();
    _descriptionController.clear();
    _openingQuantityController.clear();

    setState(() {
      _pricingCurrency = carries(ProductCarryField.price)
          ? carried.pricingCurrency
          : '';
      _selectedCategories = carries(ProductCarryField.category)
          ? List.of(carried.categories)
          : [];
      _unit = carries(ProductCarryField.unit) ? carried.unit : 'piece';
      _tracking = carries(ProductCarryField.tracksExpiry)
          ? carried.tracking
          : const ProductTracking();
      _selectedImage = null;
      _isProductActive = true;
      _isVariantActive = true;
      _isService = false;
      _isPrepared = false;
      _selectedVariantOptionIds.clear();
      _selectedValueIdsByOption.clear();
      _valueErrorOptionIds = {};
      _generationErrorKey = null;
      _selectedModifierGroupIds.clear();
      _units = [];
      _defaultSaleUnit = '';
      _defaultPurchaseUnit = '';
      _step = 0;
      _entryGeneration += 1;
      _confirmedRepeatedName = false;
      _savingAddAnother = false;
      _syncGeneratedVariantControllers();
      _syncIdentityWatcher();
      _lastBasePrice = _priceController.text;
    });
    _baseline = _snapshot();
    unawaited(_refreshAutoSkus());
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _barcodeFocusNode.requestFocus();
      }
    });
  }

  /// «منتج مشابه»: the form opens on [similar]'s values, each marked as
  /// copied, and the run starts from it — so the unchanged-name check holds
  /// the new name against the product being copied.
  void _startFromSimilar(SimilarProduct similar) {
    _similar = similar;
    final carried = similar.carried;
    _run.startFrom(carried);
    _setText(_nameController, carried.name);
    _lastNameText = carried.name;
    _setText(_priceController, carried.price);
    _pricingCurrency = carried.pricingCurrency;
    _selectedCategories = List.of(carried.categories);
    _unit = carried.unit;
    _tracking = carried.tracking;
    _descriptionController.text = similar.description;
    _isService = similar.isService;
    _isPrepared = similar.isPrepared;
    _selectedModifierGroupIds.addAll(similar.modifierGroupIds);
    _units = similar.units;
    _defaultSaleUnit = similar.defaultSaleUnit;
    _defaultPurchaseUnit = similar.defaultPurchaseUnit;
    _moreDetailsExpanded = similar.fillsMoreDetails;
    // Laid out as rows once the options load: _applySimilarGrid.
    _selectedVariantOptionIds.addAll(similar.variantOptionIds);
    for (final MapEntry(key: optionId, value: valueIds)
        in similar.valueIdsByOption.entries) {
      _selectedValueIdsByOption[optionId] = {...valueIds};
    }
  }

  /// The copied product's grid, once its options are known: the same values
  /// where they are still on offer, and each row priced and switched on or off
  /// as the copied product's variant was. A row it never had starts switched
  /// off — the grid is every combination of the values, and only the owner
  /// knows whether this product comes in one the original did not.
  void _applySimilarGrid() {
    final similar = _similar;
    if (similar == null ||
        !similar.hasVariantGrid ||
        _similarGridApplied ||
        !_run.copiesProduct) {
      return;
    }
    _similarGridApplied = true;
    // Whatever arrives with the options is the copy, not the owner's work.
    final untouched = !_isDirty;
    for (final optionId in similar.variantOptionIds) {
      final option = _availableVariantOptions
          .where((option) => option.id == optionId)
          .firstOrNull;
      final offered = {
        if (option != null)
          for (final value in option.values)
            if (value.isActive) value.id,
      };
      final values = similar.valueIdsByOption[optionId]!.intersection(offered);
      if (values.isEmpty) {
        // Switched off, or every value it used retired, since the original
        // was made: not offered to the copy.
        _selectedVariantOptionIds.remove(optionId);
        _selectedValueIdsByOption.remove(optionId);
      } else {
        _selectedValueIdsByOption[optionId] = values;
      }
    }
    _syncGeneratedVariantControllers();
    final combinations = _generatedCombinations;
    for (final combination in combinations) {
      final row = similar.rowsBySignature[combination.signature];
      _generatedActiveBySignature[combination.signature] =
          row?.isActive ?? false;
      if (row != null && row.price.isNotEmpty) {
        _generatedPriceControllers[combination.signature]?.text = row.price;
      }
    }
    final defaultSignature = similar.defaultSignature;
    if (combinations.any((row) => row.signature == defaultSignature)) {
      _defaultGeneratedSignature = defaultSignature;
    }
    _syncIdentityWatcher();
    if (untouched) {
      _baseline = _snapshot();
    }
  }

  /// Writes [text] with the cursor after it, so a carried name is edited from
  /// its end — Ctrl+Backspace takes off the last word.
  static void _setText(TextEditingController controller, String text) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Pins or unpins [field]. Pinning a field that is still fresh brings back
  /// the previous product's value, so the choice can be made after the save.
  void _togglePin(ProductCarryField field) {
    final previous = _run.previous;
    if (previous == null) {
      return;
    }
    if (_run.togglePin(field) && _holdsFreshValue(field)) {
      _restoreCarried(field, previous);
      _run.markKept(field);
    }
    setState(() {});
  }

  /// F7: the pin of whichever field holds focus.
  bool _togglePinOfFocusedField() {
    if (!_showsPins) {
      return false;
    }
    for (final MapEntry(key: field, value: scope) in _pinScopes.entries) {
      if (scope.hasFocus) {
        _togglePin(field);
        return true;
      }
    }
    return false;
  }

  /// Whether [field] still shows what a fresh form starts with.
  bool _holdsFreshValue(ProductCarryField field) {
    return switch (field) {
      ProductCarryField.name => _nameController.text.trim().isEmpty,
      ProductCarryField.price => _priceController.text.trim().isEmpty,
      ProductCarryField.category => _selectedCategories.isEmpty,
      ProductCarryField.unit => _unit == 'piece',
      ProductCarryField.tracksExpiry => _tracking == const ProductTracking(),
      ProductCarryField.openingCost =>
        _openingCostController.text.trim().isEmpty,
    };
  }

  void _restoreCarried(
    ProductCarryField field,
    ProductCarryOverValues previous,
  ) {
    switch (field) {
      case ProductCarryField.name:
        _setText(_nameController, previous.name);
      case ProductCarryField.price:
        _setText(_priceController, previous.price);
        _pricingCurrency = previous.pricingCurrency;
      case ProductCarryField.category:
        _selectedCategories = List.of(previous.categories);
      case ProductCarryField.unit:
        _unit = previous.unit;
      case ProductCarryField.tracksExpiry:
        _tracking = previous.tracking;
      case ProductCarryField.openingCost:
        _setText(_openingCostController, previous.openingCost);
    }
  }

  void _setTracking(ProductTracking tracking) {
    setState(() {
      _tracking = tracking;
      _run.unkeep(ProductCarryField.tracksExpiry);
    });
  }

  void _setCategories(List<AsyncSelectionOption<int>> categories) {
    setState(() {
      _selectedCategories = categories;
      _run.unkeep(ProductCarryField.category);
    });
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

    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _savingAddAnother = false;
      _gtinError = gtinConflictText(l10n, single);
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
          _applySimilarGrid();
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
        // No values are chosen for the user: adding "colour" used to select
        // all sixteen of them, and a second option turned one tap into a
        // couple of hundred generated variants nobody asked for.
        _selectedValueIdsByOption[option.id] = const {};
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
        _autoSku.forget(entry.value);
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
    for (final map in [
      _generatedOpeningQuantityControllers,
      _generatedOpeningCostControllers,
    ]) {
      for (final entry in [...map.entries]) {
        if (!signatures.contains(entry.key)) {
          entry.value.dispose();
          map.remove(entry.key);
        }
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
      _generatedOpeningQuantityControllers.putIfAbsent(
        combination.signature,
        // Blank, not copied from the single-variant field: a shop holding six
        // sizes holds a different number of each, and a prefilled quantity is
        // the one default that would be wrong on every row.
        TextEditingController.new,
      );
      _generatedOpeningCostControllers.putIfAbsent(
        combination.signature,
        () => TextEditingController(text: _openingCostController.text),
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
    _fillGeneratedSkus();
  }

  /// Asks which number the next new variant gets, and writes it into every SKU
  /// field the user has not typed in.
  Future<void> _refreshAutoSkus() async {
    await _autoSku.refresh();
    if (!mounted) {
      return;
    }
    _autoSku.fill(
      _skuController,
      _autoSku.numberAt(0),
      barcode: _barcodeController,
    );
    _fillGeneratedSkus();
  }

  /// Codes every generated row the user has not typed a SKU into: from the
  /// prefix when the shop keeps a scheme (SHIRT-RED), otherwise with a number
  /// of its own, counting up from the next one.
  void _fillGeneratedSkus() {
    final prefix = _skuPrefixController.text;
    for (final (index, combination) in _generatedCombinations.indexed) {
      final controller = _generatedSkuControllers[combination.signature];
      if (controller == null) {
        continue;
      }
      _autoSku.fill(
        controller,
        prefix.trim().isEmpty
            ? _autoSku.numberAt(index)
            : combination.skuFromBase(prefix),
        barcode: _generatedBarcodeControllers[combination.signature],
      );
    }
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
      // The two codes a generated row has; a GTIN is set per variant later.
      for (final field in const [
        CatalogIdentityField.sku,
        CatalogIdentityField.barcode,
      ]) {
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
      _selectedValueIdsByOption[created.id] = const {};
      _generationErrorKey = null;
      _syncGeneratedVariantControllers();
      _syncIdentityWatcher();
    });
  }

  void _selectAllVariantOptionValues(VariantOption option) {
    setState(() {
      _selectedValueIdsByOption[option.id] = {
        for (final value in option.values)
          if (value.isActive) value.id,
      };
      _valueErrorOptionIds = {..._valueErrorOptionIds}..remove(option.id);
      _generationErrorKey = null;
      _syncGeneratedVariantControllers();
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
    _setCategories(picked);
  }
}
