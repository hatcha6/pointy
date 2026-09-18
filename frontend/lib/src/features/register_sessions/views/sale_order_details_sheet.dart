import 'package:flutter/material.dart';

import '../../../data/models/sale_order.dart';
import '../../../shared/components/components.dart';
import '../../../shared/order/sale_order_details_content.dart';
import '../../../shared/responsive/responsive.dart';

/// Fetches the full sale behind a row. Returns null when it cannot be loaded —
/// the sheet then falls back to the summary rather than showing nothing.
typedef SaleOrderDetailLoader = Future<SaleOrder?> Function(int orderId);

Future<void> showSaleOrderDetailsSheet(
  BuildContext context,
  SaleOrder order, {
  SaleOrderDetailLoader? loadDetail,
  Future<bool> Function(SaleOrder order)? onReprint,
  Future<bool> Function(SaleOrder order, String reason)? onVoid,
  SaleOrderReturnAction? onReturn,
}) {
  return showAdaptiveModalBottomSheet<void>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.92,
    builder: (context) {
      return _SaleOrderDetailsSheetBody(
        order: order,
        loadDetail: loadDetail,
        onReprint: onReprint,
        onVoid: onVoid,
        onReturn: onReturn,
      );
    },
  );
}

/// The row that opened this sheet is a summary: it carries a line COUNT and no
/// line items (see `OrderSessionSerializer`). Rendering it directly reported a
/// sale with no products and hid the void/return actions, which are offered
/// only when a line still has something returnable on it.
class _SaleOrderDetailsSheetBody extends StatefulWidget {
  const _SaleOrderDetailsSheetBody({
    required this.order,
    this.loadDetail,
    this.onReprint,
    this.onVoid,
    this.onReturn,
  });

  final SaleOrder order;
  final SaleOrderDetailLoader? loadDetail;
  final Future<bool> Function(SaleOrder order)? onReprint;
  final Future<bool> Function(SaleOrder order, String reason)? onVoid;
  final SaleOrderReturnAction? onReturn;

  @override
  State<_SaleOrderDetailsSheetBody> createState() =>
      _SaleOrderDetailsSheetBodyState();
}

class _SaleOrderDetailsSheetBodyState
    extends State<_SaleOrderDetailsSheetBody> {
  late SaleOrder _order = widget.order;
  late bool _isLoading = widget.loadDetail != null;

  @override
  void initState() {
    super.initState();
    final loadDetail = widget.loadDetail;
    if (loadDetail != null) {
      _load(loadDetail);
    }
  }

  Future<void> _load(SaleOrderDetailLoader loadDetail) async {
    final loaded = await loadDetail(widget.order.id);
    if (!mounted) {
      return;
    }
    setState(() {
      // A failed fetch leaves the summary on screen — less than the whole
      // document, but still the sale's number, totals and status.
      _order = loaded ?? _order;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const PointyLoadingArea();
    }
    return SaleOrderDetailsContent(
      order: _order,
      onReprint: widget.onReprint,
      onVoid: widget.onVoid,
      onReturn: widget.onReturn,
      useInvoiceLabels: false,
    );
  }
}
