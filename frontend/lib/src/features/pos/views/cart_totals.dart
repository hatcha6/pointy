import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/formatters.dart';
import '../view_models/pos_view_model.dart';

class CartTotals extends StatelessWidget {
  const CartTotals({super.key, required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TotalLine(label: l10n.subtotal, value: viewModel.subtotal),
          if (viewModel.discountTotal > 0)
            _TotalLine(
              label: l10n.discountTotalLabel,
              value: -viewModel.discountTotal,
            ),
          if (viewModel.appliedDiscounts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Column(
                children: [
                  for (final discount in viewModel.appliedDiscounts)
                    _DiscountLine(discount: discount),
                ],
              ),
            ),
          const Divider(height: 12),
          _TotalLine(label: l10n.total, value: viewModel.total, isStrong: true),
        ],
      ),
    );
  }
}

class _DiscountLine extends StatelessWidget {
  const _DiscountLine({required this.discount});

  final AppliedDiscountInfo discount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final label = discount.couponCode.isEmpty
        ? discount.ruleName
        : l10n.discountCouponAppliedLabel(discount.couponCode);

    return _TotalLine(label: label, value: -discount.discountAmount);
  }
}

class _TotalLine extends StatelessWidget {
  const _TotalLine({
    required this.label,
    required this.value,
    this.isStrong = false,
  });

  final String label;
  final double value;
  final bool isStrong;

  @override
  Widget build(BuildContext context) {
    final style = isStrong
        ? Theme.of(context).textTheme.titleLarge
        : Theme.of(context).textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(formatMoney(value), maxLines: 1, style: style),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
