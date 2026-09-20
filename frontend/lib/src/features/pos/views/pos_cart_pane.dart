import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/barcode/scan_burst_guard.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/integration_card.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../data/services/order_document_service.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/contact_picker_sheet.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../../../shared/responsive/responsive.dart';
import '../../settings/views/integration_presentation.dart';
import '../view_models/pos_view_model.dart';
import '../../../shared/tutor/anchors.dart';
import '../../../shared/tutor/tutor_target.dart';
import '../../../data/models/cart_line.dart';
import '../../../data/models/product.dart';
import 'cart_line_note_sheet.dart';
import 'cart_line_tile.dart';
import 'pos_batch_picker_sheet.dart';
import 'unit_quantity_sheet.dart';
import 'weight_entry_sheet.dart';
import 'cart_totals.dart';
import 'payment/payment.dart';
import 'pos_sale_session_strip.dart';
import 'public_invoice_dialog.dart';

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
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onCheckoutSuccess;
  final PosCheckoutController? checkoutController;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return CheckoutCapabilityBuilder(
      capabilities: capabilities,
      builder: (context, canCheckout) {
        final isCartLocked = viewModel.isCheckingOut || !canCheckout;
        final spacing = AdaptiveSpacing.of(context);
        final colors = context.pointyColors;

        // Publish the current checkout closure so the workspace's Ctrl/Cmd+Enter
        // shortcut runs the exact same flow as the footer button.
        final canCheckoutNow =
            canCheckout &&
            viewModel.cart.isNotEmpty &&
            !viewModel.isCheckingOut;
        checkoutController?.onCheckout = canCheckoutNow
            ? () => _checkout(context)
            : null;

        return ColoredBox(
          color: colors.page,
          child: Padding(
            padding: spacing.compactPadding,
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
                      ),
                    ),
                  ),
                ),
                SizedBox(height: spacing.sm),
                _CheckoutFooter(
                  viewModel: viewModel,
                  capabilities: capabilities,
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
          return;
        }
        if (!context.mounted) {
          return;
        }
      }
    }

    // Force one live preview so loss warnings and coupon validation are as
    // fresh as the network allows — but its failure must never dead-end the
    // sale: the checkout itself recomputes discounts server-side.
    await viewModel.refreshDiscountPreview(forceServer: true);
    if (!context.mounted) {
      return;
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
        return;
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
        return;
      }
      if (!context.mounted) {
        return;
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
      return;
    }
    final lossLines = viewModel.checkoutLossLines();
    if (lossLines.isNotEmpty) {
      final shouldContinue = await _showLossWarningDialog(
        context,
        lossLines: lossLines,
        canSellAtLoss: !viewModel.preventSellingAtLoss,
      );
      if (shouldContinue != true) {
        return;
      }
      if (!context.mounted) {
        return;
      }
    }

    final payment = await _showPaymentDialog(context);
    if (payment == null) {
      return;
    }

    final outcome = await viewModel.checkoutCurrentSale(
      payments: payment.payments,
      saleType: payment.saleType,
      validUntil: payment.validUntil,
      dueDate: payment.dueDate,
      reserveStock: payment.reserveStock,
      printProof: payment.printProof,
    );

    if (!context.mounted) {
      return;
    }

    if (outcome.isStockRejected) {
      await _showStockWarningDialog(
        context,
        shortages: outcome.shortages,
        canOversell: false,
      );
      return;
    }
    if (outcome.isLossRejected) {
      await _showLossWarningDialog(
        context,
        lossLines: outcome.lossLines,
        canSellAtLoss: false,
      );
      return;
    }
    final creditLimit = outcome.creditLimit;
    if (creditLimit != null) {
      await _showCreditLimitDialog(context, credit: creditLimit);
      return;
    }
    if (outcome.isSessionExpired) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.saleCheckoutSessionExpired)),
        );
      return;
    }

    // The provider has already been paid (or refused) by now. Anything other
    // than a clean charge is told to the cashier in a dialog rather than a
    // snackbar: one of these states means money may have moved and nobody
    // knows, which is not something to let scroll past.
    if (outcome.isSuccess && outcome.recharges.any((row) => !row.isCharged)) {
      await _showRechargeOutcomeDialog(context, outcome.recharges);
      if (!context.mounted) return;
    }

    final receiptNumber = outcome.order?.receiptNumber;
    var message = outcome.isSuccess
        ? receiptNumber == null || receiptNumber.isEmpty
              ? l10n.saleCheckoutSuccess
              : l10n.saleCheckoutSuccessWithReceipt(receiptNumber)
        : l10n.saleCheckoutError;
    if (outcome.isSuccess && payment.shareInvoiceAfterPayment) {
      final order = outcome.order;
      final shareStatus = order == null
          ? OrderDocumentActionStatus.failed
          : await viewModel.sharePaidInvoice(order);
      if (!context.mounted) {
        return;
      }
      message = switch (shareStatus) {
        OrderDocumentActionStatus.completed =>
          '$message ${l10n.invoiceShareSuccess}',
        OrderDocumentActionStatus.failed =>
          '$message ${l10n.invoiceShareError}',
        OrderDocumentActionStatus.canceled => message,
      };
    }

    if (outcome.isSuccess) {
      message = switch (outcome.printStatus) {
        InvoicePrintStatus.printed => '$message ${l10n.invoicePrintSuccess}',
        InvoicePrintStatus.failed => '$message ${l10n.invoicePrintError}',
        InvoicePrintStatus.notRequested => message,
      };
    }

    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: outcome.isSuccess
              ? null
              : SnackBarAction(
                  label: l10n.retryButton,
                  onPressed: () {
                    if (context.mounted) {
                      _checkout(context);
                    }
                  },
                ),
        ),
      );

    if (outcome.isSuccess) {
      final order = outcome.order;
      if (order != null && order.publicInvoiceUrl.trim().isNotEmpty) {
        await showPublicInvoiceDialog(context: context, order: order);
        if (!context.mounted) {
          return;
        }
      }
      onCheckoutSuccess?.call();
      // The sale is done and the cart has reset — send the cashier straight
      // back to the search field for the next customer. Fired last, after any
      // public-invoice dialog has closed, so it lands on the live route.
      viewModel.requestSearchFocus();
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

  /// The آجل sale was refused for breaching the customer's ceiling. There is no
  /// "continue anyway" here on purpose: raising the limit is an owner's decision
  /// made on the customer's record, not a cashier's at the till.
  Future<void> _showCreditLimitDialog(
    BuildContext context, {
    required SaleCheckoutCreditLimitException credit,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          icon: const Icon(Icons.account_balance_wallet_outlined),
          title: Text(l10n.creditLimitBlockedTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.creditLimitBlockedMessage),
                const SizedBox(height: 12),
                Text(
                  l10n.creditLimitBlockedOutstanding(
                    formatMoney(credit.outstanding),
                  ),
                ),
                Text(l10n.creditLimitBlockedLimit(formatMoney(credit.limit))),
                Text(
                  l10n.creditLimitBlockedAvailable(
                    formatMoney(credit.available),
                  ),
                ),
                Text(
                  l10n.creditLimitBlockedNewDebt(formatMoney(credit.newDebt)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.reviewCartButton),
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _showLossWarningDialog(
    BuildContext context, {
    required List<SaleLossLine> lossLines,
    required bool canSellAtLoss,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          icon: const Icon(Icons.warning_amber_outlined),
          title: Text(l10n.lossSaleWarningTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  canSellAtLoss
                      ? l10n.lossSaleWarningMessage
                      : l10n.lossSaleBlockedMessage,
                ),
                const SizedBox(height: 12),
                for (final line in lossLines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      l10n.lossSaleLine(
                        line.productName,
                        formatMoney(line.lossAmount),
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
                canSellAtLoss ? l10n.cancelButton : l10n.reviewCartButton,
              ),
            ),
            if (canSellAtLoss)
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
    // Nothing may redraw the sell screen while money is being taken.
    return viewModel.duringCriticalInteraction(
      () => showPosPaymentSheet(
        context: context,
        total: viewModel.total,
        enableCashPayments: viewModel.enableCashPayments,
        enableCardPayments: viewModel.enableCardPayments,
        enableTransferPayments: viewModel.enableTransferPayments,
        requireCardReceipt: viewModel.requireCardPaymentReceipt,
        trustedCardTerminalIds: viewModel.trustedCardTerminalIds,
        showPrintInvoiceToggle: viewModel.shouldShowPrintInvoiceCheckbox,
        printInvoiceAfterPayment: viewModel.printInvoiceAfterPayment,
        onPrintInvoiceChanged: viewModel.updatePrintInvoiceAfterPayment,
        showShareInvoiceToggle: viewModel.shouldShowShareInvoiceCheckbox,
        shareInvoiceAfterPayment: viewModel.shareInvoiceAfterPayment,
        onShareInvoiceChanged: viewModel.updateShareInvoiceAfterPayment,
        hasCustomer: viewModel.selectedCustomer != null,
        requireCustomerForCredit: viewModel.requireCustomerForCredit,
        proposedDueDate: viewModel.proposedCreditDueDate,
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
  });

  final PosViewModel viewModel;
  final bool isCartLocked;

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
                          onPickBatch:
                              widget.isCartLocked ||
                                  !line.variant.trackingMode.tracksLots ||
                                  _viewModel.trackedStockRepository == null
                              ? null
                              : () => _editLineBatch(context, line),
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
                  value: _selectedCustomer?.fullName ?? '',
                  placeholder: l10n.walkInCustomerLabel,
                  icon: Icons.person_pin_circle_outlined,
                  enabled: !widget.viewModel.isCheckingOut,
                  onSelect: _selectCustomer,
                  onClear: () => setState(() => _selectedCustomer = null),
                  allowClear: _selectedCustomer != null,
                  selectActionIcon: Icons.edit_outlined,
                ),
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
    required this.onCheckout,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final canSubmit = viewModel.cart.isNotEmpty && !viewModel.isCheckingOut;

    return PointyStickyActionFooter(
      padding: EdgeInsetsDirectional.fromSTEB(spacing.sm, 6, spacing.sm, 6),
      primaryActionHeight: 52,
      summary: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CartTotals(viewModel: viewModel, compact: true),
          if (viewModel.shouldShowPrintInvoiceCheckbox)
            PointyOrderToggleRow(
              label: l10n.printInvoiceAfterPaymentLabel,
              value: viewModel.printInvoiceAfterPayment,
              enabled: !viewModel.isCheckingOut,
              onChanged: viewModel.updatePrintInvoiceAfterPayment,
            ),
        ],
      ),
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

/// What the provider did about each recharge, when it was not simply "done".
///
/// The three outcomes need three different reactions and the dialog says so
/// outright, because the wrong reaction to the third one spends the shop's
/// money twice:
///
/// * refused for want of float — top up, then retry the line;
/// * refused for any other reason — the float is untouched, retry is safe;
/// * **unknown** — the request left and never answered. Do not retry. Check
///   the card with the provider; reconciliation will settle it against their
///   own purchase log.
Future<void> _showRechargeOutcomeDialog(
  BuildContext context,
  List<IntegrationChargeResult> rows,
) {
  final l10n = AppLocalizations.of(context)!;
  final colors = context.pointyColors;
  final unresolved = rows.where((row) => row.needsAttention).toList();
  final failed = rows.where((row) => row.isRefused).toList();

  return showDialog<void>(
    context: context,
    // The unknown case is not dismissable by tapping away: it is the one
    // state where doing nothing about it is a real risk.
    barrierDismissible: unresolved.isEmpty,
    builder: (dialogContext) => AlertDialog(
      icon: Icon(
        unresolved.isEmpty
            ? Icons.error_outline
            : Icons.help_outline,
        color: unresolved.isEmpty ? colors.danger : colors.warning,
      ),
      title: Text(
        unresolved.isEmpty
            ? l10n.rechargeRefusedTitle
            : l10n.rechargeUnknownTitle,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (unresolved.isNotEmpty) ...[
            Text(l10n.rechargeUnknownBody),
            const SizedBox(height: 12),
          ],
          for (final row in [...unresolved, ...failed])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${row.subscriberRef} · ${row.optionLabel}',
                    style: Theme.of(dialogContext).textTheme.titleSmall,
                  ),
                  Text(
                    integrationErrorText(row.errorCode, l10n),
                    style: Theme.of(dialogContext).textTheme.bodySmall
                        ?.copyWith(color: colors.mutedInk),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(l10n.closeButton),
        ),
      ],
    ),
  );
}
