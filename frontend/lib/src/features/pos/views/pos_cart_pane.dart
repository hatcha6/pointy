import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
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
import '../view_models/pos_view_model.dart';
import 'cart_line_tile.dart';
import 'cart_totals.dart';
import 'payment/payment.dart';
import 'pos_sale_session_strip.dart';

class PosCartPane extends StatelessWidget {
  const PosCartPane({
    super.key,
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
    this.onCheckoutSuccess,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;
  final VoidCallback? onCheckoutSuccess;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return CheckoutCapabilityBuilder(
      capabilities: capabilities,
      builder: (context, canCheckout) {
        final isCartLocked = viewModel.isCheckingOut || !canCheckout;
        final spacing = AdaptiveSpacing.of(context);
        final colors = context.pointyColors;

        return ColoredBox(
          color: colors.page,
          child: Padding(
            padding: spacing.compactPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: PointyOrderPanel(
                    title: l10n.currentSaleTitle,
                    trailing: _PosCartHeaderActions(
                      viewModel: viewModel,
                      isCartLocked: isCartLocked,
                      onSelectCustomer: () => _selectCustomer(context),
                      onEditCoupon: () => _showCouponDialog(context),
                    ),
                    child: _CartScrollContent(
                      viewModel: viewModel,
                      isCartLocked: isCartLocked,
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
      final shouldContinue = await _showStockWarningDialog(
        context,
        shortages: shortages,
        canOversell: viewModel.allowOverselling,
      );
      if (shouldContinue != true) {
        return;
      }
      if (!context.mounted) {
        return;
      }
    }

    await viewModel.refreshDiscountPreview();
    if (!context.mounted) {
      return;
    }
    if (viewModel.hasDiscountPreviewError) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(l10n.discountPreviewUnavailable)),
        );
      return;
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
      ..showSnackBar(SnackBar(content: Text(message)));

    if (outcome.isSuccess) {
      onCheckoutSuccess?.call();
    }
  }

  Future<void> _selectCustomer(BuildContext context) async {
    final customer = await showCustomerPickerSheet(
      context: context,
      repository: contactRepository,
    );
    if (customer != null) {
      viewModel.selectCustomer(customer);
    }
  }

  Future<void> _showCouponDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) => _CouponCodeDialog(viewModel: viewModel),
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
                        shortage.requested,
                        shortage.available,
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
    return showPosPaymentSheet(
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
    );
  }
}

class _CartScrollContent extends StatelessWidget {
  const _CartScrollContent({
    required this.viewModel,
    required this.isCartLocked,
  });

  final PosViewModel viewModel;
  final bool isCartLocked;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final visibleLines = viewModel.cart.reversed.toList(growable: false);

    return ListView(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.md,
        spacing.sm,
        spacing.md,
        spacing.md,
      ),
      children: [
        Divider(height: 1, color: colors.line),
        if (viewModel.cart.isEmpty)
          SizedBox(
            height: 220,
            child: PointyEmptyState(
              icon: Icons.shopping_cart_outlined,
              title: l10n.emptyCart,
            ),
          )
        else
          for (var index = 0; index < visibleLines.length; index += 1) ...[
            if (index > 0) Divider(height: 1, color: colors.line),
            CartLineTile(
              line: visibleLines[index],
              onAdd: isCartLocked
                  ? null
                  : () => viewModel.addVariant(
                      visibleLines[index].variant,
                      source: 'cart_quantity_button',
                    ),
              onRemove: isCartLocked
                  ? null
                  : () => viewModel.decrementVariant(
                      visibleLines[index].variant,
                      source: 'cart_quantity_button',
                    ),
              onDelete: isCartLocked
                  ? null
                  : () => viewModel.removeVariant(
                      visibleLines[index].variant,
                      source: 'cart_delete_button',
                    ),
            ),
          ],
      ],
    );
  }
}

enum _CustomerHeaderMenuAction { change, clear }

class _PosCartHeaderActions extends StatelessWidget {
  const _PosCartHeaderActions({
    required this.viewModel,
    required this.isCartLocked,
    required this.onSelectCustomer,
    required this.onEditCoupon,
  });

  final PosViewModel viewModel;
  final bool isCartLocked;
  final VoidCallback onSelectCustomer;
  final VoidCallback onEditCoupon;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;

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
        _CustomerHeaderAction(
          viewModel: viewModel,
          isCartLocked: isCartLocked,
          onSelectCustomer: onSelectCustomer,
        ),
        _CouponHeaderAction(
          viewModel: viewModel,
          isCartLocked: isCartLocked,
          onEditCoupon: onEditCoupon,
        ),
        IconButton(
          tooltip: l10n.clearCartTooltip,
          onPressed: viewModel.cart.isEmpty || isCartLocked
              ? null
              : viewModel.clearCart,
          icon: const Icon(Icons.delete_outline),
          color: colors.danger,
        ),
      ],
    );
  }
}

class _CustomerHeaderAction extends StatelessWidget {
  const _CustomerHeaderAction({
    required this.viewModel,
    required this.isCartLocked,
    required this.onSelectCustomer,
  });

  final PosViewModel viewModel;
  final bool isCartLocked;
  final VoidCallback onSelectCustomer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final customer = viewModel.selectedCustomer;
    final hasCustomer = customer != null;
    final pill = _CustomerHeaderPill(
      label: hasCustomer ? customer.fullName : l10n.walkInCustomerLabel,
      icon: hasCustomer
          ? Icons.person_pin_circle_outlined
          : Icons.person_add_alt_1_outlined,
      foreground: hasCustomer ? colors.primaryStrong : colors.ink,
      background: hasCustomer
          ? PointyColors.primaryContainer
          : colors.subtleFill,
    );

    if (!hasCustomer) {
      return Tooltip(
        message: l10n.selectedCustomerLabel,
        child: InkWell(
          onTap: isCartLocked ? null : onSelectCustomer,
          borderRadius: BorderRadius.circular(PointyRadii.card),
          child: pill,
        ),
      );
    }

    return PopupMenuButton<_CustomerHeaderMenuAction>(
      tooltip: customer.fullName,
      enabled: !isCartLocked,
      onSelected: (action) {
        switch (action) {
          case _CustomerHeaderMenuAction.change:
            onSelectCustomer();
          case _CustomerHeaderMenuAction.clear:
            viewModel.selectCustomer(null);
        }
      },
      itemBuilder: (context) {
        return [
          PopupMenuItem(
            value: _CustomerHeaderMenuAction.change,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.edit_outlined),
              title: Text(l10n.changeContactAction),
            ),
          ),
          PopupMenuItem(
            value: _CustomerHeaderMenuAction.clear,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.close),
              title: Text(l10n.clearContactTooltip),
            ),
          ),
        ];
      },
      child: pill,
    );
  }
}

class _CustomerHeaderPill extends StatelessWidget {
  const _CustomerHeaderPill({
    required this.label,
    required this.icon,
    required this.foreground,
    required this.background,
  });

  final String label;
  final IconData icon;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 128, minHeight: 40),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(PointyRadii.card),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CouponHeaderAction extends StatelessWidget {
  const _CouponHeaderAction({
    required this.viewModel,
    required this.isCartLocked,
    required this.onEditCoupon,
  });

  final PosViewModel viewModel;
  final bool isCartLocked;
  final VoidCallback onEditCoupon;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final couponCode = viewModel.couponCode.trim();
    final hasCoupon = couponCode.isNotEmpty;
    final hasIssue =
        viewModel.hasDiscountPreviewError ||
        viewModel.unappliedCouponCodes.isNotEmpty;
    final hasAppliedDiscount = viewModel.appliedDiscounts.isNotEmpty;
    final iconColor = hasIssue
        ? colors.danger
        : hasCoupon || hasAppliedDiscount
        ? colors.primaryStrong
        : null;

    return IconButton(
      tooltip: hasCoupon
          ? '${l10n.discountCouponCodeLabel}: $couponCode'
          : l10n.discountCouponCodeLabel,
      onPressed: isCartLocked ? null : onEditCoupon,
      icon: viewModel.isLoadingDiscountPreview
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.confirmation_number_outlined),
      color: iconColor,
    );
  }
}

class _CouponCodeDialog extends StatefulWidget {
  const _CouponCodeDialog({required this.viewModel});

  final PosViewModel viewModel;

  @override
  State<_CouponCodeDialog> createState() => _CouponCodeDialogState();
}

class _CouponCodeDialogState extends State<_CouponCodeDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.viewModel.couponCode,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasCoupon = _controller.text.trim().isNotEmpty;
    final hasInvalidCoupon = widget.viewModel.unappliedCouponCodes.isNotEmpty;

    return AlertDialog(
      icon: const Icon(Icons.confirmation_number_outlined),
      title: Text(l10n.discountCouponCodeLabel),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _controller,
          enabled: !widget.viewModel.isCheckingOut,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            hintText: l10n.discountCouponCodeHint,
            isDense: true,
            errorText: hasInvalidCoupon
                ? l10n.discountCouponUnavailable(
                    widget.viewModel.unappliedCouponCodes.join('، '),
                  )
                : widget.viewModel.hasDiscountPreviewError
                ? l10n.discountPreviewUnavailable
                : null,
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _apply(),
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
        FilledButton(
          onPressed: _apply,
          child: Text(l10n.applyDiscountCodeButton),
        ),
      ],
    );
  }

  void _apply() {
    final value = _controller.text.trim();
    if (value == widget.viewModel.couponCode.trim()) {
      unawaited(widget.viewModel.refreshDiscountPreview());
    } else {
      widget.viewModel.updateCouponCode(value);
    }
    Navigator.of(context).pop();
  }

  void _clear() {
    widget.viewModel.updateCouponCode('');
    Navigator.of(context).pop();
  }

  void _refresh() {
    final value = _controller.text.trim();
    if (value != widget.viewModel.couponCode.trim()) {
      widget.viewModel.updateCouponCode(value);
    }
    unawaited(widget.viewModel.refreshDiscountPreview());
    Navigator.of(context).pop();
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
        children: [
          CartTotals(viewModel: viewModel, compact: true),
          if (viewModel.shouldShowPrintInvoiceCheckbox)
            InkWell(
              onTap: viewModel.isCheckingOut
                  ? null
                  : () => viewModel.updatePrintInvoiceAfterPayment(
                      !viewModel.printInvoiceAfterPayment,
                    ),
              child: Padding(
                padding: const EdgeInsetsDirectional.only(top: 2),
                child: Row(
                  children: [
                    Checkbox(
                      value: viewModel.printInvoiceAfterPayment,
                      onChanged: viewModel.isCheckingOut
                          ? null
                          : (value) => viewModel.updatePrintInvoiceAfterPayment(
                              value ?? false,
                            ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        l10n.printInvoiceAfterPaymentLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      primaryAction: CheckoutGuard(
        capabilities: capabilities,
        child: FilledButton.icon(
          onPressed: canSubmit ? onCheckout : null,
          icon: viewModel.isCheckingOut
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
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
    );
  }
}
