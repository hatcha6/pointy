import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/formatters.dart';
import '../view_models/pos_view_model.dart';
import 'cart_line_tile.dart';
import 'cart_totals.dart';

class PosCartPane extends StatelessWidget {
  const PosCartPane({super.key, required this.viewModel});

  final PosViewModel viewModel;

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
                IconButton(
                  tooltip: l10n.clearCartTooltip,
                  onPressed: viewModel.cart.isEmpty || viewModel.isCheckingOut
                      ? null
                      : viewModel.clearCart,
                  icon: const Icon(Icons.delete_outline),
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
                        return CartLineTile(
                          line: line,
                          onAdd: viewModel.isCheckingOut
                              ? null
                              : () => viewModel.addProduct(line.product),
                          onRemove: viewModel.isCheckingOut
                              ? null
                              : () => viewModel.decrementProduct(line.product),
                        );
                      },
                    ),
            ),
            CartTotals(viewModel: viewModel),
            const SizedBox(height: 12),
            FilledButton.icon(
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
          ],
        ),
      ),
    );
  }

  Future<void> _checkout(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await viewModel.checkoutCurrentSale();

    if (!context.mounted) {
      return;
    }

    final receiptNumber = outcome.order?.receiptNumber;
    final message = outcome.isSuccess
        ? receiptNumber == null || receiptNumber.isEmpty
              ? l10n.saleCheckoutSuccess
              : l10n.saleCheckoutSuccessWithReceipt(receiptNumber)
        : l10n.saleCheckoutError;

    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
