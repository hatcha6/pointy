import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../shared/authorization_guards.dart';
import '../../../shared/decimal_text_input_formatter.dart';
import '../../../shared/formatters.dart';
import '../view_models/pos_view_model.dart';
import 'cart_line_tile.dart';
import 'cart_totals.dart';

class PosCartPane extends StatelessWidget {
  const PosCartPane({
    super.key,
    required this.viewModel,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return ColoredBox(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  l10n.currentSaleTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const Spacer(),
                CheckoutCapabilityBuilder(
                  capabilities: capabilities,
                  builder: (context, canCheckout) {
                    return IconButton(
                      tooltip: l10n.clearCartTooltip,
                      onPressed:
                          viewModel.cart.isEmpty ||
                              viewModel.isCheckingOut ||
                              !canCheckout
                          ? null
                          : viewModel.clearCart,
                      icon: const Icon(Icons.delete_outline),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: viewModel.cart.isEmpty
                  ? Center(child: Text(l10n.emptyCart))
                  : ListView.separated(
                      itemCount: viewModel.cart.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final line = viewModel.cart[index];
                        return CheckoutCapabilityBuilder(
                          capabilities: capabilities,
                          builder: (context, canCheckout) {
                            return CartLineTile(
                              line: line,
                              onAdd: viewModel.isCheckingOut || !canCheckout
                                  ? null
                                  : () => viewModel.addProduct(line.product),
                              onRemove: viewModel.isCheckingOut || !canCheckout
                                  ? null
                                  : () => viewModel.decrementProduct(
                                      line.product,
                                    ),
                            );
                          },
                        );
                      },
                    ),
            ),
            CartTotals(viewModel: viewModel),
            if (viewModel.shouldShowPrintInvoiceCheckbox) ...[
              const SizedBox(height: 8),
              CheckboxListTile(
                value: viewModel.printInvoiceAfterPayment,
                onChanged: viewModel.isCheckingOut
                    ? null
                    : (value) => viewModel.updatePrintInvoiceAfterPayment(
                        value ?? false,
                      ),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(l10n.printInvoiceAfterPaymentLabel),
              ),
            ],
            const SizedBox(height: 12),
            CheckoutGuard(
              capabilities: capabilities,
              child: FilledButton.icon(
                onPressed: viewModel.cart.isEmpty || viewModel.isCheckingOut
                    ? null
                    : () => _checkout(context),
                icon: viewModel.isCheckingOut
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.payments_outlined),
                label: Text(
                  viewModel.isCheckingOut
                      ? l10n.checkoutInProgressButton
                      : l10n.payAmount(formatMoney(viewModel.total)),
                ),
              ),
            ),
          ],
        ),
      ),
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

    final payment = await _showPaymentDialog(context);
    if (payment == null) {
      return;
    }

    final outcome = await viewModel.checkoutCurrentSale(
      paymentMethod: payment.method,
      amountReceived: payment.amountReceived,
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

  Future<_PaymentInput?> _showPaymentDialog(BuildContext context) {
    return showDialog<_PaymentInput>(
      context: context,
      builder: (context) => _PaymentDialog(viewModel: viewModel),
    );
  }
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.viewModel});

  final PosViewModel viewModel;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  late PaymentMethod _method = _initialMethod;
  late final TextEditingController _cashAmountController =
      TextEditingController(text: widget.viewModel.total.toStringAsFixed(2));
  bool _showCashError = false;

  @override
  void dispose() {
    _cashAmountController.dispose();
    super.dispose();
  }

  PaymentMethod get _initialMethod {
    if (widget.viewModel.enableCashPayments) {
      return PaymentMethod.cash;
    }
    if (widget.viewModel.enableCardPayments) {
      return PaymentMethod.card;
    }
    return PaymentMethod.transfer;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final total = widget.viewModel.total;
    final amountReceived = _method == PaymentMethod.cash
        ? _parseMoney(_cashAmountController.text)
        : total;
    final change = (amountReceived - total).clamp(0, double.infinity);

    return AlertDialog(
      icon: const Icon(Icons.payments_outlined),
      title: Text(l10n.paymentDialogTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_hasAnyPaymentMethod)
              Text(l10n.noEnabledPaymentMethods)
            else
              SegmentedButton<PaymentMethod>(
                segments: _paymentSegments(l10n),
                selected: {_method},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  setState(() {
                    _method = selection.first;
                    _showCashError = false;
                  });
                },
              ),
            const SizedBox(height: 16),
            TotalRow(label: l10n.total, value: total, isStrong: true),
            if (_method == PaymentMethod.cash) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _cashAmountController,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [DecimalTextInputFormatter()],
                onChanged: (_) => setState(() => _showCashError = false),
                decoration: InputDecoration(
                  labelText: l10n.cashReceivedLabel,
                  errorText: _showCashError
                      ? l10n.cashReceivedTooLowError
                      : null,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.payments_outlined),
                ),
              ),
              const SizedBox(height: 8),
              TotalRow(label: l10n.changeDueLabel, value: change.toDouble()),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancelButton),
        ),
        FilledButton.icon(
          onPressed: _hasAnyPaymentMethod ? () => _submit(total) : null,
          icon: const Icon(Icons.check),
          label: Text(l10n.confirmPaymentButton),
        ),
      ],
    );
  }

  void _submit(double total) {
    final amountReceived = _method == PaymentMethod.cash
        ? _parseMoney(_cashAmountController.text)
        : total;
    if (amountReceived < total) {
      setState(() => _showCashError = true);
      return;
    }
    Navigator.of(
      context,
    ).pop(_PaymentInput(method: _method, amountReceived: amountReceived));
  }

  double _parseMoney(String value) {
    return double.tryParse(value.replaceAll(',', '.')) ?? 0;
  }

  bool get _hasAnyPaymentMethod {
    return widget.viewModel.enableCashPayments ||
        widget.viewModel.enableCardPayments ||
        widget.viewModel.enableTransferPayments;
  }

  List<ButtonSegment<PaymentMethod>> _paymentSegments(AppLocalizations l10n) {
    return [
      if (widget.viewModel.enableCashPayments)
        ButtonSegment(
          value: PaymentMethod.cash,
          icon: const Icon(Icons.payments_outlined),
          label: Text(l10n.paymentMethodCash),
        ),
      if (widget.viewModel.enableCardPayments)
        ButtonSegment(
          value: PaymentMethod.card,
          icon: const Icon(Icons.credit_card_outlined),
          label: Text(l10n.paymentMethodCard),
        ),
      if (widget.viewModel.enableTransferPayments)
        ButtonSegment(
          value: PaymentMethod.transfer,
          icon: const Icon(Icons.account_balance_outlined),
          label: Text(l10n.paymentMethodTransfer),
        ),
    ];
  }
}

class _PaymentInput {
  const _PaymentInput({required this.method, required this.amountReceived});

  final PaymentMethod method;
  final double amountReceived;
}
