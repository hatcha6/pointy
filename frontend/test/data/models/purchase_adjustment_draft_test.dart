import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/receipt_capture.dart';

/// What a supplier return, refund or exchange sends about identified stock:
/// the handsets going back by id, and what arrived scanned the way a receipt
/// scans it.
void main() {
  test('a returned line names its handsets; a plain line names nothing', () {
    const draft = PurchaseAdjustmentDraft(
      lines: [
        PurchaseAdjustmentLineDraft(lineId: 1, quantity: 2, unitIds: [7, 9]),
        PurchaseAdjustmentLineDraft(lineId: 2, quantity: 1.5),
      ],
    );

    expect(draft.toJson()['lines'], [
      {
        'line': 1,
        'quantity': '2.000',
        'units': [7, 9],
      },
      {'line': 2, 'quantity': '1.500'},
    ]);
  });

  test('a replacement carries its scanned serials and lot', () {
    const draft = PurchaseAdjustmentDraft(
      lines: [PurchaseAdjustmentLineDraft(lineId: 1, quantity: 1)],
      replacementLines: [
        PurchaseReplacementLineDraft(
          variantId: 11,
          quantity: 1,
          unitCost: 900,
          capture: ReceiptLineCapture(
            units: [ReceiptUnitCapture(code: 'SN-NEW')],
            batches: [ReceiptBatchCapture(code: 'LOT-1', quantity: 1)],
          ),
        ),
        PurchaseReplacementLineDraft(variantId: 21, quantity: 3, unitCost: 10),
      ],
    );

    expect(draft.toJson()['replacement_lines'], [
      {
        'variant': 11,
        'quantity': '1.000',
        'unit_cost': '900.00',
        'units': [
          {'code': 'SN-NEW'},
        ],
        'batches': [
          {'code': 'LOT-1', 'quantity': '1.000'},
        ],
      },
      {'variant': 21, 'quantity': '3.000', 'unit_cost': '10.00'},
    ]);
  });
}
