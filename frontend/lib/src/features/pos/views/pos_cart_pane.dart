import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/authorization.dart';
import '../../../data/repositories/sale_repository.dart';
import '../../../shared/authorization_guards.dart';
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
    }

    final outcome = await viewModel.checkoutCurrentSale();

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
}
