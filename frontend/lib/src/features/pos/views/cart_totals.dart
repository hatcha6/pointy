import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/formatters.dart';
import '../../../shared/order/order.dart';
import '../view_models/pos_view_model.dart';

class CartTotals extends StatelessWidget {
  const CartTotals({super.key, required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: PointyTotalsPanel(
        lines: [
          PointyTotalLine(
            label: l10n.subtotal,
            value: formatMoney(viewModel.subtotal),
          ),
          if (viewModel.discountTotal > 0)
            PointyTotalLine(
              label: l10n.discountTotalLabel,
              value: formatMoney(-viewModel.discountTotal),
            ),
          if (viewModel.appliedDiscounts.isNotEmpty)
            for (final discount in viewModel.appliedDiscounts)
              _discountLine(l10n, discount),
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
    );
  }
}
