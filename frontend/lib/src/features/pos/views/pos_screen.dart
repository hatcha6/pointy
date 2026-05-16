import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../view_models/pos_view_model.dart';
import 'pos_cart_pane.dart';
import 'pos_catalog_pane.dart';
import 'register_session_close_sheet.dart';
import 'register_session_gate.dart';

class PosScreen extends StatelessWidget {
  const PosScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenCatalog,
    required this.onOpenRegisterSessions,
    required this.onLogout,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final PosViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenRegisterSessions;
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
            onOpenCatalog: onOpenCatalog,
            onOpenRegisterSessions: onOpenRegisterSessions,
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
          initialClosingCash: viewModel.total == 0
              ? ''
              : viewModel.total.toStringAsFixed(2),
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
}

class _PosWorkspace extends StatelessWidget {
  const _PosWorkspace({required this.viewModel, required this.capabilities});

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final catalog = PosCatalogPane(
          viewModel: viewModel,
          capabilities: capabilities,
        );
        final cart = PosCartPane(
          viewModel: viewModel,
          capabilities: capabilities,
        );

        if (constraints.maxWidth >= 900) {
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
    );
  }
}
