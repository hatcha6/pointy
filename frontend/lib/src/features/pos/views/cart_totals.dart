import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../view_models/pos_view_model.dart';

class CartTotals extends StatelessWidget {
  const CartTotals({super.key, required this.viewModel, this.compact = false});

  final PosViewModel viewModel;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final appliedDiscounts = viewModel.appliedDiscounts;

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
          else if (viewModel.discountTotal > 0)
            PointyTotalLine(
              label: l10n.discountTotalLabel,
              value: formatMoney(-viewModel.discountTotal),
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
