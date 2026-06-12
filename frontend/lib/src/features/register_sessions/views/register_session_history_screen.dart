import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/register_session.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/register_session_history_view_model.dart';
import 'register_session_list.dart';
import 'session_orders.dart';

class RegisterSessionHistoryScreen extends StatelessWidget {
  const RegisterSessionHistoryScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.currentUser,
    required this.capabilities,
    required this.onOpenPos,
    required this.onOpenInvoices,
    required this.onOpenCatalog,
    required this.onOpenCategories,
    required this.onOpenPurchasing,
    required this.onOpenContacts,
    required this.onOpenDeviceSettings,
    required this.onLogout,
    this.onOpenDashboard,
    this.onOpenDiscounts,
    this.onOpenReports,
    this.onOpenActivityLog,
    this.onOpenUsers,
    this.onOpenShopSettings,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final ContactRepository contactRepository;
  final PosUser currentUser;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onOpenPos;
  final VoidCallback onOpenInvoices;
  final VoidCallback onOpenCatalog;
  final VoidCallback onOpenCategories;
  final VoidCallback onOpenPurchasing;
  final VoidCallback onOpenContacts;
  final VoidCallback onOpenDeviceSettings;
  final VoidCallback? onOpenDashboard;
  final VoidCallback? onOpenDiscounts;
  final VoidCallback? onOpenReports;
  final VoidCallback? onOpenActivityLog;
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
            selectedDestination: AppNavigationDestination.registerSessions,
            currentUser: currentUser,
            capabilities: capabilities,
            onOpenDashboard: onOpenDashboard,
            onOpenPos: onOpenPos,
            onOpenInvoices: onOpenInvoices,
            onOpenPurchasing: onOpenPurchasing,
            onOpenContacts: onOpenContacts,
            onOpenCatalog: onOpenCatalog,
            onOpenCategories: onOpenCategories,
            onOpenRegisterSessions: () {},
            onOpenDeviceSettings: onOpenDeviceSettings,
            onOpenDiscounts: onOpenDiscounts,
            onOpenReports: onOpenReports,
            onOpenActivityLog: onOpenActivityLog,
            onOpenUsers: onOpenUsers,
            onOpenShopSettings: onOpenShopSettings,
            onLogout: onLogout,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
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
          body: RegisterSessionsGuard(
            capabilities: capabilities,
            child: _HistoryWorkspace(
              viewModel: viewModel,
              contactRepository: contactRepository,
              capabilities: capabilities,
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
    required this.contactRepository,
    required this.capabilities,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final isCompact = width < AppBreakpoints.masterDetailMin;
        final sessions = RegisterSessionList(
          viewModel: viewModel,
          capabilities: capabilities,
          onSessionSelected: isCompact
              ? (session) {
                  unawaited(_showSessionDetailsSheet(context, session));
                }
              : null,
        );

        if (isCompact) {
          return sessions;
        }

        final orders = SessionOrders(
          viewModel: viewModel,
          contactRepository: contactRepository,
          capabilities: capabilities,
        );

        return TwoPaneLayout(
          dualPaneBreakpoint: AppBreakpoints.masterDetailMin,
          primaryPane: orders,
          secondaryPane: sessions,
          secondaryFirst: true,
          secondaryPaneWidth: 420,
          compactPrimaryFlex: 1,
          compactSecondaryFlex: 1,
        );
      },
    );
  }

  Future<void> _showSessionDetailsSheet(
    BuildContext context,
    RegisterSession session,
  ) async {
    unawaited(viewModel.selectSession(session));
    await showAdaptiveModalBottomSheet<void>(
      context: context,
      size: AdaptiveModalSize.expanded,
      maxHeightFactor: 0.92,
      builder: (context) {
        return _CompactSessionDetailsSheet(
          viewModel: viewModel,
          contactRepository: contactRepository,
          capabilities: capabilities,
        );
      },
    );
  }
}

class _CompactSessionDetailsSheet extends StatelessWidget {
  const _CompactSessionDetailsSheet({
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(PointyRadii.sheet),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: viewModel,
          builder: (context, _) {
            return SessionOrders(
              viewModel: viewModel,
              contactRepository: contactRepository,
              capabilities: capabilities,
            );
          },
        ),
      ),
    );
  }
}
