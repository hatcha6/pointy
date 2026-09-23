import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/integration_provider.dart';
import '../../../data/repositories/integrations_repository.dart';
import '../view_models/integration_recharge_view_model.dart';
import 'integration_recharge_screen.dart';
import '../../../data/models/product.dart';
import '../../../data/models/register_cash_movement.dart';
import '../../../data/repositories/catalog_repository.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/repositories/purchase_repository.dart';
import '../../../data/repositories/shop_settings_repository.dart';
import '../../../shared/app_navigation_drawer.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/barcode/barcode_scan_listener.dart';
import '../../companion/companion_scan_listener.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_listener.dart';
import '../../../shared/barcode/camera_wedge/camera_wedge_scope.dart';
import '../../companion/views/companion_status_button.dart';
import '../../companion/companion_scope.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../../../shared/shell/shell.dart';
import '../../../shared/unit_options.dart';
import '../../contacts/views/collect_debt_dialog.dart';
import '../view_models/pos_view_model.dart';
import 'pos_cash_purchase_sheet.dart';
import 'pos_cart_pane.dart';
import 'pos_catalog_pane.dart';
import 'pos_shortcuts_sheet.dart';
import 'register_cash_movement_sheet.dart';
import 'register_session_close_sheet.dart';
import 'register_session_gate.dart';
import '../../../shared/components/pointy_progress.dart';

class PosScreen extends StatelessWidget {
  const PosScreen({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.printingRepository,
    required this.shopSettingsRepository,
    required this.catalogRepository,
    required this.purchaseRepository,
    required this.integrationsRepository,
    required this.capabilities,
    required this.navigation,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final PrintingRepository printingRepository;
  final ShopSettingsRepository shopSettingsRepository;
  final CatalogRepository catalogRepository;
  final PurchaseRepository purchaseRepository;
  final IntegrationsRepository integrationsRepository;
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
              // Always present, not only once a phone is paired: in ambient
              // mode a paired phone can put a scan straight into the open
              // cart, so the cashier needs to see at a glance that something
              // is listening — and reach the pause switch in one tap.
              CompanionStatusButton(
                bridge: CompanionScope.bridgeOf(context),
                repository: CompanionScope.maybeOf(context)?.repository,
              ),
              // Discoverable keyboard-shortcuts cheat sheet — so cashiers who
              // don't use the till shortcuts can still find and learn them.
              IconButton(
                icon: const Icon(Icons.keyboard_outlined),
                tooltip: l10n.posShortcutsButtonTooltip,
                onPressed: () => showPosShortcutsSheet(context),
              ),
              // A single, clearly-labeled session control replaces the old row of
              // cryptic icon-only buttons. It shows the active session and opens a
              // labeled menu of everything you can do at the register.
              if (viewModel.activeRegisterSession != null)
                PosAccessGuard(
                  capabilities: capabilities,
                  fallback: const SizedBox.shrink(),
                  child: TutorTarget(
                    anchor: TutorAnchor.registerSessionMenuButton,
                    child: _RegisterSessionPill(
                      sessionNumber:
                          viewModel.activeRegisterSession!.sessionNumber,
                      tooltip: l10n.posSessionMenuTooltip,
                      busy:
                          viewModel.isCreatingCashMovement ||
                          viewModel.isClosingRegisterSession,
                      onTap: () => _showRegisterSessionMenu(context),
                    ),
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
                    integrationsRepository: integrationsRepository,
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
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final didClose = await showAdaptiveModalBottomSheet<bool>(
      context: context,
      size: AdaptiveModalSize.standard,
      builder: (context) {
        return RegisterSessionCloseSheet(
          closeErrorDetail: () => viewModel.registerSessionErrorMessage,
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

    if (didClose != true) {
      return;
    }
    final sessionId = viewModel.lastClosedRegisterSessionId;
    if (sessionId == null) {
      return;
    }
    // Offer the cashier the thermal Z-Report drawer copy right after close.
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.sessionClosedPrintZReportPrompt),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: l10n.sessionPrintZReportThermal,
          onPressed: () =>
              _printClosedSessionZReport(messenger, l10n, sessionId),
        ),
      ),
    );
  }

  Future<void> _printClosedSessionZReport(
    ScaffoldMessengerState messenger,
    AppLocalizations l10n,
    int sessionId,
  ) async {
    final printed = await viewModel.printClosedRegisterSessionZReport(
      sessionId,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          printed
              ? l10n.sessionZReportPrintedMessage
              : l10n.sessionZReportFailedMessage,
        ),
      ),
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

  Future<void> _showPosCashPurchaseSheet(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final submission = await showPosCashPurchaseSheet(
      context,
      contactRepository: contactRepository,
      catalogRepository: catalogRepository,
      purchaseRepository: purchaseRepository,
      shopSettingsRepository: shopSettingsRepository,
    );
    if (submission == null) {
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          l10n.posCashPurchaseSuccessMessage(
            submission.draftNumber,
            formatMoney(submission.total),
          ),
        ),
      ),
    );
    // The purchase changed on-hand quantities; refresh the sale catalog so the
    // cashier sells against the new stock right away.
    viewModel.loadCatalog();
  }

  /// Opens the labeled register-session menu — every register action presented
  /// as an icon + title + description tile, gated by the same capabilities the
  /// old toolbar icons were.
  Future<void> _showRegisterSessionMenu(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final session = viewModel.activeRegisterSession;
    if (session == null) {
      return;
    }
    final actions = _sessionActions(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final spacing = AdaptiveSpacing.of(sheetContext);
        final colors = sheetContext.pointyColors;
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(
                    spacing.lg,
                    spacing.xs,
                    spacing.lg,
                    spacing.sm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.posSessionMenuTitle,
                        style: Theme.of(sheetContext).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.activeRegisterSessionLabel(session.sessionNumber),
                        style: Theme.of(
                          sheetContext,
                        ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                      ),
                    ],
                  ),
                ),
                for (final action in actions)
                  _PosSessionActionTile(
                    action: action,
                    onInvoke: () {
                      Navigator.of(sheetContext).pop();
                      action.onTap();
                    },
                  ),
                SizedBox(height: spacing.sm),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The register actions available right now, each gated by the capability that
  /// backed its old toolbar icon. The pill itself requires POS access, so the
  /// refresh action (also POS-access) guarantees the menu is never empty.
  List<_PosSessionAction> _sessionActions(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return [
      if (capabilities.canCreateRegisterCashMovement) ...[
        _PosSessionAction(
          icon: Icons.add_circle_outline,
          id: 'pay_in',
          label: l10n.payInRegisterSessionButton,
          description: l10n.payInRegisterSessionDescription,
          onTap: () =>
              _showCashMovementSheet(context, RegisterCashMovementType.payIn),
        ),
        _PosSessionAction(
          icon: Icons.remove_circle_outline,
          id: 'pay_out',
          label: l10n.payOutRegisterSessionButton,
          description: l10n.payOutRegisterSessionDescription,
          onTap: () =>
              _showCashMovementSheet(context, RegisterCashMovementType.payOut),
        ),
      ],
      // The drawer-paid quick purchase (bread/milk vendors at the door): its
      // own narrow permission, granted per-cashier by the owner.
      if (capabilities.canCreatePosCashPurchase)
        _PosSessionAction(
          icon: Icons.shopping_basket_outlined,
          id: 'cash_purchase',
          label: l10n.posCashPurchaseTitle,
          description: l10n.posCashPurchaseDescription,
          onTap: () => _showPosCashPurchaseSheet(context),
        ),
      if (capabilities.canCollectCustomerDebt)
        _PosSessionAction(
          icon: Icons.request_quote_outlined,
          id: 'collect_debt',
          label: l10n.collectDebtTitle,
          description: l10n.collectDebtSessionDescription,
          onTap: () => showCollectDebtDialog(
            context,
            contactRepository: contactRepository,
            printingRepository: printingRepository,
            shopSettingsRepository: shopSettingsRepository,
          ),
        ),
      if (capabilities.canAccessPos)
        _PosSessionAction(
          icon: Icons.sync,
          id: 'refresh_catalog',
          label: l10n.refreshCatalogTooltip,
          description: l10n.refreshCatalogDescription,
          onTap: viewModel.loadCatalog,
        ),
      if (capabilities.canCloseRegisterSession)
        _PosSessionAction(
          icon: Icons.lock_outline,
          id: 'close_session',
          label: l10n.closeRegisterSessionTooltip,
          description: l10n.closeRegisterSessionDescription,
          danger: true,
          onTap: () => _showCloseRegisterSessionSheet(context),
        ),
    ];
  }
}

/// One labeled action in the POS session menu.
class _PosSessionAction {
  const _PosSessionAction({
    required this.id,
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
    this.danger = false,
  });

  /// Stable name for this action, independent of its Arabic label — what a
  /// lesson points at, so rewording the menu cannot silently re-aim a step.
  final String id;

  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;
  final bool danger;
}

/// The tappable session control in the POS app bar: shows the active session and
/// opens the labeled session-actions menu. Replaces the row of icon-only buttons
/// users couldn't decode.
class _RegisterSessionPill extends StatelessWidget {
  const _RegisterSessionPill({
    required this.sessionNumber,
    required this.tooltip,
    required this.onTap,
    this.busy = false,
  });

  final String sessionNumber;
  final String tooltip;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final onBar = IconTheme.of(context).color ?? Colors.white;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: Center(
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: onBar.withValues(alpha: 0.16),
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 7, 8, 7),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (busy)
                      SizedBox.square(
                        dimension: 16,
                        child: PointySpinner(strokeWidth: 2, color: onBar),
                      )
                    else
                      Icon(
                        Icons.point_of_sale_outlined,
                        size: 18,
                        color: onBar,
                      ),
                    const SizedBox(width: 6),
                    Text(
                      l10n.activeRegisterSessionLabel(sessionNumber),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: onBar,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.expand_more_rounded, size: 18, color: onBar),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labeled action tile in the session menu (icon + title + description),
/// mirroring the purchase-order action sheet so the two feel consistent.
class _PosSessionActionTile extends StatelessWidget {
  const _PosSessionActionTile({required this.action, required this.onInvoke});

  final _PosSessionAction action;
  final VoidCallback onInvoke;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final accent = action.danger ? colors.danger : colors.primaryStrong;
    return TutorTarget(
      anchor: TutorAnchor.registerSessionAction,
      id: action.id,
      child: ListTile(
        onTap: onInvoke,
        leading: CircleAvatar(
          backgroundColor: accent.withValues(alpha: 0.12),
          foregroundColor: accent,
          child: Icon(action.icon),
        ),
        title: Text(
          action.label,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: action.danger ? colors.danger : colors.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          action.description,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
      ),
    );
  }
}

class _PosWorkspace extends StatefulWidget {
  const _PosWorkspace({
    required this.viewModel,
    required this.contactRepository,
    required this.integrationsRepository,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final IntegrationsRepository integrationsRepository;
  final AuthorizationCapabilities capabilities;

  @override
  State<_PosWorkspace> createState() => _PosWorkspaceState();
}

class _PosWorkspaceState extends State<_PosWorkspace> {
  /// Show the top-up button only when this shop actually resells something
  /// and this cashier is allowed to. Both halves matter: the permission is on
  /// by default for cashiers, so the shop's own configuration is what keeps
  /// the button out of a grocer's till.
  List<String> get _rechargeProviders => widget.capabilities.canUseIntegrations
      ? widget.viewModel.rechargeIntegrations
      : const [];

  Future<void> _openRecharge(String providerKey) async {
    final draft = await showIntegrationRecharge(
      context: context,
      viewModel: IntegrationRechargeViewModel(
        repository: widget.integrationsRepository,
        provider: integrationProviderKeyFromJson(providerKey),
      ),
    );
    if (draft == null || !mounted) {
      return;
    }
    widget.viewModel.addIntegrationRecharge(draft);
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(l10n.rechargeAddedToCart)));
  }

  // The cart pane publishes its checkout closure here so Ctrl/Cmd+Enter runs the
  // same flow as the footer button, even while the catalog search has focus.
  final PosCheckoutController _checkoutController = PosCheckoutController();

  void _requestCheckout() => _checkoutController.onCheckout?.call();

  /// F1 — hold the current invoice and open a fresh one (the multi-invoice
  /// flow). No-op when the cart is empty (the active session is already blank)
  /// or a checkout is in progress, matching the on-screen switcher button.
  void _newInvoice() => widget.viewModel.startNewSaleSession();

  /// Page Down / Page Up — cycle through the held invoices (next / previous),
  /// wrapping around. Returns whether it moved (so the key is only consumed when
  /// there is more than one open invoice to cycle).
  bool _cycleHeldInvoice({required bool forward}) =>
      widget.viewModel.cycleActiveSaleSession(forward: forward);

  /// F2 / arrow keys — cycle the active line (last scanned, catalog-tapped, or
  /// tapped-to-select) through the product's sellable units. Arrow Up/Right =
  /// next, Down/Left = previous; F2 (no [key]) advances forward. Wraps around.
  bool _cycleActiveLineUnit([LogicalKeyboardKey? key]) {
    final viewModel = widget.viewModel;
    final line = viewModel.activeCartLine;
    if (line == null) {
      return false;
    }
    final options = sellableUnitOptions(
      AppLocalizations.of(context)!,
      Product.fromVariant(line.variant),
      line.variant.unitPrice,
    );
    if (options.length < 2) {
      return false;
    }
    final currentCode = line.unitCode.isEmpty
        ? options.first.code
        : line.unitCode;
    var index = options.indexWhere((option) => option.code == currentCode);
    if (index == -1) {
      index = 0;
    }
    final forward =
        key == null ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowRight;
    final next =
        options[(index + (forward ? 1 : -1) + options.length) % options.length];
    return viewModel.setActiveCartLineUnit(next);
  }

  /// F4 — delete the active line, surfacing an Undo so a mis-fire on a
  /// customer's in-progress order is one tap to recover.
  void _deleteActiveLine() {
    final viewModel = widget.viewModel;
    final line = viewModel.activeCartLine;
    if (line == null) {
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final removed = viewModel.removeCartLine(
      line.lineKey,
      source: 'keyboard_delete_line',
    );
    if (removed == null) {
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.cartLineRemovedMessage),
          action: SnackBarAction(
            label: l10n.undoButton,
            onPressed: () =>
                viewModel.restoreCartLine(removed.line, removed.index),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final viewModel = widget.viewModel;
    final capabilities = widget.capabilities;

    final scanEnabled =
        capabilities.canCheckoutSale &&
        !viewModel.isCheckingOut &&
        !viewModel.isResolvingBarcode;

    // Three scan sources, one handler. The counter wedge types; a paired
    // phone posts; a camera on a stand watches the counter. All three add
    // products the same way under the same gate, and only the source tag
    // tells them apart in telemetry — which is the whole reason a new source
    // costs a wrapper here rather than a second scanning model everywhere.
    return CameraWedgeListener(
      controller: CameraWedgeScope.controllerOf(context),
      enabled: scanEnabled,
      onScan: (barcode) =>
          viewModel.addVariantByBarcode(barcode, source: 'camera_wedge'),
      child: CompanionScanListener(
        bridge: CompanionScope.bridgeOf(context),
        enabled: scanEnabled,
        onScan: (barcode) =>
            viewModel.addVariantByBarcode(barcode, source: 'companion_camera'),
        child: BarcodeScanListener(
          enabled: scanEnabled,
          onBarcodeScanned: (barcode) => viewModel.addVariantByBarcode(
            barcode,
            source: 'hardware_scanner',
          ),
          // A scan only ever adds its own product; it never touches a line's
          // quantity. Arrow keys flip the active line's unit of measure (the
          // legacy shortcut, kept alongside the F-keys below).
          onArrowKey: (key) => _cycleActiveLineUnit(key),
          // Legacy till function keys (muscle memory from older POS systems):
          // F1 hold-and-open-new-invoice, F2 cycle the active line's unit,
          // F4 delete the active line. Dispatched through the global key handler
          // above — NOT focus-tree Shortcuts, which silently die whenever focus
          // parks outside the workspace (an app-bar tap, a closed dialog, or
          // nothing focused at all). Same for the Ctrl/Cmd+Enter checkout chord.
          onFunctionKey: (key) {
            if (key == LogicalKeyboardKey.f1) {
              _newInvoice();
              return true;
            }
            if (key == LogicalKeyboardKey.f2) {
              return _cycleActiveLineUnit();
            }
            if (key == LogicalKeyboardKey.f4) {
              _deleteActiveLine();
              return true;
            }
            // F9 shows or hides cost. A keypress rather than a screen the
            // cashier navigates to, because the question is "what does this
            // cost" asked mid-haggle with a customer across the counter —
            // and the same counter is why it goes away again just as fast.
            // Deliberately far from F4, which deletes.
            if (key == LogicalKeyboardKey.f9) {
              if (!capabilities.canViewTillCost) {
                return false;
              }
              unawaited(viewModel.toggleCostRevealed());
              return true;
            }
            return false;
          },
          // Page Down / Page Up cycle the held invoices, like F1 opens a new one —
          // global (not focus-tree) so they work from anywhere on the POS.
          onPageKey: (key) =>
              _cycleHeldInvoice(forward: key == LogicalKeyboardKey.pageDown),
          onCommandEnter: _requestCheckout,
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
                    rechargeProviders: _rechargeProviders,
                    onRecharge: _openRecharge,
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
                rechargeProviders: _rechargeProviders,
                onRecharge: _openRecharge,
              );
            },
          ),
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
    this.rechargeProviders = const [],
    this.onRecharge,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final List<String> rechargeProviders;
  final void Function(String providerKey)? onRecharge;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Column(
      children: [
        Expanded(
          child: PosCatalogPane(
            viewModel: viewModel,
            capabilities: capabilities,
            rechargeProviders: rechargeProviders,
            onRecharge: onRecharge,
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
