import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../view_models/pos_view_model.dart';
import 'invoice_discount_sheet.dart';

class CartTotals extends StatelessWidget {
  const CartTotals({super.key, required this.viewModel, this.compact = false});

  final PosViewModel viewModel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final appliedDiscounts = viewModel.appliedDiscounts;
    // What the cashier's own discount actually took off, which is not always
    // what they typed: a cart that shrank after the fact can only carry what it
    // is worth, and the panel must state the discount the sale is getting.
    final invoiceDiscount = viewModel.appliedExtraDiscountAmount;
    // The rules' share, so the deductions listed below add up to the total. The
    // aggregate line is the fallback for a backend that does not itemise; the
    // manual discount is never folded into it, because it has its own line.
    final ruleDiscount = viewModel.discountTotal - invoiceDiscount;
    // Shown whenever the shop allows a till discount at all — including while
    // a checkout is in flight, where only the PRESS is withdrawn. Dropping the
    // whole row on checkout moved every figure under it at the exact moment
    // the cashier is reading the total back to the customer.
    final showsInvoiceDiscountRow = viewModel.canDiscountInvoice;
    final canEditInvoiceDiscount =
        !viewModel.isCheckingOut && viewModel.cart.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(top: compact ? 0 : 8),
      child: PointyTotalsPanel(
        compact: compact,
        lines: [
          PointyTotalLine(
            label: l10n.subtotal,
            value: formatMoney(viewModel.subtotal),
          ),
          // Show the itemized discount breakdown when it is available;
          // otherwise fall back to a single aggregate line. Never both — a
          // lone discount used to render twice (rule line + aggregate line).
          if (appliedDiscounts.isNotEmpty)
            for (final discount in appliedDiscounts)
              _discountLine(l10n, discount)
          else if (ruleDiscount > 0)
            PointyTotalLine(
              label: l10n.discountTotalLabel,
              value: formatMoney(-ruleDiscount),
              isMuted: true,
            ),
          // The cashier's own discount, on its own line and always reachable
          // while the shop allows one — a row that only appeared once a
          // discount existed would leave nothing to press to create the first
          // one. Tapping it IS the editor.
          if (showsInvoiceDiscountRow)
            PointyTotalLine(
              label: invoiceDiscount > 0
                  ? l10n.invoiceDiscountLabel
                  : l10n.invoiceDiscountAddAction,
              value: invoiceDiscount > 0 ? formatMoney(-invoiceDiscount) : '',
              isMuted: true,
              actionIcon: Icons.discount_outlined,
              onTap: canEditInvoiceDiscount
                  ? () => _editInvoiceDiscount(context)
                  : null,
            )
          else if (invoiceDiscount > 0)
            PointyTotalLine(
              label: l10n.invoiceDiscountLabel,
              value: formatMoney(-invoiceDiscount),
              isMuted: true,
            ),
          PointyTotalLine(
            label: l10n.total,
            value: formatMoney(viewModel.total),
            isStrong: true,
          ),
        ],
      ),
    );
  }

  Future<void> _editInvoiceDiscount(BuildContext context) async {
    final amount = await showInvoiceDiscountSheet(
      context,
      // The typed figure, not the applied one: reopening the editor should show
      // the cashier what they last asked for, so an amount the cart could not
      // carry can be corrected rather than silently re-entered.
      currentAmount: viewModel.extraDiscountAmount,
      // What the sale can still carry, from the last preview — the subtotal
      // less whatever the shop's rules already took off. Falls back to the
      // subtotal only when no preview has answered yet, which is the same
      // number on a cart no rule has touched.
      roomOnTheSale: viewModel.maxExtraDiscountAmount > 0
          ? viewModel.maxExtraDiscountAmount
          : viewModel.subtotal,
      limit: viewModel.invoiceDiscountLimit,
    );
    if (amount == null) {
      return;
    }
    viewModel.updateExtraDiscountAmount(amount);
  }

  PointyTotalLine _discountLine(
    AppLocalizations l10n,
    AppliedDiscountInfo discount,
  ) {
    final label = discount.couponCode.isEmpty
        ? discount.ruleName
        : l10n.discountCouponAppliedLabel(discount.couponCode);

    return PointyTotalLine(
      label: label,
      value: formatMoney(-discount.discountAmount),
      isMuted: true,
    );
  }
}
