import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/barcode/keystroke_wedge.dart';
import '../../../shared/barcode/scan_burst_guard.dart';
import '../../card_verification/moamalat_scope.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../core/result.dart';
import '../../../data/models/contact.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../../treasury/view_models/bank_routing.dart';
import '../view_models/pos_view_model.dart';
import 'direct_services/service_requote_dialog.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../../../data/models/cart_line.dart';
import '../../../data/models/product.dart';
import 'cart_line_note_sheet.dart';
import 'cart_line_tile.dart';
import 'line_price_sheet.dart';
import 'loss_warning_dialog.dart';
import 'pos_batch_picker_sheet.dart';
import 'unit_quantity_sheet.dart';
import 'weight_entry_sheet.dart';
import 'cart_totals.dart';
import 'payment/payment.dart';
import 'pos_sale_session_strip.dart';
import 'checkout_result/pos_checkout_dialog.dart';

/// Lets an ancestor (the POS workspace) trigger the cart's checkout flow from a
/// keyboard shortcut. The cart pane publishes its current checkout closure here
/// on every build — `null` when checkout isn't currently possible.
class PosCheckoutController {
  Future<void> Function()? onCheckout;
}

class PosCartPane extends StatelessWidget {
  const PosCartPane({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    this.onCheckoutSuccess,
    this.checkoutController,
    this.onOpenShopSettings,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onCheckoutSuccess;
  final PosCheckoutController? checkoutController;

  /// Opens the shop settings, for a result that points at one. Null for
  /// someone who may not change them.
  final VoidCallback? onOpenShopSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return CheckoutCapabilityBuilder(
      capabilities: capabilities,
      builder: (context, canCheckout) {
        final isCartLocked = viewModel.isCartFrozen || !canCheckout;
        final spacing = AdaptiveSpacing.of(context);
        final colors = context.pointyColors;
        // A short till spends its height on cart lines, not on the margins
        // around them — the same step down the catalog beside it takes.
        final short = AppBreakpoints.isShortHeight(context);

        // Publish the current checkout closure so the workspace's Ctrl/Cmd+Enter
        // shortcut runs the exact same flow as the footer button.
        final canCheckoutNow =
            canCheckout && viewModel.cart.isNotEmpty && !viewModel.isCartFrozen;
        checkoutController?.onCheckout = canCheckoutNow
            ? () => _checkout(context)
            : null;

        return ColoredBox(
          color: colors.page,
          child: Padding(
            padding: spacing.panePadding(short: short),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  // Keyed by whoever the sale is for. It is the line on screen
                  // that tells the cashier whose invoice this is, so it is also
                  // the honest way for a lesson to check that they attached the
                  // customer the narration named — rather than merely that a
                  // picker closed, which any customer would satisfy.
                  child: TutorTarget(
                    anchor: TutorAnchor.posCartCustomer,
                    id: _saleDraftSubtitle(l10n, viewModel),
                    child: PointyOrderPanel(
                      title: l10n.currentSaleTitle,
                      subtitle: _saleDraftSubtitle(l10n, viewModel),
                      trailing: _PosCartHeaderActions(
                        viewModel: viewModel,
                        isCartLocked: isCartLocked,
                        onEditSettings: () => _showSaleSettingsDialog(context),
                      ),
                      child: _CartScrollContent(
                        viewModel: viewModel,
                        isCartLocked: isCartLocked,
                        capabilities: capabilities,
                      ),
                    ),
                  ),
                ),
                SizedBox(height: short ? spacing.xs : spacing.sm),
                _CheckoutFooter(
                  viewModel: viewModel,
                  capabilities: capabilities,
                  short: short,
                  onCheckout: () => _checkout(context),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _checkout(BuildContext context) async {
    // The whole Pay flow runs with the cart frozen. The payment sheet reads
    // the total once, when it opens: a line tapped in while the forced preview
    // was still in flight once left it asking for the old cart's total, and the
    // server refused the payment as short.
    final step = await viewModel.whilePreparingCheckout(
      () => _takePayment(context),
    );
    if (step == null || !context.mounted) {
      return;
    }
    switch (step) {
      case _ServiceLinesRequoted(:final changes):
        await resolveServiceRequotes(context, viewModel, changes);
      case _SaleCompleted(:final exit):
        _afterSale(exit);
    }
  }

  /// The sale's result has closed: back to an empty till, ready for the next
  /// customer — whose first item may already be the scan that closed it.
  void _afterSale(PosCheckoutCompleted exit) {
    onCheckoutSuccess?.call();
    final scanned = exit.scannedCode;
    if (scanned != null && scanned.trim().isNotEmpty) {
      unawaited(
        viewModel.addVariantByBarcode(
          scanned,
          source: KeystrokeWedge.typingSource ?? 'hardware_scanner',
        ),
      );
    }
    if (exit.openShopSettings) {
      onOpenShopSettings?.call();
      return;
    }
    viewModel.requestSearchFocus();
  }

  /// Everything from Pay to the sale being sent. Null when the cashier backs
  /// out anywhere along the way.
  Future<_PayStep?> _takePayment(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final shortages = viewModel.checkoutStockShortages();
    if (shortages.isNotEmpty) {
      final canOversell = viewModel.allowOverselling;
      // Shops that routinely sell into negative stock can silence this per-sale
      // confirmation from Settings. Only skip it when overselling is allowed —
      // otherwise the dialog is a hard stop and skipping it would just bounce
      // off the server's stock rejection a round-trip later.
      final skipConfirmation = canOversell && !viewModel.warnLowStockBeforeSale;
      if (!skipConfirmation) {
        final shouldContinue = await _showStockWarningDialog(
          context,
          shortages: shortages,
          canOversell: canOversell,
        );
        if (shouldContinue != true) {
          return null;
        }
        if (!context.mounted) {
          return null;
        }
      }
    }

    // An airtime or bill line priced a while ago — a held invoice — is priced
    // again before the customer is asked to pay: a price that moved is the
    // cashier's to decide, not something to find out from a refused charge.
    final requoted = await viewModel.requoteServiceLines();
    if (!context.mounted) {
      return null;
    }
    if (requoted.isNotEmpty) {
      // Resolved once the cart is unfrozen, since dropping a moved price
      // removes its line. Stop the sale here whatever is decided: the total the
      // customer is about to be asked for has either changed or been left on
      // purpose.
      return _ServiceLinesRequoted(requoted);
    }

    // Force one live preview so loss warnings and coupon validation are as
    // fresh as the network allows — but its failure must never dead-end the
    // sale: the checkout itself recomputes discounts server-side.
    await viewModel.refreshDiscountPreview(forceServer: true);
    if (!context.mounted) {
      return null;
    }
    if (viewModel.hasDiscountPreviewError) {
      if (viewModel.couponCode.trim().isNotEmpty) {
        // A typed coupon must be validated before payment — this is the one
        // case the preview genuinely gates.
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text(l10n.discountPreviewUnavailable)),
          );
        return null;
      }
      // Rules may exist but can't be verified right now. The server applies
      // the real discounts at checkout either way — let the cashier decide
      // instead of forcing them to abandon (and hand-write) the sale.
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.sync_problem_outlined),
          title: Text(l10n.discountPreviewFailedCheckoutTitle),
          content: Text(l10n.discountPreviewFailedCheckoutBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancelButton),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.discountPreviewFailedCheckoutConfirm),
            ),
          ],
        ),
      );
      if (proceed != true) {
        return null;
      }
      if (!context.mounted) {
        return null;
      }
    }
    if (viewModel.unappliedCouponCodes.isNotEmpty) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              l10n.discountCouponUnavailable(
                viewModel.unappliedCouponCodes.join('، '),
              ),
            ),
          ),
        );
      return null;
    }
    final lossLines = viewModel.checkoutLossLines();
    if (lossLines.isNotEmpty) {
      final shouldContinue = await showLossWarningDialog(
        context,
        lossLines: lossLines,
        canSellAtLoss: !viewModel.preventSellingAtLoss,
        showAmounts: capabilities.canViewLossAmounts,
      );
      if (shouldContinue != true) {
        return null;
      }
      if (!context.mounted) {
        return null;
      }
    }

    // Shown again, once, when the tender no longer matches the cart's total —
    // with the total re-read, so the second sheet asks for the right amount.
    // "Edit payment" from a refused sale brings the sheet back as often as the
    // cashier asks for it.
    var reopened = false;
    while (true) {
      final payment = await _showPaymentDialog(context);
      if (payment == null || !context.mounted) {
        return null;
      }

      var totalChanged = !viewModel.tenderMatchesTotal(
        payment.payments,
        saleType: payment.saleType,
      );
      if (!totalChanged) {
        // The lines are gone from the cart once the sale is made: whether any
        // was added while the relay was in test mode is told from here.
        final soldInTestMode = viewModel.cart.any(
          (line) => line.integration?.testMode == true,
        );
        final exit = await showPosCheckoutDialog(
          context: context,
          viewModel: viewModel,
          payment: payment,
          soldInTestMode: soldInTestMode,
          showLossAmounts: capabilities.canViewLossAmounts,
          canSendSms: capabilities.canSendSms,
          canOpenSettings: onOpenShopSettings != null,
        );
        if (!context.mounted) {
          return null;
        }
        switch (exit) {
          case PosCheckoutCompleted():
            return _SaleCompleted(exit);
          case PosCheckoutAbandoned():
            return null;
          case PosCheckoutEditPayment():
            continue;
          case PosCheckoutTotalChanged():
            totalChanged = true;
        }
      }
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(l10n.saleCheckoutTotalChanged)));
      if (reopened || !context.mounted) {
        return null;
      }
      reopened = true;
      await viewModel.refreshDiscountPreview(forceServer: true);
      if (!context.mounted) {
        return null;
      }
    }
  }

  Future<void> _showSaleSettingsDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => _SaleSettingsDialog(
        viewModel: viewModel,
        contactRepository: contactRepository,
      ),
    );
  }

  Future<bool?> _showStockWarningDialog(
    BuildContext context, {
    required List<SaleStockShortage> shortages,
    required bool canOversell,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          icon: const Icon(Icons.warning_amber_outlined),
          title: Text(l10n.oversellWarningTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  canOversell
                      ? l10n.oversellWarningMessage
                      : l10n.oversellBlockedMessage,
                ),
                const SizedBox(height: 12),
                for (final shortage in shortages)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      l10n.oversellLine(
                        shortage.productName,
                        formatSaleQuantity(shortage.requested),
                        formatSaleQuantity(shortage.available),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(
                canOversell ? l10n.cancelButton : l10n.reviewCartButton,
              ),
            ),
            if (canOversell)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(l10n.continueSaleButton),
              ),
          ],
        );
      },
    );
  }

  Future<PaymentSheetResult?> _showPaymentDialog(BuildContext context) {
    // Where the shop's card and transfer money goes. Absent in previews and
    // tests, and empty until an owner configures a second bank account — in
    // both cases the sheet is exactly what it was.
    final routing = BankRoutingScope.maybeOf(context);
    // Nothing may redraw the sell screen while money is being taken.
    return viewModel.duringCriticalInteraction(
      () => showPosPaymentSheet(
        context: context,
        total: viewModel.total,
        bankAccounts: routing?.bankAccounts ?? const [],
        accountForTerminal: routing?.accountForTerminal,
        enableCashPayments: viewModel.enableCashPayments,
        enableCardPayments: viewModel.enableCardPayments,
        enableTransferPayments: viewModel.enableTransferPayments,
        requireCardReceipt: viewModel.requireCardPaymentReceipt,
        trustedCardTerminalIds: viewModel.trustedCardTerminalIds,
        hasCustomer: viewModel.selectedCustomer != null,
        requireCustomerForCredit: viewModel.requireCustomerForCredit,
        proposedDueDate: viewModel.proposedCreditDueDate,
        isStaffAccount: viewModel.selectedCustomer?.isStaffAccount ?? false,
        moamalatRepository: viewModel.enableCardPayments
            ? MoamalatScope.maybeOf(context)
            : null,
      ),
    );
  }
}

String _saleDraftSubtitle(AppLocalizations l10n, PosViewModel viewModel) {
  final customerName = viewModel.selectedCustomer?.fullName.trim();
  if (customerName != null && customerName.isNotEmpty) {
    return customerName;
  }
  return l10n.walkInCustomerLabel;
}

class _CartScrollContent extends StatefulWidget {
  const _CartScrollContent({
    required this.viewModel,
    required this.isCartLocked,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final bool isCartLocked;

  /// Decides whether a row may show cost and offer a reprice. The server
  /// is the authority for both; this only hides affordances nobody could
  /// use.
  final AuthorizationCapabilities capabilities;

  @override
  State<_CartScrollContent> createState() => _CartScrollContentState();
}

class _CartScrollContentState extends State<_CartScrollContent> {
  // The cart's keyboard scope. It only steals focus from the catalog search
  // when the cashier taps a line, so plain typing keeps scanning barcodes. Once
  // a line is focused, +/- step its quantity and digits set an exact quantity.
  final FocusNode _focusNode = FocusNode(debugLabel: 'pos_cart_keyboard');
  String? _focusedLineKey;
  String _pendingQuantity = '';
  // Rejects scanner-speed keystrokes so a wedge burst can never become a
  // line quantity (the scan itself is BarcodeScanListener's job).
  final ScanBurstGuard _scanBurstGuard = ScanBurstGuard();
  int _lastLineCount = -1;

  PosViewModel get _viewModel => widget.viewModel;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    setState(() {
      if (!_focusNode.hasFocus) {
        _pendingQuantity = '';
      }
    });
  }

  List<CartLine> get _visibleLines =>
      _viewModel.cart.reversed.toList(growable: false);

  CartLine? _focusedLine(List<CartLine> lines) {
    if (lines.isEmpty) {
      return null;
    }
    final key = _focusedLineKey;
    if (key != null) {
      for (final line in lines) {
        if (line.lineKey == key) {
          return line;
        }
      }
    }
    return lines.first;
  }

  void _focusLine(CartLine line) {
    setState(() {
      _focusedLineKey = line.lineKey;
      _pendingQuantity = '';
    });
    // Mirror the selection into the view model so the workspace F2/F4 shortcuts
    // (which read activeCartLine) act on the line the cashier just tapped.
    _viewModel.focusCartLine(line.lineKey);
    _focusNode.requestFocus();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || widget.isCartLocked) {
      return KeyEventResult.ignored;
    }
    // Let modified combos (e.g. Ctrl/Cmd+Enter for checkout) bubble up to the
    // workspace shortcuts instead of being treated as quantity entry.
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    // Only treat keystrokes as line-quantity entry when this scope itself holds
    // the primary focus. Tapping into a text field inside the pane moves the
    // primary focus to that field; its digits must reach the field, not be
    // hijacked as quantity.
    if (!node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    final line = _focusedLine(_visibleLines);
    if (line == null) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;

    final digit = _digitFor(key);
    if (digit != null) {
      final rollback = _scanBurstGuard.onDigit(
        _pendingQuantity,
        DateTime.now(),
      );
      if (rollback != null) {
        // A wedge is typing, not the cashier — roll the pending entry back to
        // its pre-burst value and swallow the keystroke. The scan itself is
        // recognized (or safely dropped) by BarcodeScanListener.
        if (_pendingQuantity != rollback) {
          setState(() => _pendingQuantity = rollback);
        }
        return KeyEventResult.handled;
      }
      if (_pendingQuantity.length < 7) {
        setState(() => _pendingQuantity = '$_pendingQuantity$digit');
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.period ||
        key == LogicalKeyboardKey.numpadDecimal) {
      // Fractional entry (2.5 of anything) is the cashier's choice — allowed for
      // every product; at most one decimal point.
      final rollback = _scanBurstGuard.onDigit(
        _pendingQuantity,
        DateTime.now(),
      );
      if (rollback != null) {
        if (_pendingQuantity != rollback) {
          setState(() => _pendingQuantity = rollback);
        }
        return KeyEventResult.handled;
      }
      if (!_pendingQuantity.contains('.') && _pendingQuantity.length < 6) {
        setState(
          () => _pendingQuantity = _pendingQuantity.isEmpty
              ? '0.'
              : '$_pendingQuantity.',
        );
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      if (_pendingQuantity.isEmpty) {
        return KeyEventResult.ignored;
      }
      setState(
        () => _pendingQuantity = _pendingQuantity.substring(
          0,
          _pendingQuantity.length - 1,
        ),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_scanBurstGuard.shouldSwallowCommit(DateTime.now())) {
        // Tail of a scanner burst (reaches here only when the listener is
        // disabled or the code was too short) — never commit it as quantity.
        return KeyEventResult.handled;
      }
      _applyPendingQuantity(line);
      // Done editing this line — return focus to the search field so the next
      // item can be searched or scanned immediately. Requesting search focus
      // blurs this scope (deselecting the line), which is the intended "done"
      // state. Only ever fires on the deliberate Enter commit, never mid-typing.
      _viewModel.requestSearchFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.add ||
        key == LogicalKeyboardKey.numpadAdd ||
        key == LogicalKeyboardKey.equal) {
      setState(() => _pendingQuantity = '');
      _viewModel.incrementCartLine(line.lineKey, source: 'keyboard');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      setState(() => _pendingQuantity = '');
      _viewModel.decrementCartLine(line.lineKey, source: 'keyboard');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_pendingQuantity.isNotEmpty) {
        // First Esc just clears the half-typed quantity; the line stays focused
        // so the cashier can retype without losing their place.
        setState(() => _pendingQuantity = '');
      } else {
        // Nothing pending: the cashier is done with this line. Drop the cart
        // scope and hand focus back to the search field (the request is a no-op
        // if the search field can't take focus right now, e.g. behind a sheet).
        _focusNode.unfocus();
        _viewModel.requestSearchFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _applyPendingQuantity(CartLine line) {
    final quantity = double.tryParse(_pendingQuantity);
    setState(() => _pendingQuantity = '');
    if (quantity != null && quantity > 0) {
      _viewModel.setCartLineQuantity(
        line.lineKey,
        quantity,
        source: 'keyboard',
      );
    }
  }

  /// Removes a cart line and surfaces a SnackBar with an Undo action, so a
  /// mis-tap on a customer's in-progress order is one tap to recover.
  void _deleteCartLineWithUndo(String lineKey) {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final removed = _viewModel.removeCartLine(
      lineKey,
      source: 'cart_delete_button',
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
                _viewModel.restoreCartLine(removed.line, removed.index),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final visibleLines = _visibleLines;
    // A structural cart change (a scan/tap added or removed a line) invalidates
    // any half-typed quantity, so the banner can't show stale scanned digits.
    if (visibleLines.length != _lastLineCount) {
      _lastLineCount = visibleLines.length;
      _pendingQuantity = '';
    }
    final focusedLine = _focusedLine(visibleLines);
    final scopeFocused = _focusNode.hasFocus;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKey,
      child: Column(
        children: [
          Expanded(
            child: visibleLines.isEmpty
                ? ListView(
                    padding: EdgeInsetsDirectional.fromSTEB(
                      spacing.md,
                      spacing.sm,
                      spacing.md,
                      spacing.md,
                    ),
                    children: [
                      SizedBox(
                        height: 240,
                        child: PointyEmptyState(
                          icon: Icons.shopping_cart_outlined,
                          title: l10n.emptyCart,
                          message: l10n.emptyCartMessage,
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    padding: EdgeInsetsDirectional.fromSTEB(
                      spacing.md,
                      spacing.sm,
                      spacing.md,
                      spacing.md,
                    ),
                    itemCount: visibleLines.length,
                    separatorBuilder: (context, index) =>
                        Divider(height: 1, color: colors.line),
                    itemBuilder: (context, index) {
                      final line = visibleLines[index];
                      return TutorTarget(
                        anchor: TutorAnchor.posCartLine,
                        id: line.variant.sku,
                        child: CartLineTile(
                          line: line,
                          selected:
                              scopeFocused &&
                              focusedLine?.lineKey == line.lineKey,
                          onSelect: widget.isCartLocked
                              ? null
                              : () => _focusLine(line),
                          onAdd: widget.isCartLocked
                              ? null
                              : () => _viewModel.incrementCartLine(
                                  line.lineKey,
                                  source: 'cart_quantity_button',
                                ),
                          onRemove: widget.isCartLocked
                              ? null
                              : () => _viewModel.decrementCartLine(
                                  line.lineKey,
                                  source: 'cart_quantity_button',
                                ),
                          onDelete: widget.isCartLocked
                              ? null
                              : () => _deleteCartLineWithUndo(line.lineKey),
                          onEditQuantity: widget.isCartLocked
                              ? null
                              : () => _editLineQuantity(context, line),
                          onSwitchUnit:
                              widget.isCartLocked ||
                                  !Product.fromVariant(
                                    line.variant,
                                  ).hasSellableUnits
                              ? null
                              : () => _editLineUnit(context, line),
                          onEditNote:
                              widget.isCartLocked ||
                                  !_viewModel.enableKitchenOperations
                              ? null
                              : () => _editLineNote(context, line),
                          // Only lot-tracked lines offer a lot to change, and
                          // only when the shop actually has identified stock.
                          // A serialised pack's lot is the article's own —
                          // pinning another would contradict the unit.
                          onPickBatch:
                              widget.isCartLocked ||
                                  !line.variant.trackingMode.tracksLots ||
                                  line.variant.trackingMode.tracksUnits ||
                                  _viewModel.trackedStockRepository == null
                              ? null
                              : () => _editLineBatch(context, line),
                          // A top-up's price comes from the provider's live
                          // quote plus the shop's markup — it is not the
                          // shop's number to type over.
                          onEditPrice:
                              widget.isCartLocked ||
                                  !widget.capabilities.canOverrideLinePrice ||
                                  line.isProviderLine
                              ? null
                              : () => _editLinePrice(context, line),
                          unitCost: widget.capabilities.canViewTillCost
                              ? _viewModel.costForVariant(line.variant.id)
                              : null,
                          isLoadingCost:
                              widget.capabilities.canViewTillCost &&
                              _viewModel.isCostRevealed &&
                              _viewModel.isLoadingCosts,
                        ),
                      );
                    },
                  ),
          ),
          if (_pendingQuantity.isNotEmpty && focusedLine != null)
            PendingQuantityBanner(
              quantity: _pendingQuantity,
              productName: focusedLine.variant.productLabel,
            ),
        ],
      ),
    );
  }

  /// Pin a different lot to this line.
  ///
  /// The customer who asks for a longer expiry is asking for a different lot,
  /// and refusing them would mean voiding the line and starting again. Picking
  /// the one the till would have chosen anyway clears the pin rather than
  /// setting it, so the line goes back to first-expiring-first-out.
  Future<void> _editLinePrice(BuildContext context, CartLine line) async {
    final price = await showLinePriceSheet(
      context,
      line: line,
      unitCost: _viewModel.costForVariant(line.variant.id),
    );
    if (price == null) return; // dismissed, which is not the same as cleared
    _viewModel.setCartLinePrice(
      line.lineKey,
      price == clearedLinePrice ? null : price,
    );
  }

  Future<void> _editLineBatch(BuildContext context, CartLine line) async {
    final repository = _viewModel.trackedStockRepository;
    if (repository == null) {
      return;
    }
    final batch = await showPosBatchPickerSheet(
      context,
      repository: repository,
      variantId: line.variant.id,
      productLabel: line.variant.displayLabel,
    );
    if (batch == null || !context.mounted) {
      return;
    }
    _viewModel.setCartLineBatch(line.lineKey, batch);
  }

  Future<void> _editLineQuantity(BuildContext context, CartLine line) async {
    // Multi-unit lines reuse the unit + quantity sheet so the cashier can change
    // both at once; plain weighted lines keep the lighter weight entry.
    if (Product.fromVariant(line.variant).hasSellableUnits) {
      await _editLineUnit(context, line);
      return;
    }
    final weight = await _viewModel.duringCriticalInteraction(
      () => showWeightEntrySheet(
        context,
        variant: line.variant,
        initialQuantity: line.quantity,
      ),
    );
    if (weight != null && context.mounted) {
      _viewModel.setCartLineQuantity(line.lineKey, weight);
    }
  }

  Future<void> _editLineUnit(BuildContext context, CartLine line) async {
    final selection = await _viewModel.duringCriticalInteraction(
      () => showUnitQuantitySheet(
        context,
        product: Product.fromVariant(line.variant),
        variant: line.variant,
        initialUnitCode: line.unitCode.isEmpty
            ? line.variant.unit
            : line.unitCode,
        initialQuantity: line.quantity,
      ),
    );
    if (selection != null && context.mounted) {
      _viewModel.setCartLineUnit(line.lineKey, selection.unit);
      _viewModel.setCartLineQuantity(line.lineKey, selection.quantity);
    }
  }

  Future<void> _editLineNote(BuildContext context, CartLine line) async {
    final note = await showCartLineNoteSheet(context, line: line);
    if (note != null && context.mounted) {
      _viewModel.setCartLineNote(line.lineKey, note);
    }
  }

  static String? _digitFor(LogicalKeyboardKey key) => _digitKeys[key];
}

final Map<LogicalKeyboardKey, String> _digitKeys = {
  LogicalKeyboardKey.digit0: '0',
  LogicalKeyboardKey.digit1: '1',
  LogicalKeyboardKey.digit2: '2',
  LogicalKeyboardKey.digit3: '3',
  LogicalKeyboardKey.digit4: '4',
  LogicalKeyboardKey.digit5: '5',
  LogicalKeyboardKey.digit6: '6',
  LogicalKeyboardKey.digit7: '7',
  LogicalKeyboardKey.digit8: '8',
  LogicalKeyboardKey.digit9: '9',
  LogicalKeyboardKey.numpad0: '0',
  LogicalKeyboardKey.numpad1: '1',
  LogicalKeyboardKey.numpad2: '2',
  LogicalKeyboardKey.numpad3: '3',
  LogicalKeyboardKey.numpad4: '4',
  LogicalKeyboardKey.numpad5: '5',
  LogicalKeyboardKey.numpad6: '6',
  LogicalKeyboardKey.numpad7: '7',
  LogicalKeyboardKey.numpad8: '8',
  LogicalKeyboardKey.numpad9: '9',
};

class _PosCartHeaderActions extends StatelessWidget {
  const _PosCartHeaderActions({
    required this.viewModel,
    required this.isCartLocked,
    required this.onEditSettings,
  });

  final PosViewModel viewModel;
  final bool isCartLocked;
  final VoidCallback onEditSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final couponCode = viewModel.couponCode.trim();
    final hasCoupon = couponCode.isNotEmpty;
    final hasIssue =
        viewModel.hasDiscountPreviewError ||
        viewModel.unappliedCouponCodes.isNotEmpty;
    final hasActiveSettings =
        viewModel.selectedCustomer != null ||
        hasCoupon ||
        viewModel.appliedDiscounts.isNotEmpty;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PosSaleSessionSwitcher(
          sessions: viewModel.saleSessions,
          canStartNewSession: viewModel.canStartNewSaleSession && !isCartLocked,
          isLocked: isCartLocked,
          onStartNewSession: viewModel.startNewSaleSession,
          onSelectSession: viewModel.switchSaleSession,
          onDiscardSession: viewModel.discardSaleSession,
        ),
        TutorTarget(
          anchor: TutorAnchor.posSaleSettingsButton,
          child: IconButton(
            key: const ValueKey('sale_draft_settings_button'),
            tooltip: l10n.saleDraftSettingsActionTooltip,
            onPressed: isCartLocked ? null : onEditSettings,
            icon: const Icon(Icons.tune),
            color: hasIssue
                ? colors.danger
                : hasActiveSettings
                ? colors.primaryStrong
                : null,
          ),
        ),
        IconButton(
          tooltip: l10n.clearCartTooltip,
          onPressed: viewModel.cart.isEmpty || isCartLocked
              ? null
              : () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (_) => PointyDestructiveConfirmationDialog(
                      icon: Icons.remove_shopping_cart_outlined,
                      title: l10n.clearCartConfirmTitle,
                      message: l10n.clearCartConfirmMessage,
                      confirmLabel: l10n.clearButton,
                    ),
                  );
                  if (confirmed == true) {
                    viewModel.clearCart();
                  }
                },
          icon: const Icon(Icons.delete_outline),
          color: colors.danger,
        ),
      ],
    );
  }
}

class _SaleSettingsDialog extends StatefulWidget {
  const _SaleSettingsDialog({
    required this.viewModel,
    required this.contactRepository,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;

  @override
  State<_SaleSettingsDialog> createState() => _SaleSettingsDialogState();
}

class _SaleSettingsDialogState extends State<_SaleSettingsDialog> {
  late var _selectedCustomer = widget.viewModel.selectedCustomer;
  var _loadingStaffAccount = false;
  var _staffAccountFailed = false;
  late final TextEditingController _controller = TextEditingController(
    text: widget.viewModel.couponCode,
  );

  String get _currentCode => _controller.text.trim();

  bool get _matchesSavedCode =>
      _currentCode == widget.viewModel.couponCode.trim();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasCoupon = _currentCode.isNotEmpty;
    final hasInvalidCoupon =
        _matchesSavedCode && widget.viewModel.unappliedCouponCodes.isNotEmpty;

    return AlertDialog(
      icon: const Icon(Icons.tune),
      title: Text(l10n.saleDraftSettingsDialogTitle),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TutorTarget(
                anchor: TutorAnchor.contactSelectionTile,
                child: ContactSelectionTile(
                  label: l10n.selectedCustomerLabel,
                  value: _customerLabel(l10n),
                  placeholder: l10n.walkInCustomerLabel,
                  icon: _selectedCustomer?.isStaffAccount == true
                      ? Icons.badge_outlined
                      : Icons.person_pin_circle_outlined,
                  enabled: !widget.viewModel.isCheckingOut,
                  onSelect: _selectCustomer,
                  onClear: () => setState(() => _selectedCustomer = null),
                  allowClear: _selectedCustomer != null,
                  selectActionIcon: Icons.edit_outlined,
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('sale_settings_staff_account_button'),
                  onPressed:
                      widget.viewModel.isCheckingOut || _loadingStaffAccount
                      ? null
                      : _selectStaffAccount,
                  icon: _loadingStaffAccount
                      ? const SizedBox.square(
                          dimension: 16,
                          child: PointySpinner(strokeWidth: 2),
                        )
                      : const Icon(Icons.badge_outlined),
                  label: Text(l10n.staffAccountSelectAction),
                ),
              ),
              if (_staffAccountFailed)
                Text(
                  l10n.staffAccountLoadError,
                  style: TextStyle(color: context.pointyColors.danger),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                enabled: !widget.viewModel.isCheckingOut,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: l10n.discountCouponCodeLabel,
                  hintText: l10n.discountCouponCodeHint,
                  isDense: true,
                  prefixIcon: const Icon(Icons.confirmation_number_outlined),
                  errorText: hasInvalidCoupon
                      ? l10n.discountCouponUnavailable(
                          widget.viewModel.unappliedCouponCodes.join('، '),
                        )
                      : _matchesSavedCode &&
                            widget.viewModel.hasDiscountPreviewError
                      ? l10n.discountPreviewUnavailable
                      : null,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _apply(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        if (hasCoupon)
          TextButton(
            onPressed: _clear,
            child: Text(l10n.clearCouponCodeTooltip),
          ),
        TextButton(
          onPressed: _refresh,
          child: Text(l10n.refreshDiscountPreviewTooltip),
        ),
        TutorTarget(
          anchor: TutorAnchor.posSaleSettingsSaveButton,
          child: FilledButton(onPressed: _apply, child: Text(l10n.saveButton)),
        ),
      ],
    );
  }

  String _customerLabel(AppLocalizations l10n) {
    final customer = _selectedCustomer;
    if (customer == null) {
      return '';
    }
    return customer.isStaffAccount
        ? '${customer.fullName} · ${l10n.staffAccountBadge}'
        : customer.fullName;
  }

  Future<void> _selectCustomer() async {
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: widget.contactRepository,
    );
    if (customer == null || !mounted) {
      return;
    }
    setState(() => _selectedCustomer = customer);
  }

  /// Puts the sale on the cashier's own staff account, so it comes off their
  /// next payroll run. Needs no customer look-up permission: the server only
  /// ever answers with the signed-in user's own account.
  Future<void> _selectStaffAccount() async {
    setState(() {
      _loadingStaffAccount = true;
      _staffAccountFailed = false;
    });
    final result = await widget.contactRepository.loadStaffAccount();
    if (!mounted) {
      return;
    }
    setState(() {
      _loadingStaffAccount = false;
      switch (result) {
        case Ok<Customer>(value: final customer):
          _selectedCustomer = customer;
        case Error<Customer>():
          _staffAccountFailed = true;
      }
    });
  }

  void _apply() {
    _saveSettings();
    Navigator.of(context).pop();
  }

  void _clear() {
    _controller.clear();
    _saveSettings();
    Navigator.of(context).pop();
  }

  void _refresh() {
    final customerChanged =
        _selectedCustomer?.id != widget.viewModel.selectedCustomer?.id;
    final codeChanged = _currentCode != widget.viewModel.couponCode.trim();
    _saveSettings();
    if (!customerChanged && !codeChanged) {
      unawaited(widget.viewModel.refreshDiscountPreview());
    }
    Navigator.of(context).pop();
  }

  void _saveSettings() {
    if (_selectedCustomer?.id != widget.viewModel.selectedCustomer?.id) {
      widget.viewModel.selectCustomer(_selectedCustomer);
    }
    if (_currentCode != widget.viewModel.couponCode.trim()) {
      widget.viewModel.updateCouponCode(_currentCode);
    }
  }
}

class _CheckoutFooter extends StatelessWidget {
  const _CheckoutFooter({
    required this.viewModel,
    required this.capabilities,
    required this.short,
    required this.onCheckout,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  /// A short screen: the pay button drops to the theme's standard button
  /// height, still the largest target on the till.
  final bool short;
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final canSubmit = viewModel.cart.isNotEmpty && !viewModel.isCartFrozen;

    return PointyStickyActionFooter(
      padding: EdgeInsetsDirectional.fromSTEB(spacing.sm, 6, spacing.sm, 6),
      primaryActionHeight: short ? PointyDimensions.buttonHeight : 52,
      summary: CartTotals(viewModel: viewModel, compact: true),
      primaryAction: CheckoutGuard(
        capabilities: capabilities,
        child: TutorTarget(
          anchor: TutorAnchor.posCheckoutButton,
          child: FilledButton.icon(
            onPressed: canSubmit ? onCheckout : null,
            icon: viewModel.isCheckingOut
                ? const SizedBox.square(
                    dimension: 18,
                    child: PointySpinner(strokeWidth: 2),
                  )
                : const Icon(Icons.payments_outlined),
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                viewModel.isCheckingOut
                    ? l10n.checkoutInProgressButton
                    : l10n.payAmount(formatMoney(viewModel.total)),
                maxLines: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the frozen half of the Pay flow hands back to the rest of it.
sealed class _PayStep {
  const _PayStep();
}

/// A held top-up or bill came back at a new price; the cashier decides once
/// the cart may change again.
final class _ServiceLinesRequoted extends _PayStep {
  const _ServiceLinesRequoted(this.changes);

  final List<ServiceRequote> changes;
}

/// The sale is recorded and its result closed.
final class _SaleCompleted extends _PayStep {
  const _SaleCompleted(this.exit);

  final PosCheckoutCompleted exit;
}
