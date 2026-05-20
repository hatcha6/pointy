import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/product.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/inventory_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/camera_barcode_scanner_sheet.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
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
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDiscounts,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final CatalogViewModel viewModel;
  final InventoryRepository inventoryRepository;
  final PrintingRepository printingRepository;
  final PurchaseRepository purchaseRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.catalog,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenPos: onOpenPos,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: () {},
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: AppBar(
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
          body: SafeArea(
            child: CatalogManagementGuard(
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
                  capabilities: capabilities,
                  onBarcodeSubmitted: (barcode) {
                    return _openProductForBarcode(context, barcode);
                  },
                  onOpenCameraScanner: () => _openCameraScanner(context),
                ),
              ),
            ),
          ),
          floatingActionButton: ProductCreateGuard(
            capabilities: capabilities,
            child: FloatingActionButton.extended(
              onPressed: () => _showProductForm(context),
              icon: const Icon(Icons.add),
              label: Text(l10n.addProductButton),
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

    final outcome = await viewModel.findProductByBarcode(normalizedBarcode);
    if (!context.mounted) {
      return false;
    }

    switch (outcome.status) {
      case CatalogBarcodeLookupStatus.found:
        await openProductDetails(
          context,
          product: outcome.product!,
          inventoryRepository: inventoryRepository,
          printingRepository: printingRepository,
          purchaseRepository: purchaseRepository,
          capabilities: capabilities,
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
      lookupProduct: _lookupProductByBarcode,
    );
    if (entries == null || entries.isEmpty || !context.mounted) {
      return;
    }
    await openProductDetails(
      context,
      product: entries.first.product,
      inventoryRepository: inventoryRepository,
      printingRepository: printingRepository,
      purchaseRepository: purchaseRepository,
      capabilities: capabilities,
    );
  }

  Future<Product?> _lookupProductByBarcode(String barcode) async {
    final outcome = await viewModel.findProductByBarcode(barcode);
    return switch (outcome.status) {
      CatalogBarcodeLookupStatus.found => outcome.product,
      CatalogBarcodeLookupStatus.notFound => null,
      CatalogBarcodeLookupStatus.error => throw Exception(
        'barcode lookup failed',
      ),
    };
  }

  Future<void> _showProductForm(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: FractionallySizedBox(
            heightFactor: 0.9,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ProductForm(
                  viewModel: viewModel,
                  onCreated: () => Navigator.of(sheetContext).pop(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
