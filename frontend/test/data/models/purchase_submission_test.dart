import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';

void main() {
  test('purchase draft serializes named landed cost entries', () {
    final draft = PurchaseOrderDraft(
      supplierId: 14,
      landedCostAllocationMethod: LandedCostAllocationMethod.byQuantity,
      landedCostEntries: const [
        PurchaseLandedCostEntry(name: 'شحن', cost: 0.60),
        PurchaseLandedCostEntry(name: 'تخليص', cost: 0.40),
      ],
      lines: const [
        PurchaseOrderLineDraft(variantId: 7, quantity: 2, unitCost: 3.50),
      ],
    );

    final json = draft.toJson();

    expect(json['shipping_amount'], isNull);
    expect(json['customs_amount'], isNull);
    expect(json['handling_amount'], isNull);
    expect(json['landed_cost_allocation_method'], 'quantity');
    expect(json['landed_cost_entries'], [
      {'name': 'شحن', 'amount': '0.60'},
      {'name': 'تخليص', 'amount': '0.40'},
    ]);
  });

  test('a purchase draft line round-trips through json persistence', () {
    const variant = ProductVariant(
      id: 55,
      productId: 9,
      productName: 'دقيق',
      sku: 'FL-1',
      unitPrice: 2.0,
      unit: 'kg',
      tracksExpiry: true,
      productDetail: Product(
        id: 9,
        name: 'دقيق',
        quantityOnHand: 0,
        tracksExpiry: true,
      ),
    );
    final line = PurchaseDraftLine(
      variant: variant,
      quantity: 4,
      unitCost: 18.5,
      unitCode: 'bag',
      unitLabel: 'كيس',
      unitFactor: 25,
      expiryDate: DateTime(2026, 12, 31),
    );

    final restored = PurchaseDraftLine.fromJson(
      (jsonDecode(jsonEncode(line.toJson())) as Map).cast<String, Object?>(),
    );

    expect(restored.variant.id, 55);
    expect(restored.variant.tracksExpiry, isTrue);
    // productDetail is carried so the restored line keeps its unit metadata
    // (the per-line unit dropdown depends on it).
    expect(restored.variant.productDetail?.id, 9);
    expect(restored.variant.productDetail?.tracksExpiry, isTrue);
    expect(restored.quantity, 4);
    expect(restored.unitCost, 18.5);
    expect(restored.unitCode, 'bag');
    expect(restored.unitFactor, 25);
    expect(restored.expiryDate, DateTime(2026, 12, 31));
  });

  test('purchase lines serialize and parse expiry tracking fields', () {
    final line = PurchaseOrderLineDraft(
      variantId: 7,
      quantity: 2,
      unitCost: 3.50,
      expiryDate: DateTime(2026, 12, 31),
    );

    expect(line.toJson(), {
      'variant': 7,
      'quantity': 2,
      'unit_cost': '3.50',
      'expiry_date': '2026-12-31',
    });

    final parsed = PurchaseOrderLine.fromJson({
      'id': 1,
      'product': 1,
      'variant': 7,
      'tracks_expiry': true,
      'expiry_date': '2026-12-31',
      'quantity': 2,
      'adjusted_quantity': 0,
      'adjustable_quantity': 2,
      'unit_cost': '3.50',
      'line_total': '7.00',
    });

    expect(parsed.tracksExpiry, isTrue);
    expect(parsed.expiryDate, DateTime(2026, 12, 31));
  });

  test('purchase receive draft serializes expiry date', () {
    final draft = PurchaseReceiveDraft(
      lines: [
        PurchaseReceiveLineDraft(
          purchaseLineId: 9,
          quantityReceived: 4,
          quantityDamaged: 0,
          expiryDate: DateTime(2026, 8, 15),
        ),
      ],
    );

    expect(draft.toJson(), {
      'lines': [
        {
          'purchase_line': 9,
          'quantity_received': 4,
          'quantity_damaged': 0,
          'expiry_date': '2026-08-15',
        },
      ],
    });
  });

  test('purchase order reads landed cost entries and allocated line cost', () {
    final order = PurchaseOrder.fromJson({
      'id': 200,
      'order_number': 'P200',
      'status': 'draft',
      'supplier': 14,
      'lines': [
        {
          'id': 1,
          'product': 1,
          'variant': 7,
          'quantity': 2,
          'adjusted_quantity': 0,
          'adjustable_quantity': 2,
          'unit_cost': '3.50',
          'line_total': '7.00',
          'allocated_landed_cost': '1.00',
          'landed_unit_cost': '0.50',
          'effective_unit_cost': '4.00',
          'effective_line_total': '8.00',
        },
      ],
      'receipts': const [],
      'adjustments': const [],
      'subtotal': '7.00',
      'landed_cost_entries': [
        {'id': 1, 'name': 'شحن', 'amount': '1.00'},
      ],
      'landed_cost_total': '1.00',
      'total': '8.00',
    });

    expect(order.landedCostTotal, 1);
    expect(order.landedCostEntries.single.name, 'شحن');
    expect(order.lines.single.unitCost, 3.5);
    expect(order.lines.single.landedCostAllocation, 1);
    expect(order.lines.single.effectiveUnitCost, 4);
  });

  test('purchase discount preview reads allocated landed cost lines', () {
    final preview = PurchaseDiscountPreview.fromJson({
      'subtotal': '7.00',
      'discount_total': '1.00',
      'landed_cost_total': '0.60',
      'total': '6.60',
      'lines': [
        {
          'product': 1,
          'variant': 7,
          'quantity': 2,
          'unit_cost': '3.50',
          'line_total': '7.00',
          'discount_amount': '1.00',
          'net_line_total': '6.00',
          'net_unit_cost': '3.00',
          'allocated_landed_cost': '0.60',
          'landed_unit_cost': '0.30',
          'effective_unit_cost': '3.30',
          'effective_line_total': '6.60',
        },
      ],
      'applied_discounts': const [],
      'unapplied_discount_codes': const [],
    });

    expect(preview.lines.single.variantId, 7);
    expect(preview.lines.single.discountAmount, 1);
    expect(preview.lines.single.allocatedLandedCost, 0.6);
    expect(preview.lines.single.landedUnitCost, 0.3);
    expect(preview.lines.single.effectiveUnitCost, 3.3);
    expect(preview.lines.single.effectiveLineTotal, 6.6);
  });
}
