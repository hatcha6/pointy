import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/order_totals.dart';
import '../view_models/pos_view_model.dart';

class CartTotals extends StatelessWidget {
  const CartTotals({super.key, required this.viewModel});

  final PosViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return OrderTotals(
      subtotalLabel: l10n.subtotal,
      totalLabel: l10n.total,
      subtotal: viewModel.subtotal,
      total: viewModel.total,
    );
  }
}
