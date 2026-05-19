import 'package:flutter/material.dart';

import 'formatters.dart';

class OrderTotals extends StatelessWidget {
  const OrderTotals({
    super.key,
    required this.subtotalLabel,
    required this.totalLabel,
    required this.subtotal,
    required this.total,
  });

  final String subtotalLabel;
  final String totalLabel;
  final double subtotal;
  final double total;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TotalRow(label: subtotalLabel, value: subtotal),
        const Divider(),
        TotalRow(label: totalLabel, value: total, isStrong: true),
      ],
    );
  }
}

class TotalRow extends StatelessWidget {
  const TotalRow({
    super.key,
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
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: style),
          const Spacer(),
          Text(formatMoney(value), style: style),
        ],
      ),
    );
  }
}
