import 'package:flutter/material.dart';

import '../data/models/product.dart';
import 'formatters.dart';

class OrderLineTile extends StatelessWidget {
  const OrderLineTile({
    super.key,
    required this.product,
    required this.quantity,
    required this.totalAmount,
    required this.unitLabel,
    required this.addTooltip,
    required this.removeTooltip,
    required this.onAdd,
    required this.onRemove,
  });

  final Product product;
  final int quantity;
  final double totalAmount;
  final String unitLabel;
  final String addTooltip;
  final String removeTooltip;
  final VoidCallback? onAdd;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(unitLabel, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton.filledTonal(
            tooltip: removeTooltip,
            onPressed: onRemove,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(width: 36, child: Center(child: Text('$quantity'))),
          IconButton.filledTonal(
            tooltip: addTooltip,
            onPressed: onAdd,
            icon: const Icon(Icons.add),
          ),
          SizedBox(
            width: 72,
            child: Text(formatMoney(totalAmount), textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}
