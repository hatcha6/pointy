import 'package:flutter/material.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/order/sale_order_details_content.dart';
import '../../../shared/responsive/responsive.dart';

Future<void> showSaleOrderDetailsSheet(
  BuildContext context,
  SaleOrder order, {
  Future<bool> Function(SaleOrder order)? onReprint,
  Future<bool> Function(SaleOrder order, String reason)? onVoid,
  Future<bool> Function(
    SaleOrder order,
    List<SaleReturnLineDraft> lines,
    String reason,
  )?
  onReturn,
}) {
  return showAdaptiveModalBottomSheet<void>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.92,
    builder: (context) {
      return SaleOrderDetailsContent(
        order: order,
        onReprint: onReprint,
        onVoid: onVoid,
        onReturn: onReturn,
        useInvoiceLabels: false,
      );
    },
  );
}
