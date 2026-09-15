import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/register_session.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/shell/shell.dart';
import '../view_models/register_session_history_view_model.dart';
import 'register_session_list.dart';
import 'session_orders.dart';

class RegisterSessionHistoryScreen extends StatefulWidget {
  const RegisterSessionHistoryScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    required this.navigation,
    this.initialSessionId,
  });

  final RegisterSessionHistoryViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final AppNavigation navigation;

  /// Selected on open, fetching the shift when it is older than the first page
  /// of history. Set when the screen is reached from an invoice's drawer-session
  /// link rather than from the drawer.
  final int? initialSessionId;

  @override
  State<RegisterSessionHistoryScreen> createState() =>
      _RegisterSessionHistoryScreenState();
}

class _RegisterSessionHistoryScreenState
    extends State<RegisterSessionHistoryScreen> {
  RegisterSessionHistoryViewModel get viewModel => widget.viewModel;

  @override
  void initState() {
    super.initState();
    final sessionId = widget.initialSessionId;
    if (sessionId != null) {
      unawaited(viewModel.focusSession(sessionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        return PointyScaffold(
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.registerSessions,
            navigation: widget.navigation,
          ),
          appBar: AppBar(
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.registerSessionHistoryTitle),
            actions: [
              RegisterSessionsGuard(
                capabilities: widget.capabilities,
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
            capabilities: widget.capabilities,
            child: _HistoryWorkspace(
              viewModel: viewModel,
              contactRepository: widget.contactRepository,
              capabilities: widget.capabilities,
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
