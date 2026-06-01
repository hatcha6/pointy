import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/product.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/catalog_view_model.dart';
import 'product_form.dart';
import 'product_list.dart';

class CatalogScreen extends StatelessWidget {
  const CatalogScreen({
    super.key,
    required this.viewModel,
    required this.inventoryRepository,
    required this.printingRepository,
    required this.purchaseRepository,
    required this.saleRepository,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenCategories,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final CatalogViewModel viewModel;
  final InventoryRepository inventoryRepository;
  final PrintingRepository printingRepository;
  final PurchaseRepository purchaseRepository;
  final SaleRepository saleRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenCategories;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.catalog,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: () {},
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenReports: onOpenReports,
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: PointyAppBar(
            leading: Builder(
              builder: (context) {
                return IconButton(
                  tooltip: l10n.navigationMenuTooltip,
                  icon: const Icon(Icons.menu),
                  onPressed: Scaffold.of(context).openDrawer,
                );
              },
            ),
            title: Text(l10n.catalogManagementTitle),
            actions: [
              CatalogManagementGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshCatalogTooltip,
                  onPressed: viewModel.loadProducts,
                  icon: const Icon(Icons.sync),
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
              child: ProductList(
                viewModel: viewModel,
                inventoryRepository: inventoryRepository,
                printingRepository: printingRepository,
                purchaseRepository: purchaseRepository,
                saleRepository: saleRepository,
                capabilities: capabilities,
                onBarcodeSubmitted: (barcode) {
                  return _openProductForBarcode(context, barcode);
                },
                onOpenCameraScanner: () => _openCameraScanner(context),
                onCreateProduct: () => _showProductForm(context),
              ),
            ),
          ),
        );
      },
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
        await openProductDetails(
          context,
          product: outcome.product!,
          catalogRepository: viewModel.catalogRepository,
          inventoryRepository: inventoryRepository,
          printingRepository: printingRepository,
          purchaseRepository: purchaseRepository,
          saleRepository: saleRepository,
          capabilities: capabilities,
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
    await openProductDetails(
      context,
      product: Product.fromVariant(entries.first.variant),
      catalogRepository: viewModel.catalogRepository,
      inventoryRepository: inventoryRepository,
      printingRepository: printingRepository,
      purchaseRepository: purchaseRepository,
      saleRepository: saleRepository,
      capabilities: capabilities,
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
    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      maxHeightFactor: 0.9,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: ProductForm(
            viewModel: viewModel,
            onCreated: () => Navigator.of(sheetContext).pop(),
          ),
        );
      },
    );
  }
}
