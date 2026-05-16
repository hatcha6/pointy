import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/formatters.dart';

Future<void> showSaleOrderDetailsSheet(BuildContext context, SaleOrder order) {
  final l10n = AppLocalizations.of(context)!;

  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.saleReceiptTitle(
                order.receiptNumber ?? l10n.saleReceiptFallback,
              ),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: order.lines.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final line = order.lines[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      line.productName ??
                          l10n.saleProductFallback(line.productId),
                    ),
                    subtitle: Text(
                      l10n.saleLineQuantityAndPrice(
                        line.quantity,
                        formatMoney(line.unitPrice),
                      ),
                    ),
                    trailing: Text(formatMoney(line.total)),
                  );
                },
              ),
            ),
            const Divider(),
            Row(
              children: [
                Text(
                  l10n.total,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  formatMoney(order.total),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
