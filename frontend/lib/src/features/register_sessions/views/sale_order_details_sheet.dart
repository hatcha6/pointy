import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

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
        orderId: order.id,
        summary: order,
        loadDetail: loadDetail,
        onReprint: onReprint,
        onVoid: onVoid,
        onReturn: onReturn,
      );
    },
  );
}

/// Opens the sale behind [orderId] when only its id is at hand — a row that
/// is not itself an order, such as a provider top-up on the shift summary.
///
/// There is no summary to fall back on here, so a failed fetch says so and
/// offers a retry instead of drawing an empty invoice with a zero total.
Future<void> showSaleOrderDetailsSheetForId(
  BuildContext context,
  int orderId, {
  required SaleOrderDetailLoader loadDetail,
  Future<bool> Function(SaleOrder order)? onReprint,
}) {
  return showAdaptiveModalBottomSheet<void>(
    context: context,
    size: AdaptiveModalSize.standard,
    maxHeightFactor: 0.92,
    builder: (context) {
      return _SaleOrderDetailsSheetBody(
        orderId: orderId,
        loadDetail: loadDetail,
        onReprint: onReprint,
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
    required this.orderId,
    this.summary,
    this.loadDetail,
    this.onReprint,
    this.onVoid,
    this.onReturn,
  });

  final int orderId;

  /// What the opening row already knew, shown if the full sale cannot be
  /// fetched. Null when the row was not an order at all.
  final SaleOrder? summary;
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
  late SaleOrder? _order = widget.summary;
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
    final loaded = await loadDetail(widget.orderId);
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

  void _retry() {
    final loadDetail = widget.loadDetail;
    if (loadDetail == null) {
      return;
    }
    setState(() => _isLoading = true);
    _load(loadDetail);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const PointyLoadingArea();
    }
    final order = _order;
    if (order == null) {
      final l10n = AppLocalizations.of(context)!;
      return PointyErrorState(
        title: l10n.invoiceDetailsLoadError,
        icon: Icons.receipt_long_outlined,
        action: OutlinedButton.icon(
          onPressed: _retry,
          icon: const Icon(Icons.refresh),
          label: Text(l10n.retryButton),
        ),
      );
    }
    return SaleOrderDetailsContent(
      order: order,
      onReprint: widget.onReprint,
      onVoid: widget.onVoid,
      onReturn: widget.onReturn,
      useInvoiceLabels: false,
    );
  }
}
