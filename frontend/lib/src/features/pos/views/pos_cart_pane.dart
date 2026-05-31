import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/contact_repository.dart';
import '../../../data/repositories/sale_repository.dart';
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

class PosCartPane extends StatelessWidget {
  const PosCartPane({
    super.key,
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
                    trailing: IconButton(
                      tooltip: l10n.clearCartTooltip,
                      onPressed: viewModel.cart.isEmpty || isCartLocked
                          ? null
                          : viewModel.clearCart,
                      icon: const Icon(Icons.delete_outline),
                      color: colors.danger,
                    ),
                    child: _CartScrollContent(
                      viewModel: viewModel,
                      isCartLocked: isCartLocked,
                      onSelectCustomer: () => _selectCustomer(context),
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
      showPrintInvoiceToggle: viewModel.shouldShowPrintInvoiceCheckbox,
      printInvoiceAfterPayment: viewModel.printInvoiceAfterPayment,
      onPrintInvoiceChanged: viewModel.updatePrintInvoiceAfterPayment,
    );
  }
}

class _CartScrollContent extends StatelessWidget {
  const _CartScrollContent({
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
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return ListView(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.md,
        spacing.sm,
        spacing.md,
        spacing.md,
      ),
      children: [
        ContactSelectionTile(
          label: l10n.selectedCustomerLabel,
          value: viewModel.selectedCustomer?.fullName ?? '',
          placeholder: l10n.walkInCustomerLabel,
          icon: Icons.person_outline,
          iconSize: 20,
          iconSpacing: 8,
          enabled: !viewModel.isCheckingOut,
          onSelect: onSelectCustomer,
          onClear: () => viewModel.selectCustomer(null),
          padding: const EdgeInsetsDirectional.fromSTEB(10, 8, 6, 8),
          actionVisualDensity: VisualDensity.compact,
          selectActionIcon: Icons.edit_outlined,
        ),
        SizedBox(height: spacing.sm),
        _CouponCodeField(viewModel: viewModel),
        SizedBox(height: spacing.sm),
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
          for (var index = 0; index < viewModel.cart.length; index += 1) ...[
            if (index > 0) Divider(height: 1, color: colors.line),
            CartLineTile(
              line: viewModel.cart[index],
              onAdd: isCartLocked
                  ? null
                  : () => viewModel.addVariant(viewModel.cart[index].variant),
              onRemove: isCartLocked
                  ? null
                  : () => viewModel.decrementVariant(
                      viewModel.cart[index].variant,
                    ),
              onDelete: isCartLocked
                  ? null
                  : () =>
                        viewModel.removeVariant(viewModel.cart[index].variant),
            ),
          ],
      ],
    );
  }
}

class _CouponCodeField extends StatefulWidget {
  const _CouponCodeField({required this.viewModel});

  final PosViewModel viewModel;

  @override
  State<_CouponCodeField> createState() => _CouponCodeFieldState();
}

class _CouponCodeFieldState extends State<_CouponCodeField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.viewModel.couponCode,
  );
  final FocusNode _focusNode = FocusNode();

  @override
  void didUpdateWidget(covariant _CouponCodeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus &&
        _controller.text != widget.viewModel.couponCode) {
      _controller.text = widget.viewModel.couponCode;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final viewModel = widget.viewModel;
    final hasCoupon = _controller.text.trim().isNotEmpty;
    final hasInvalidCoupon = viewModel.unappliedCouponCodes.isNotEmpty;

    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      enabled: !viewModel.isCheckingOut,
      textCapitalization: TextCapitalization.characters,
      decoration: InputDecoration(
        labelText: l10n.discountCouponCodeLabel,
        hintText: l10n.discountCouponCodeHint,
        isDense: true,
        prefixIcon: const Icon(Icons.confirmation_number_outlined),
        suffixIcon: viewModel.isLoadingDiscountPreview
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                tooltip: hasCoupon
                    ? l10n.clearCouponCodeTooltip
                    : l10n.refreshDiscountPreviewTooltip,
                onPressed: viewModel.isCheckingOut
                    ? null
                    : () {
                        if (hasCoupon) {
                          _controller.clear();
                          viewModel.updateCouponCode('');
                        } else {
                          viewModel.refreshDiscountPreview();
                        }
                      },
                icon: Icon(hasCoupon ? Icons.close : Icons.sync),
              ),
        errorText: hasInvalidCoupon
            ? l10n.discountCouponUnavailable(
                viewModel.unappliedCouponCodes.join('، '),
              )
            : viewModel.hasDiscountPreviewError
            ? l10n.discountPreviewUnavailable
            : null,
      ),
      onChanged: viewModel.updateCouponCode,
      onSubmitted: (_) => viewModel.refreshDiscountPreview(),
    );
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
    final canSubmit = viewModel.cart.isNotEmpty && !viewModel.isCheckingOut;

    return PointyStickyActionFooter(
      summary: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CartTotals(viewModel: viewModel),
          if (viewModel.shouldShowPrintInvoiceCheckbox)
            CheckboxListTile(
              value: viewModel.printInvoiceAfterPayment,
              onChanged: viewModel.isCheckingOut
                  ? null
                  : (value) => viewModel.updatePrintInvoiceAfterPayment(
                      value ?? false,
                    ),
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                l10n.printInvoiceAfterPaymentLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
