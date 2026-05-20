import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/register_cash_movement.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
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
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenCatalog,
    required this.onOpenRegisterSessions,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDiscounts,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenRegisterSessions;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenUsers;
  final VoidCallback? onOpenShopSettings;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;

        return Scaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.pos,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenPos: () {},
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
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
                  onPressed: Scaffold.of(context).openDrawer,
                  icon: const Icon(Icons.menu),
                );
              },
            ),
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
          body: SafeArea(
            child: PosAccessGuard(
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
          ),
        );
      },
    );
  }

  Future<void> _showCloseRegisterSessionSheet(BuildContext context) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
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
    final didCreate = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
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

class _PosWorkspace extends StatelessWidget {
  const _PosWorkspace({
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    return BarcodeScanListener(
      enabled:
          capabilities.canCheckoutSale &&
          !viewModel.isCheckingOut &&
          !viewModel.isResolvingBarcode,
      onBarcodeScanned: viewModel.addProductByBarcode,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final catalog = PosCatalogPane(
            viewModel: viewModel,
            capabilities: capabilities,
          );
          final cart = PosCartPane(
            viewModel: viewModel,
            contactRepository: contactRepository,
            capabilities: capabilities,
          );

          if (constraints.maxWidth >= 720) {
            return Row(
              children: [
                Expanded(flex: 3, child: catalog),
                const VerticalDivider(width: 1),
                SizedBox(width: 420, child: cart),
              ],
            );
          }

          return Column(
            children: [
              Expanded(flex: 2, child: catalog),
              const Divider(height: 1),
              Expanded(flex: 3, child: cart),
            ],
          );
        },
      ),
    );
  }
}
