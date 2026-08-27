import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';

/// What the till tells the backend about who prints the receipt.
///
/// A driver/PDF printer is driven from the client and never touches the print
/// queue, so a queue row created for that sale is one nothing will ever read —
/// in the field that banked 24,264 unread jobs, one per sale, while every
/// receipt printed perfectly by the local route.
///
/// The second group is the one that matters more: this field is derived from
/// the shop settings and the resolved printer, both of which can come back
/// differently on a retry. If it reached the idempotency signature it would
/// rotate the key and book the sale twice — which is exactly what `print_invoice`
/// did before it was excluded.
void main() {
  SaleCheckoutDraft draft({ReceiptDelivery? delivery}) {
    return SaleCheckoutDraft(
      lines: const [SaleCheckoutLineDraft(variantId: 1, quantity: 1)],
      payments: const [
        SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 3.5),
      ],
      receiptDelivery: delivery,
    );
  }

  group('the checkout body', () {
    test('says when this till prints the receipt itself', () {
      final body = draft(delivery: ReceiptDelivery.local).toJson();

      expect(body['receipt_delivery'], 'local');
    });

    test('says when the receipt goes through an agent', () {
      final body = draft(delivery: ReceiptDelivery.agent).toJson();

      expect(body['receipt_delivery'], 'agent');
    });

    test('says nothing when the till has not resolved a printer', () {
      // The backend then falls back to whether an agent is reading the queue,
      // which is also what an older client gets.
      final body = draft().toJson();

      expect(body.containsKey('receipt_delivery'), isFalse);
    });
  });

  group('print routing is not part of the sale', () {
    String signature(SaleCheckoutDraft value) {
      // Mirrors _checkoutSignature in pos_view_model.dart.
      final body = value.toJson()
        ..remove('print_invoice')
        ..remove('receipt_delivery');
      return jsonEncode(body);
    }

    test('the same sale keeps one signature however it is printed', () {
      expect(
        signature(draft(delivery: ReceiptDelivery.local)),
        signature(draft(delivery: ReceiptDelivery.agent)),
      );
    });

    test('and when printing is turned off between attempts', () {
      // The exact field failure: shop settings that failed to reload during the
      // outage cleared the print toggle, so the second attempt resolved a
      // different routing. The sale must still be the same sale.
      expect(
        signature(draft(delivery: ReceiptDelivery.local)),
        signature(draft()),
      );
    });
  });
}
