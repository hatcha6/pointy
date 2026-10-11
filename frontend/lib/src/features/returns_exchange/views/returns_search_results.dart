import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/return_search.dart';
import '../../../data/models/sale_order.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/pointy_quantity_stepper.dart'
    show formatSaleQuantity;
import '../../../shared/order/sale_order_details_content.dart'
    show saleOrderStatusLabel;
import '../../../shared/return_window_label.dart';

/// What a returns-desk search can mean, to pick from: invoices (a receipt
/// number's tail, a customer's phone) and sold lines (the goods, inside the
/// shop's return window). Tapping one opens its invoice.
class ReturnsSearchResults extends StatelessWidget {
  const ReturnsSearchResults({
    super.key,
    required this.result,
    required this.onOpenInvoice,
    this.openingOrderId,
  });

  final ReturnSearchResult result;

  /// Opens an invoice; [lineId] is the sold line the cashier picked, if any.
  final void Function(int orderId, {int? lineId}) onOpenInvoice;

  /// The invoice being fetched, which shows a spinner instead of a chevron.
  final int? openingOrderId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final window = formatReturnWindow(l10n, result.windowHours);
    final busy = openingOrderId != null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: [
        if (result.invoices.isNotEmpty) ...[
          PointySectionHeader(title: l10n.returnsSearchInvoicesSection),
          for (final invoice in result.invoices)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _InvoiceRow(
                invoice: invoice,
                opening: openingOrderId == invoice.id,
                onTap: busy ? null : () => onOpenInvoice(invoice.id),
              ),
            ),
        ],
        if (result.lines.isNotEmpty) ...[
          PointySectionHeader(
            title: l10n.returnsSearchLinesSection,
            subtitle: l10n.returnsSearchWindowNote(window),
          ),
          for (final line in result.lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SoldLineRow(
                line: line,
                opening: openingOrderId == line.orderId,
                onTap: busy
                    ? null
                    : () => onOpenInvoice(line.orderId, lineId: line.id),
              ),
            ),
          if (result.linesTruncated)
            PointyInlineMessage(
              message: l10n.returnsSearchTruncated(result.lines.length),
              compact: true,
            ),
        ],
        if (result.lines.isEmpty && result.windowHours == 0)
          PointyInlineMessage(
            message: l10n.returnsSearchWindowClosedHint,
            compact: true,
          ),
      ],
    );
  }
}

class _InvoiceRow extends StatelessWidget {
  const _InvoiceRow({
    required this.invoice,
    required this.opening,
    required this.onTap,
  });

  final SaleOrder invoice;
  final bool opening;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final cashier = invoice.cashierName ?? '';
    final customer = invoice.customerName ?? '';
    final createdAt = invoice.createdAt;

    return PointyDataRow(
      title: invoice.receiptNumber ?? '#${invoice.id}',
      subtitle: [
        if (createdAt != null) formatDateTime(createdAt),
        if (customer.isNotEmpty) customer,
        if (cashier.isNotEmpty) l10n.invoiceCashierValue(cashier),
      ].join(' • '),
      leading: const Icon(Icons.receipt_long_outlined),
      badges: [
        if (invoice.status != 'paid')
          PointyStatusPill(
            label: saleOrderStatusLabel(l10n, invoice.status),
            color: colors.danger,
          )
        else if (!invoice.hasReturnableItems)
          PointyStatusPill(
            label: l10n.returnsSearchNothingLeft,
            color: colors.mutedInk,
          ),
      ],
      trailing: _RowTrailing(amount: invoice.total, opening: opening),
      onTap: onTap,
    );
  }
}

class _SoldLineRow extends StatelessWidget {
  const _SoldLineRow({
    required this.line,
    required this.opening,
    required this.onTap,
  });

  final ReturnSearchLine line;
  final bool opening;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final soldAt = line.soldAt;
    final unit = line.unitLabel.isEmpty ? '' : ' ${line.unitLabel}';

    return PointyDataRow(
      title: line.displayName,
      subtitle: [
        line.receiptNumber,
        if (soldAt != null) formatDateTime(soldAt),
        if (line.customerName.isNotEmpty) line.customerName,
        if (line.cashierName.isNotEmpty)
          l10n.invoiceCashierValue(line.cashierName),
      ].join(' • '),
      leading: const Icon(Icons.inventory_2_outlined),
      badges: [
        // A pill rather than a subtitle line: what is left to return is
        // the figure the cashier decides on, and a phone row would clip it.
        PointyStatusPill(
          label: l10n.returnsSearchLineQuantities(
            '${formatSaleQuantity(line.quantity)}$unit',
            '${formatSaleQuantity(line.returnableQuantity)}$unit',
          ),
          color: context.pointyColors.mutedInk,
        ),
        if (line.matchedBy == ReturnSearchMatch.serial &&
            line.matchedCode.isNotEmpty)
          PointyStatusPill(
            label: l10n.returnsSearchSerialMatch(line.matchedCode),
            icon: Icons.qr_code_2_outlined,
          ),
      ],
      trailing: _RowTrailing(amount: line.unitPrice, opening: opening),
      onTap: onTap,
    );
  }
}

class _RowTrailing extends StatelessWidget {
  const _RowTrailing({required this.amount, required this.opening});

  final double amount;
  final bool opening;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          formatMoney(amount),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(width: 8),
        if (opening)
          const SizedBox.square(
            dimension: 18,
            child: PointySpinner(strokeWidth: 2),
          )
        else
          const PointyDisclosureChevron(),
      ],
    );
  }
}
