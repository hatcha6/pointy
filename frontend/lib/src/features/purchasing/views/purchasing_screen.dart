import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/models/product_variant.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/purchase_view_model.dart';
import 'purchase_catalog_pane.dart';
import 'purchase_draft_pane.dart';
import 'purchase_quick_product_sheet.dart';

class PurchasingScreen extends StatelessWidget {
  const PurchasingScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenContacts,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.showBackButton = false,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final bool showBackButton;
  final VoidCallback? onOpenDashboard;
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
            selectedDestination: AppNavigationDestination.purchasing,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenPurchasing: () {},
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: onOpenRegisterSessions,
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenReports: onOpenReports,
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: AppBar(
            leading: showBackButton
                ? IconButton(
                    tooltip: l10n.backTooltip,
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  )
                : const PointyNavigationMenuButton(),
            title: Text(l10n.newPurchaseOrderTitle),
            actions: [
              AuthorizationGuard(
                capabilities: capabilities,
                capability: AppCapability.accessPurchasing,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshCatalogTooltip,
                  onPressed: viewModel.loadCatalog,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: AuthorizationGuard(
            capabilities: capabilities,
            capability: AppCapability.accessPurchasing,
            child: _PurchasingWorkspace(
              viewModel: viewModel,
              contactRepository: contactRepository,
            ),
          ),
        );
      },
    );
  }
}

class _PurchasingWorkspace extends StatelessWidget {
  const _PurchasingWorkspace({
    required this.viewModel,
    required this.contactRepository,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;

  @override
  Widget build(BuildContext context) {
    return BarcodeScanListener(
      enabled: !viewModel.isSubmitting && !viewModel.isCreatingProduct,
      onBarcodeScanned: (barcode) {
        unawaited(_addBarcode(context, barcode));
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          if (AppBreakpoints.usesTwoPane(width)) {
            return TwoPaneLayout(
              primaryPane: PurchaseCatalogPane(viewModel: viewModel),
              secondaryPane: PurchaseDraftPane(
                viewModel: viewModel,
                contactRepository: contactRepository,
              ),
            );
          }

          return _CompactPurchasingWorkspace(
            viewModel: viewModel,
            contactRepository: contactRepository,
          );
        },
      ),
    );
  }

  Future<void> _addBarcode(BuildContext context, String barcode) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    ProductVariant? variant;
    try {
      variant = await resolveOrCreatePurchaseVariant(
        context,
        viewModel: viewModel,
        barcode: barcode,
      );
    } on Exception {
      if (!context.mounted) {
        return;
      }
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.barcodeScanError)));
      return;
    }
    if (variant == null) {
      return;
    }
    await viewModel.addVariant(variant);
  }
}

class _CompactPurchasingWorkspace extends StatelessWidget {
  const _CompactPurchasingWorkspace({
    required this.viewModel,
    required this.contactRepository,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        Expanded(child: PurchaseCatalogPane(viewModel: viewModel)),
        PointyCompactOrderLauncher(
          title: l10n.purchaseDraftTitle,
          lineCountLabel: l10n.lineItemCount(viewModel.draft.length),
          totalLabel: formatMoney(viewModel.total),
          actionLabel: l10n.openPurchaseDraftSheetButton,
          icon: Icons.assignment_outlined,
          isBusy: viewModel.isSubmitting,
          onPressed: () => _showDraftSheet(context),
        ),
      ],
    );
  }

  Future<void> _showDraftSheet(BuildContext context) {
    final colors = context.pointyColors;

    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(PointyRadii.sheet),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) {
        return ListenableBuilder(
          listenable: viewModel,
          builder: (context, _) {
            return PurchaseDraftPane(
              viewModel: viewModel,
              contactRepository: contactRepository,
              onSubmitSuccess: () {
                Navigator.of(sheetContext).pop();
              },
            );
          },
        );
      },
    );
  }
}
