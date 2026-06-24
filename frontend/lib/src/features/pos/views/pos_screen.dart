import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/register_cash_movement.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../../contacts/views/collect_debt_dialog.dart';
import '../view_models/pos_view_model.dart';
import 'pos_cart_pane.dart';
import 'pos_catalog_pane.dart';
import 'register_cash_movement_sheet.dart';
import 'register_session_close_sheet.dart';
import 'register_session_gate.dart';

class PosScreen extends StatelessWidget {
  const PosScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.capabilities,
    required this.navigation,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;

        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.pos,
            navigation: navigation,
          ),
          appBar: PointyAppBar(
            style: PointyAppBarStyle.highFocus,
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.appTitle),
            actions: [
              if (viewModel.activeRegisterSession != null)
                PosAccessGuard(
                  capabilities: capabilities,
                  fallback: const SizedBox.shrink(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Center(
                      child: Chip(
                        avatar: const Icon(Icons.point_of_sale_outlined),
                        label: Text(
                          l10n.activeRegisterSessionLabel(
                            viewModel.activeRegisterSession!.sessionNumber,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (viewModel.activeRegisterSession != null)
                RegisterCashMovementCreateGuard(
                  capabilities: capabilities,
                  child: PopupMenuButton<RegisterCashMovementType>(
                    tooltip: l10n.cashMovementMenuTooltip,
                    enabled: !viewModel.isCreatingCashMovement,
                    icon: viewModel.isCreatingCashMovement
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.account_balance_wallet_outlined),
                    onSelected: (movementType) {
                      _showCashMovementSheet(context, movementType);
                    },
                    itemBuilder: (context) {
                      return [
                        PopupMenuItem(
                          value: RegisterCashMovementType.payIn,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.input),
                            title: Text(l10n.payInRegisterSessionButton),
                          ),
                        ),
                        PopupMenuItem(
                          value: RegisterCashMovementType.payOut,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.output),
                            title: Text(l10n.payOutRegisterSessionButton),
                          ),
                        ),
                      ];
                    },
                  ),
                ),
              if (viewModel.activeRegisterSession != null)
                RegisterSessionCloseGuard(
                  capabilities: capabilities,
                  child: IconButton(
                    tooltip: l10n.closeRegisterSessionTooltip,
                    onPressed: viewModel.isClosingRegisterSession
                        ? null
                        : () => _showCloseRegisterSessionSheet(context),
                    icon: const Icon(Icons.lock_outline),
                  ),
                ),
              if (capabilities.canCollectCustomerDebt &&
                  viewModel.activeRegisterSession != null)
                IconButton(
                  tooltip: l10n.collectDebtTitle,
                  onPressed: () => showCollectDebtDialog(
                    context,
                    contactRepository: contactRepository,
                    printingRepository: printingRepository,
                    shopSettingsRepository: shopSettingsRepository,
                  ),
                  icon: const Icon(Icons.request_quote_outlined),
                ),
              PosAccessGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshCatalogTooltip,
                  onPressed: viewModel.activeRegisterSession == null
                      ? null
                      : viewModel.loadCatalog,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: PosAccessGuard(
            capabilities: capabilities,
            child:
                viewModel.registerSessionGateStatus ==
                    RegisterSessionGateStatus.active
                ? _PosWorkspace(
                    viewModel: viewModel,
                    contactRepository: contactRepository,
                    capabilities: capabilities,
                  )
                : RegisterSessionGate(
                    viewModel: viewModel,
                    capabilities: capabilities,
                  ),
          ),
        );
      },
    );
  }

  Future<void> _showCloseRegisterSessionSheet(BuildContext context) async {
    await showAdaptiveModalBottomSheet<bool>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (context) {
        return RegisterSessionCloseSheet(
          onClose: (input) {
            return viewModel.closeActiveRegisterSession(
              closingCash: input.closingCash,
              count025: input.count025,
              count050: input.count050,
              count075: input.count075,
              count100: input.count100,
            );
          },
        );
      },
    );
  }

  Future<void> _showCashMovementSheet(
    BuildContext context,
    RegisterCashMovementType movementType,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final didCreate = await showAdaptiveModalBottomSheet<bool>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (context) {
        return RegisterCashMovementSheet(
          movementType: movementType,
          onSubmit: (input) {
            return viewModel.createActiveRegisterCashMovement(
              movementType: input.movementType,
              amount: input.amount,
              reason: input.reason,
            );
          },
        );
      },
    );

    if (didCreate ?? false) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.cashMovementCreatedMessage)),
      );
    }
  }
}

class _PosWorkspace extends StatefulWidget {
  const _PosWorkspace({
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  State<_PosWorkspace> createState() => _PosWorkspaceState();
}

class _PosWorkspaceState extends State<_PosWorkspace> {
  // The cart pane publishes its checkout closure here so Ctrl/Cmd+Enter runs the
  // same flow as the footer button, even while the catalog search has focus.
  final PosCheckoutController _checkoutController = PosCheckoutController();

  void _requestCheckout() => _checkoutController.onCheckout?.call();

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    final capabilities = widget.capabilities;

    return BarcodeScanListener(
      enabled:
          capabilities.canCheckoutSale &&
          !viewModel.isCheckingOut &&
          !viewModel.isResolvingBarcode,
      onBarcodeScanned: (barcode) =>
          viewModel.addVariantByBarcode(barcode, source: 'hardware_scanner'),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              _requestCheckout,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              _requestCheckout,
          const SingleActivator(LogicalKeyboardKey.numpadEnter, control: true):
              _requestCheckout,
          const SingleActivator(LogicalKeyboardKey.numpadEnter, meta: true):
              _requestCheckout,
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.hasBoundedWidth
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            if (AppBreakpoints.usesTwoPane(width)) {
              return TwoPaneLayout(
                minPrimaryWidth: 390,
                primaryPane: PosCatalogPane(
                  viewModel: viewModel,
                  capabilities: capabilities,
                ),
                secondaryPane: PosCartPane(
                  viewModel: viewModel,
                  contactRepository: widget.contactRepository,
                  capabilities: capabilities,
                  checkoutController: _checkoutController,
                ),
              );
            }

            return _CompactPosWorkspace(
              viewModel: viewModel,
              contactRepository: widget.contactRepository,
              capabilities: capabilities,
            );
          },
        ),
      ),
    );
  }
}

class _CompactPosWorkspace extends StatelessWidget {
  const _CompactPosWorkspace({
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        Expanded(
          child: PosCatalogPane(
            viewModel: viewModel,
            capabilities: capabilities,
          ),
        ),
        PointyCompactOrderLauncher(
          title: l10n.currentSaleTitle,
          lineCountLabel: l10n.lineItemCount(viewModel.cart.length),
          totalLabel: formatMoney(viewModel.total),
          actionLabel: l10n.openCartSheetButton,
          icon: Icons.shopping_cart_checkout_outlined,
          isBusy: viewModel.isCheckingOut,
          onPressed: () => _showCartSheet(context),
        ),
      ],
    );
  }

  Future<void> _showCartSheet(BuildContext context) {
    final colors = context.pointyColors;

    return showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      backgroundColor: colors.page,
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
            return PosCartPane(
              viewModel: viewModel,
              contactRepository: contactRepository,
              capabilities: capabilities,
              onCheckoutSuccess: () {
                Navigator.of(sheetContext).pop();
              },
            );
          },
        );
      },
    );
  }
}
