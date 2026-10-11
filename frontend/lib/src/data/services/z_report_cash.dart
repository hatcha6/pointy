import '../../shared/formatters.dart';
import '../models/register_session_summary.dart';

/// The thermal Z-Report's cash section.
///
/// A blind cashier's slip carries what they counted, not what the drawer
/// should hold: the server withheld those figures
/// ([SessionCashSummary.hasReconciliation]), so their lines are left out
/// rather than printed as 0.00.
List<Map<String, Object?>> zReportCashRows(SessionCashSummary cash) {
  final reconciled = cash.hasReconciliation;
  return [
    {'label': 'النقد الافتتاحي', 'value': formatMoney(cash.openingCash)},
    if (reconciled)
      {'label': 'مبيعات نقدية', 'value': formatMoney(cash.cashSalesTotal)},
    if (reconciled && cash.payInTotal > 0)
      {'label': 'إيداع نقدي', 'value': formatMoney(cash.payInTotal)},
    if (reconciled && cash.payOutTotal > 0)
      {'label': 'سحب نقدي', 'value': formatMoney(cash.payOutTotal)},
    if (reconciled && cash.cashRefundTotal > 0)
      {'label': 'مرتجعات نقدية', 'value': formatMoney(cash.cashRefundTotal)},
    if (reconciled)
      {
        'label': 'النقد المتوقع',
        'value': formatMoney(cash.expectedCash),
        'emphasize': true,
      },
    if (cash.closingCash != null)
      {'label': 'النقد الفعلي', 'value': formatMoney(cash.closingCash!)},
    if (cash.cashVariance != null)
      {
        // Named, not signed: a bare "-12.00" reads the same as "12.00"
        // on a till slip, so the label carries the direction.
        'label': cash.cashVariance! < -0.005
            ? 'العجز'
            : cash.cashVariance! > 0.005
            ? 'الزيادة'
            : 'الفرق',
        'value': formatMoney(cash.cashVariance!.abs()),
        'emphasize': true,
      },
  ];
}
