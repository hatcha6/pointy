import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/receipt_capture.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';

/// Lots, expiry dates and serials typed on the purchase order, and how the
/// receipt starts from them. The server's `planned_receipt_capture` decides
/// for real; these prove the client offers the same answer, so the receiving
/// form and a straight-through receipt never disagree.
void main() {
  PurchaseOrderLine orderLine({
    required String mode,
    double quantity = 10,
    double received = 0,
    bool expiryRequired = false,
    List<Map<String, Object?>> plannedUnits = const [],
    List<Map<String, Object?>> plannedBatches = const [],
  }) => PurchaseOrderLine.fromJson({
    'id': 1,
    'product': 5,
    'variant': 11,
    'quantity': '$quantity',
    'accepted_quantity': '$received',
    'outstanding_quantity': '${quantity - received}',
    'unit_cost': '2.00',
    'line_total': '20.00',
    'tracking_mode': mode,
    'tracks_expiry': expiryRequired,
    'planned_units': plannedUnits,
    'planned_batches': plannedBatches,
  });

  group('what the receiving form starts from', () {
    test('one planned lot covers whatever arrives', () {
      final line = orderLine(
        mode: 'batch',
        plannedBatches: [
          {'quantity': '10', 'expiry_date': '2027-06-30'},
        ],
      );
      final capture = line.plannedCaptureFor(received: 4, damaged: 0)!;
      expect(capture.batches.single.quantity, 4);
      expect(capture.batches.single.expiryDate, DateTime(2027, 6, 30));
      expect(capture.batches.single.code, isEmpty);
    });

    test('a split plan only fills the first delivery that matches it', () {
      final batches = [
        {'code': 'A', 'quantity': '6', 'expiry_date': '2027-06-30'},
        {'code': 'B', 'quantity': '4', 'expiry_date': '2027-09-30'},
      ];
      final fresh = orderLine(mode: 'batch', plannedBatches: batches);
      expect(
        fresh.plannedCaptureFor(received: 10, damaged: 0)!.batches,
        hasLength(2),
      );
      expect(fresh.plannedCaptureFor(received: 3, damaged: 0), isNull);

      final partial = orderLine(
        mode: 'batch',
        received: 6,
        plannedBatches: batches,
      );
      expect(partial.plannedCaptureFor(received: 4, damaged: 0), isNull);
    });

    test('serials are offered on the first delivery only', () {
      final units = [
        {'code': 'IMEI-1'},
        {'code': 'IMEI-2'},
      ];
      final fresh = orderLine(mode: 'serial', quantity: 2, plannedUnits: units);
      expect(
        fresh.plannedCaptureFor(received: 2, damaged: 0)!.units,
        hasLength(2),
      );
      final partial = orderLine(
        mode: 'serial',
        quantity: 2,
        received: 1,
        plannedUnits: units,
      );
      expect(partial.plannedCaptureFor(received: 1, damaged: 0), isNull);
    });
  });

  group('receiving straight through', () {
    test('a fully planned order needs nothing scanned', () {
      final line = orderLine(
        mode: 'batch',
        expiryRequired: true,
        plannedBatches: [
          {'quantity': '10', 'expiry_date': '2027-06-30'},
        ],
      );
      expect(line.planCoversOpenReceipt, isTrue);
    });

    test(
      'a lot without the date the product requires still opens the form',
      () {
        final line = orderLine(
          mode: 'batch',
          expiryRequired: true,
          plannedBatches: [
            {'code': 'A1', 'quantity': '10'},
          ],
        );
        expect(line.planCoversOpenReceipt, isFalse);
      },
    );

    test('serials short of the count still open the form', () {
      final line = orderLine(
        mode: 'serial',
        quantity: 3,
        plannedUnits: [
          {'code': 'S1'},
        ],
      );
      expect(line.planCoversOpenReceipt, isFalse);
      expect(orderLine(mode: 'batch').planCoversOpenReceipt, isFalse);
    });
  });

  group('a draft line', () {
    const variant = ProductVariant(
      id: 11,
      productId: 5,
      sku: 'MED-1',
      productName: 'دواء',
      unitPrice: 10,
      trackingMode: TrackingMode.batch,
    );

    test('its one lot follows every quantity and pack change', () {
      final line = PurchaseDraftLine(
        variant: variant,
        quantity: 2,
        unitCost: 1,
        batches: [
          ReceiptBatchCapture(quantity: 2, expiryDate: DateTime(2027, 1, 31)),
        ],
      );
      final more = line.copyWith(quantity: 5);
      expect(more.batches.single.quantity, 5);
      final cartons = more.copyWith(unitCode: 'box', unitFactor: 12);
      expect(cartons.batches.single.quantity, 60);
      expect(cartons.batches.single.expiryDate, DateTime(2027, 1, 31));
    });

    test('a split is left alone, and says when it no longer fits', () {
      final line = PurchaseDraftLine(
        variant: variant,
        quantity: 10,
        unitCost: 1,
        batches: const [
          ReceiptBatchCapture(code: 'A', quantity: 6),
          ReceiptBatchCapture(code: 'B', quantity: 4),
        ],
      );
      expect(line.captureFits, isTrue);
      final fewer = line.copyWith(quantity: 8);
      expect(fewer.batches.map((batch) => batch.quantity), [6, 4]);
      expect(fewer.captureFits, isFalse);
    });

    test('survives being stored and restored', () {
      final line = PurchaseDraftLine(
        variant: variant,
        quantity: 3,
        unitCost: 1,
        batches: [
          ReceiptBatchCapture(quantity: 3, expiryDate: DateTime(2027, 5, 31)),
        ],
      );
      final restored = PurchaseDraftLine.fromJson(line.toJson());
      expect(restored.batches.single.expiryDate, DateTime(2027, 5, 31));
      expect(restored.batches.single.quantity, 3);
    });

    test('an edited tracked line always sends its capture, even emptied', () {
      final draft = PurchaseOrderDraft.fromDraftLines([
        const PurchaseDraftLine(variant: variant, quantity: 3, unitCost: 1),
      ], supplierId: 1);
      final json = draft.lines.single.toJson();
      expect(json['units'], isEmpty);
      expect(json['batches'], isEmpty);
    });
  });

  test('a receipt line the receiver captured names both keys, even empty', () {
    const captured = PurchaseReceiveLineDraft(
      purchaseLineId: 1,
      quantityReceived: 2,
      quantityDamaged: 0,
      capture: ReceiptLineCapture(),
    );
    expect(captured.toJson()['units'], isEmpty);
    expect(captured.toJson()['batches'], isEmpty);
    const counted = PurchaseReceiveLineDraft(
      purchaseLineId: 1,
      quantityReceived: 2,
      quantityDamaged: 0,
    );
    expect(counted.toJson().containsKey('units'), isFalse);
  });
}
