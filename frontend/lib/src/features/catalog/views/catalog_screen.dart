import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/analytics_engine.dart';
import '../../../core/authorization.dart';
import '../../../data/models/product.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/components/components.dart';
import '../../ai/views/smart_reorder_action.dart';
import '../view_models/catalog_view_model.dart';
import '../view_models/product_details_view_model.dart';
import '../view_models/units_management_view_model.dart';
import 'product_details_screen.dart';
import 'product_form.dart';
import 'product_list.dart';
import 'units_management_screen.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({
    super.key,
    required this.viewModel,
    required this.inventoryRepository,
    required this.printingRepository,
    required this.purchaseRepository,
    required this.saleRepository,
    required this.shopSettingsRepository,
    this.contactRepository,
    required this.navigation,
    required this.capabilities,
    this.analyticsEngine,
  });

  final CatalogViewModel viewModel;
  final InventoryRepository inventoryRepository;
  final PrintingRepository printingRepository;
  final PurchaseRepository purchaseRepository;
  final SaleRepository saleRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final ContactRepository? contactRepository;
  final AppNavigation navigation;
  final AuthorizationCapabilities capabilities;
  final AnalyticsEngine? analyticsEngine;

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

  void _selectProduct(Product product) {
    setState(() {
      _selectedProduct = product;
      _selectedProductViewModel = ProductDetailsViewModel(
        viewModel.catalogRepository,
        purchaseRepository,
        saleRepository,
        product,
        analyticsEngine: analyticsEngine,
        shouldLoadSaleHistory: capabilities.canViewRegisterSessionOrders,
        shouldLoadPurchaseHistory: capabilities.canAccessPurchasing,
      );
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
            ],
          ),
          body: CatalogManagementGuard(
            capabilities: capabilities,
            child: BarcodeScanListener(
              onBarcodeScanned: (barcode) {
                _openProductForBarcode(context, barcode);
              },
              child: MasterDetailLayout(
                listPaneBuilder: (paneContext, isDualPane) => ProductList(
                  viewModel: viewModel,
                  inventoryRepository: inventoryRepository,
                  printingRepository: printingRepository,
                  purchaseRepository: purchaseRepository,
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
                ),
                placeholder: PointyEmptyState(
                  icon: Icons.inventory_2_outlined,
                  title: l10n.catalogSelectProductPlaceholder,
                ),
                detailPane: _selectedProduct == null
                    ? null
                    : ProductDetailsView(
                        key: ValueKey('catalog_detail_${_selectedProduct!.id}'),
                        viewModel: _selectedProductViewModel!,
                        inventoryRepository: inventoryRepository,
                        printingRepository: printingRepository,
                        purchaseRepository: purchaseRepository,
                        shopSettingsRepository: shopSettingsRepository,
                        capabilities: capabilities,
                        analyticsEngine: analyticsEngine,
                        onChanged: viewModel.loadProducts,
                      ),
              ),
            ),
          ),
        );
      },
    );
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

  Future<bool> _openProductForBarcode(
    BuildContext context,
    String barcode,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final normalizedBarcode = barcode.trim();
    if (normalizedBarcode.isEmpty) {
      return false;
    }

    final outcome = await viewModel.findVariantByBarcode(normalizedBarcode);
    if (!context.mounted) {
      return false;
    }

    switch (outcome.status) {
      case CatalogBarcodeLookupStatus.found:
        if (MasterDetailLayout.isDualPane(context)) {
          _selectProduct(outcome.product!);
          return true;
        }
        await openProductDetails(
          context,
          product: outcome.product!,
          catalogRepository: viewModel.catalogRepository,
          inventoryRepository: inventoryRepository,
          printingRepository: printingRepository,
          purchaseRepository: purchaseRepository,
          saleRepository: saleRepository,
          shopSettingsRepository: shopSettingsRepository,
          capabilities: capabilities,
          analyticsEngine: analyticsEngine,
          onChanged: viewModel.loadProducts,
        );
        return true;
      case CatalogBarcodeLookupStatus.notFound:
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.barcodeScanNotFound(normalizedBarcode))),
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
    await openProductDetails(
      context,
      product: Product.fromVariant(entries.first.variant),
      catalogRepository: viewModel.catalogRepository,
      inventoryRepository: inventoryRepository,
      printingRepository: printingRepository,
      purchaseRepository: purchaseRepository,
      saleRepository: saleRepository,
      shopSettingsRepository: shopSettingsRepository,
      capabilities: capabilities,
      analyticsEngine: analyticsEngine,
      onChanged: viewModel.loadProducts,
    );
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

  Future<void> _showProductForm(BuildContext context) {
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
            onCreated: (_) => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }
}
