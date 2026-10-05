import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../core/result.dart';
import '../../../data/models/warehouse.dart';
import '../../../data/repositories/warehouse_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../data/repositories/tracked_stock_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/barcode/scan_feedback_sounds.dart';
import '../../../shared/keyboard/route_keyboard_shortcuts.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/components/components.dart';
import '../../ai/views/smart_reorder_action.dart';
import '../view_models/catalog_view_model.dart';
import '../view_models/product_details_view_model.dart';
import '../view_models/scale_rules_view_model.dart';
import '../view_models/units_management_view_model.dart';
import 'product_details_screen.dart';
import 'product_form.dart';
import 'product_list.dart';
import 'scale_rules_screen.dart';
import 'units_management_screen.dart';
import 'unit_search_slot.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.viewModel,
    required this.inventoryRepository,
    required this.printingRepository,
    required this.purchaseRepository,
    this.warehouseRepository,
    required this.saleRepository,
    required this.shopSettingsRepository,
    this.contactRepository,
    required this.navigation,
    required this.capabilities,
    this.analyticsEngine,
    this.onOpenSearchMisses,
    this.trackedStockRepository,
    this.onOpenStockUnit,
    this.onOpenRecord,
  });

  final CatalogViewModel viewModel;

  /// For a tracked product's page: its articles and lots.
  final TrackedStockRepository? trackedStockRepository;
  final InventoryRepository inventoryRepository;
  final PrintingRepository printingRepository;
  final PurchaseRepository purchaseRepository;

  /// Optional: without it the stock panel simply shows the total and no
  /// per-place breakdown, which is the right answer for a shop with one
  /// place anyway.
  final WarehouseRepository? warehouseRepository;
  final SaleRepository saleRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final ContactRepository? contactRepository;
  final AppNavigation navigation;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;

  /// Opens the words searched for and not found. Null hides the button: for
  /// someone who may not change products, or where nothing can open it.
  final VoidCallback? onOpenSearchMisses;

  /// Opens one article's page — where an IMEI typed into the search lands.
  /// Null (a test, a preview) leaves the search a product search.
  final void Function(BuildContext context, StockUnit unit)? onOpenStockUnit;

  /// Opens a record by kind and id (`order`, `customer`), through the shell's
  /// own capability-gated deep links; false when it could not.
  final Future<bool> Function(BuildContext context, String type, int id)?
  onOpenRecord;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  CatalogViewModel get viewModel => widget.viewModel;
  InventoryRepository get inventoryRepository => widget.inventoryRepository;
  PrintingRepository get printingRepository => widget.printingRepository;
  PurchaseRepository get purchaseRepository => widget.purchaseRepository;
  SaleRepository get saleRepository => widget.saleRepository;
  ShopSettingsRepository get shopSettingsRepository =>
      widget.shopSettingsRepository;
  ContactRepository? get contactRepository => widget.contactRepository;
  AuthorizationCapabilities get capabilities => widget.capabilities;
  AnalyticsEngine? get analyticsEngine => widget.analyticsEngine;

  Product? _selectedProduct;
  ProductDetailsViewModel? _selectedProductViewModel;

  /// The shop's places. Empty until loaded, and empty forever for a shop that
  /// keeps one — which is what stops the filter bar from appearing at all.
  List<Warehouse> _places = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadPlaces());
  }

  void _selectProduct(Product product) {
    setState(() {
      _selectedProduct = product;
      _selectedProductViewModel = ProductDetailsViewModel(
        viewModel.catalogRepository,
        purchaseRepository,
        saleRepository,
        product,
        analyticsEngine: analyticsEngine,
        pricingOptions: viewModel.pricingOptions,
        shouldLoadSaleHistory: capabilities.canViewRegisterSessionOrders,
        shouldLoadPurchaseHistory: capabilities.canAccessPurchasing,
      );
    });
  }

  /// Best effort and fire-and-forget: the catalog is fully usable without
  /// knowing the shop's places, so a failure here costs a filter bar, not a
  /// screen.
  Future<void> _loadPlaces() async {
    final repository = widget.warehouseRepository;
    if (repository == null) {
      return;
    }
    final result = await repository.loadWarehouses(activeOnly: true);
    if (!mounted || result is! Ok<List<Warehouse>>) {
      return;
    }
    setState(() {
      _places = result.value
          .where((place) => place.sellsFrom)
          .toList(growable: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.catalog,
            navigation: widget.navigation,
          ),
          appBar: PointyAppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.catalogManagementTitle),
            actions: [
              SmartReorderAction(
                navigation: widget.navigation,
                capabilities: capabilities,
                from: AppNavigationDestination.catalog,
              ),
              CatalogManagementGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.manageUnitsTooltip,
                  onPressed: () => _openUnitsManagement(context),
                  icon: const Icon(Icons.straighten_outlined),
                ),
              ),
              CatalogManagementGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.manageScaleRulesTooltip,
                  onPressed: () => _openScaleRules(context),
                  icon: const Icon(Icons.scale_outlined),
                ),
              ),
              if (widget.onOpenSearchMisses case final openSearchMisses?)
                ProductChangeGuard(
                  capabilities: capabilities,
                  child: IconButton(
                    tooltip: l10n.searchMissesTooltip,
                    onPressed: openSearchMisses,
                    icon: const Icon(Icons.search_off_outlined),
                  ),
                ),
            ],
          ),
          body: CatalogManagementGuard(
            capabilities: capabilities,
            child: RouteKeyboardShortcuts(
              enabled: capabilities.canCreateProduct,
              bindings: _catalogShortcuts(context),
              child: BarcodeScanListener(
                onBarcodeScanned: (barcode) {
                  _openProductForBarcode(context, barcode, offerCreate: true);
                },
                child: MasterDetailLayout(
                  listPaneBuilder: (paneContext, isDualPane) => ProductList(
                    viewModel: viewModel,
                    places: _places,
                    inventoryRepository: inventoryRepository,
                    printingRepository: printingRepository,
                    purchaseRepository: purchaseRepository,
                    warehouseRepository: widget.warehouseRepository,
                    saleRepository: saleRepository,
                    shopSettingsRepository: shopSettingsRepository,
                    contactRepository: contactRepository,
                    capabilities: capabilities,
                    analyticsEngine: analyticsEngine,
                    onBarcodeSubmitted: (barcode) {
                      return _openProductForBarcode(context, barcode);
                    },
                    onOpenCameraScanner: () => _openCameraScanner(context),
                    onCreateProduct: () => _showProductForm(context),
                    onOpenProduct: isDualPane ? _selectProduct : null,
                    onCreateSimilar: (product) =>
                        _createSimilar(context, product),
                    trackedStockRepository: widget.trackedStockRepository,
                    resultsHeaderBuilder: _unitSearchSlot(context),
                  ),
                  placeholder: PointyEmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: l10n.catalogSelectProductPlaceholder,
                  ),
                  detailPane: _selectedProduct == null
                      ? null
                      : ProductDetailsView(
                          key: ValueKey(
                            'catalog_detail_${_selectedProduct!.id}',
                          ),
                          viewModel: _selectedProductViewModel!,
                          inventoryRepository: inventoryRepository,
                          printingRepository: printingRepository,
                          purchaseRepository: purchaseRepository,
                          warehouseRepository: widget.warehouseRepository,
                          shopSettingsRepository: shopSettingsRepository,
                          capabilities: capabilities,
                          analyticsEngine: analyticsEngine,
                          onChanged: viewModel.loadProducts,
                          onCreateSimilar: (product) =>
                              _createSimilar(context, product),
                          trackedStockRepository: widget.trackedStockRepository,
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The identifier match above the results, when this shop and this reader
  /// can look articles up at all.
  Widget Function(double gap)? _unitSearchSlot(BuildContext context) {
    final lookup = viewModel.unitSearch;
    final openUnit = widget.onOpenStockUnit;
    if (lookup == null || openUnit == null) {
      return null;
    }
    final openRecord = widget.onOpenRecord;
    return (gap) => UnitSearchSlot(
      lookup: lookup,
      gap: gap,
      onOpenUnit: (unit) => openUnit(context, unit),
      onOpenInvoice: openRecord != null && capabilities.canViewInvoices
          ? (id) => _openRecord(context, 'order', id)
          : null,
      onOpenCustomer: openRecord != null && capabilities.canManageContacts
          ? (id) => _openRecord(context, 'customer', id)
          : null,
    );
  }

  Future<void> _openRecord(BuildContext context, String type, int id) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = AppLocalizations.of(context)!.aiAssistantLinkUnavailable;
    final opened = await widget.onOpenRecord!(context, type, id);
    if (!opened) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// An identifier typed (Enter) or scanned: the article it names, when
  /// exactly one answers. True when one was opened. When several answer (a
  /// trade-in sold twice) the card lists them and nothing opens blindly; a
  /// scan, which never lands in the field, puts its code there so the card
  /// shows. Asked beside the barcode lookup, never after it.
  Future<bool?> _openUnitForCode(
    BuildContext context,
    String code, {
    required bool fromScan,
  }) async {
    final openUnit = widget.onOpenStockUnit;
    if (openUnit == null) {
      return null;
    }
    final match = await viewModel.resolveUnitMatch(code);
    if (match == null || !context.mounted) {
      if (fromScan) viewModel.settleUnitSearch();
      return null;
    }
    final single = match.single;
    if (single == null) {
      if (fromScan) unawaited(viewModel.updateSearch(code));
      return false;
    }
    if (fromScan) viewModel.settleUnitSearch();
    openUnit(context, single);
    return true;
  }

  /// Ctrl+N (⌘N): a new product, from anywhere on the catalogue.
  Map<ShortcutActivator, bool Function()> _catalogShortcuts(
    BuildContext context,
  ) {
    bool newProduct() {
      unawaited(_showProductForm(context));
      return true;
    }

    return {
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): newProduct,
      const SingleActivator(LogicalKeyboardKey.keyN, meta: true): newProduct,
    };
  }

  void _openUnitsManagement(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UnitsManagementScreen(
          viewModel: UnitsManagementViewModel(
            viewModel.catalogRepository,
            analyticsEngine: analyticsEngine,
          ),
        ),
      ),
    );
  }

  void _openScaleRules(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ScaleRulesScreen(
          viewModel: ScaleRulesViewModel(viewModel.catalogRepository),
        ),
      ),
    );
  }

  /// Opens the product a code belongs to. For a code nobody owns yet, a scan
  /// ([offerCreate]) goes straight to a new product with the code filled in —
  /// the scanner is in the hand of somebody entering their shelves — while a
  /// code typed into the search offers the same from the "not found" message.
  Future<bool> _openProductForBarcode(
    BuildContext context,
    String barcode, {
    bool offerCreate = false,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty) {
      return false;
    }

    // Both questions at once: the article is the answer when one answers, the
    // product otherwise. The unit side is free for text that is no identifier.
    final outcomeFuture = viewModel.findVariantByBarcode(normalizedBarcode);
    final unitOpened = await _openUnitForCode(
      context,
      normalizedBarcode,
      fromScan: offerCreate,
    );
    if (unitOpened != null) {
      return unitOpened;
    }
    final outcome = await outcomeFuture;
    if (!context.mounted) {
      return false;
    }

    switch (outcome.status) {
      case CatalogBarcodeLookupStatus.found:
        if (MasterDetailLayout.isDualPane(context)) {
          _selectProduct(outcome.product!);
          return true;
        }
        await _openDetails(context, outcome.product!);
        return true;
      case CatalogBarcodeLookupStatus.notFound:
        if (!capabilities.canCreateProduct) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(l10n.barcodeScanNotFound(normalizedBarcode)),
            ),
          );
          return false;
        }
        if (offerCreate) {
          ScanFeedbackSounds.instance.play(ScanFeedback.notFound);
          unawaited(
            _showProductForm(context, initialBarcode: normalizedBarcode),
          );
          return false;
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.barcodeScanNotFound(normalizedBarcode)),
            action: SnackBarAction(
              label: l10n.barcodeScanNotFoundCreateAction,
              onPressed: () {
                if (context.mounted) {
                  unawaited(
                    _showProductForm(
                      context,
                      initialBarcode: normalizedBarcode,
                    ),
                  );
                }
              },
            ),
          ),
        );
        return false;
      case CatalogBarcodeLookupStatus.error:
        messenger.showSnackBar(SnackBar(content: Text(l10n.barcodeScanError)));
        return false;
    }
  }

  Future<void> _openCameraScanner(BuildContext context) async {
    final entries = await showCameraBarcodeScannerSheet(
      context,
      mode: CameraBarcodeScannerMode.single,
      lookupVariant: _lookupVariantByBarcode,
    );
    if (entries == null || entries.isEmpty || !context.mounted) {
      return;
    }
    if (MasterDetailLayout.isDualPane(context)) {
      _selectProduct(Product.fromVariant(entries.first.variant));
      return;
    }
    await _openDetails(context, Product.fromVariant(entries.first.variant));
  }

  Future<ProductVariant?> _lookupVariantByBarcode(String barcode) async {
    final outcome = await viewModel.findVariantByBarcode(barcode);
    return switch (outcome.status) {
      CatalogBarcodeLookupStatus.found => outcome.variant,
      CatalogBarcodeLookupStatus.notFound => null,
      CatalogBarcodeLookupStatus.error => throw Exception(
        'barcode lookup failed',
      ),
    };
  }

  Future<void> _showProductForm(
    BuildContext context, {
    String? initialBarcode,
    Product? similarTo,
  }) {
    return showAdaptiveFormSurface<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      desktopPresentation: AdaptiveFormPresentation.sidePanel,
      maxHeightFactor: 0.9,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: ProductForm(
            viewModel: viewModel,
            initialBarcode: initialBarcode,
            similarTo: similarTo,
            // A shop typing in a product it already owns says so here rather
            // than raising a purchase order against a supplier it never
            // bought from. Gated on the stock permission, which the server
            // checks again.
            showOpeningStock: capabilities.canCreateStockMovement,
            onCreated: (created) {
              Navigator.of(sheetContext).pop();
              if (similarTo != null && context.mounted) {
                _showCreatedSimilar(context, created);
              }
            },
            // A shop entering its shelves creates product after product.
            offerAddAnother: true,
            // Opens over the panel, so the run carries on when it closes. No
            // «منتج مشابه» there: a second form over this one helps nobody.
            onOpenCreated: (product) =>
                _openDetails(sheetContext, product, offerSimilar: false),
          ),
        );
      },
    );
  }

  /// «منتج مشابه»: a new-product panel opened on [source]'s values.
  void _createSimilar(BuildContext context, Product source) {
    unawaited(_showProductForm(context, similarTo: source));
  }

  /// The product a «منتج مشابه» just created. Its details are what the owner
  /// should be looking at, not the original's: the form showed the original's
  /// name, and landing back on the original reads like an edit that was lost.
  void _showCreatedSimilar(BuildContext context, Product created) {
    if (MasterDetailLayout.isDualPane(context)) {
      _selectProduct(created);
      return;
    }
    unawaited(_openDetails(context, created));
  }

  /// A product's details on a screen of their own.
  Future<void> _openDetails(
    BuildContext context,
    Product product, {
    bool offerSimilar = true,
  }) {
    return openProductDetails(
      context,
      product: product,
      catalogRepository: viewModel.catalogRepository,
      warehouseRepository: widget.warehouseRepository,
      inventoryRepository: inventoryRepository,
      printingRepository: printingRepository,
      purchaseRepository: purchaseRepository,
      saleRepository: saleRepository,
      shopSettingsRepository: shopSettingsRepository,
      capabilities: capabilities,
      analyticsEngine: analyticsEngine,
      onChanged: viewModel.loadProducts,
      pricingOptions: viewModel.pricingOptions,
      onCreateSimilar: offerSimilar
          ? (source) => _createSimilar(context, source)
          : null,
      trackedStockRepository: widget.trackedStockRepository,
    );
  }
}
