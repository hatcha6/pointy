import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/product.dart';
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
import '../../../shared/unit_options.dart';
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
              // A single, clearly-labeled session control replaces the old row of
              // cryptic icon-only buttons. It shows the active session and opens a
              // labeled menu of everything you can do at the register.
              if (viewModel.activeRegisterSession != null)
                PosAccessGuard(
                  capabilities: capabilities,
                  fallback: const SizedBox.shrink(),
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
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    final didClose = await showAdaptiveModalBottomSheet<bool>(
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
          label: l10n.payInRegisterSessionButton,
          description: l10n.payInRegisterSessionDescription,
          onTap: () =>
              _showCashMovementSheet(context, RegisterCashMovementType.payIn),
        ),
        _PosSessionAction(
          icon: Icons.remove_circle_outline,
          label: l10n.payOutRegisterSessionButton,
          description: l10n.payOutRegisterSessionDescription,
          onTap: () =>
              _showCashMovementSheet(context, RegisterCashMovementType.payOut),
        ),
      ],
      if (capabilities.canCollectCustomerDebt)
        _PosSessionAction(
          icon: Icons.request_quote_outlined,
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
          label: l10n.refreshCatalogTooltip,
          description: l10n.refreshCatalogDescription,
          onTap: viewModel.loadCatalog,
        ),
      if (capabilities.canCloseRegisterSession)
        _PosSessionAction(
          icon: Icons.lock_outline,
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
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
    this.danger = false,
  });

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
            color: onBar.withOpacity(0.16),
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
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: onBar,
                        ),
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
    return ListTile(
      onTap: onInvoke,
      leading: CircleAvatar(
        backgroundColor: accent.withOpacity(0.12),
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
    );
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

  /// F1 — hold the current invoice and open a fresh one (the multi-invoice
  /// flow). No-op when the cart is empty (the active session is already blank)
  /// or a checkout is in progress, matching the on-screen switcher button.
  void _newInvoice() => widget.viewModel.startNewSaleSession();

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

    return BarcodeScanListener(
      enabled:
          capabilities.canCheckoutSale &&
          !viewModel.isCheckingOut &&
          !viewModel.isResolvingBarcode,
      onBarcodeScanned: (barcode) =>
          viewModel.addVariantByBarcode(barcode, source: 'hardware_scanner'),
      // A scan only ever adds its own product; it never touches a line's
      // quantity. Arrow keys flip the active line's unit of measure (the
      // legacy shortcut, kept alongside the F-keys below).
      onArrowKey: (key) => _cycleActiveLineUnit(key),
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
          // Legacy till function keys (muscle memory from older POS systems):
          // F1 hold-and-open-new-invoice, F2 cycle the active line's unit,
          // F4 delete the active line.
          const SingleActivator(LogicalKeyboardKey.f1): _newInvoice,
          const SingleActivator(LogicalKeyboardKey.f2): () =>
              _cycleActiveLineUnit(),
          const SingleActivator(LogicalKeyboardKey.f4): _deleteActiveLine,
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
