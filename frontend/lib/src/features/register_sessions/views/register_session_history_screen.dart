import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/pos_user.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../view_models/register_session_history_view_model.dart';
import 'register_session_list.dart';
import 'session_orders.dart';

class RegisterSessionHistoryScreen extends StatelessWidget {
  const RegisterSessionHistoryScreen({
    super.key,
    required this.viewModel,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenCatalog,
    required this.onLogout,
    this.onOpenUsers,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenCatalog;
  final VoidCallback? onOpenUsers;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return Scaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.registerSessions,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenPos: onOpenPos,
            onOpenCatalog: onOpenCatalog,
            onOpenRegisterSessions: () {},
            onOpenUsers: onOpenUsers,
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
            title: Text(l10n.registerSessionHistoryTitle),
            actions: [
              RegisterSessionsGuard(
                capabilities: capabilities,
                fallback: const SizedBox.shrink(),
                child: IconButton(
                  tooltip: l10n.refreshRegisterSessionsTooltip,
                  onPressed: viewModel.loadSessions,
                  icon: const Icon(Icons.sync),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: RegisterSessionsGuard(
              capabilities: capabilities,
              child: _HistoryWorkspace(
                viewModel: viewModel,
                capabilities: capabilities,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HistoryWorkspace extends StatelessWidget {
  const _HistoryWorkspace({
    required this.viewModel,
    required this.capabilities,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final sessions = RegisterSessionList(
          viewModel: viewModel,
          capabilities: capabilities,
        );
        final orders = SessionOrders(
          viewModel: viewModel,
          capabilities: capabilities,
        );

        if (constraints.maxWidth >= 900) {
          return Row(
            children: [
              SizedBox(width: 420, child: sessions),
              const VerticalDivider(width: 1),
              Expanded(child: orders),
            ],
          );
        }

        return Column(
          children: [
            Expanded(child: sessions),
            const Divider(height: 1),
            Expanded(child: orders),
          ],
        );
      },
    );
  }
}
