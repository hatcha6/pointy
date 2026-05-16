import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/formatters.dart';

Future<void> showSaleOrderDetailsSheet(
  BuildContext context,
  SaleOrder order, {
  Future<bool> Function(SaleOrder order)? onReprint,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) {
      return _SaleOrderDetailsSheet(order: order, onReprint: onReprint);
    },
  );
}

class _SaleOrderDetailsSheet extends StatefulWidget {
  const _SaleOrderDetailsSheet({required this.order, this.onReprint});

  final SaleOrder order;
  final Future<bool> Function(SaleOrder order)? onReprint;

  @override
  State<_SaleOrderDetailsSheet> createState() => _SaleOrderDetailsSheetState();
}

class _SaleOrderDetailsSheetState extends State<_SaleOrderDetailsSheet> {
  bool _isReprinting = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final order = widget.order;

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
              Text(l10n.total, style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text(
                formatMoney(order.total),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          if (widget.onReprint != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _isReprinting ? null : _requestReprint,
              icon: _isReprinting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined),
              label: Text(
                _isReprinting
                    ? l10n.saleReprintInProgressButton
                    : l10n.saleReprintButton,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _requestReprint() async {
    final l10n = AppLocalizations.of(context)!;
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _isReprinting = true);
    final requested = await widget.onReprint!(widget.order);
    if (!mounted) {
      return;
    }

    setState(() => _isReprinting = false);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            requested ? l10n.saleReprintQueuedMessage : l10n.saleReprintError,
          ),
        ),
      );
  }
}
