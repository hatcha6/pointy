import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/services/order_document_service.dart';

void main() {
  test('uses Arabic-safe filenames for sale and purchase PDFs', () {
    const service = OrderDocumentService();

    expect(
      service.saleInvoiceFileName(_saleOrder(receiptNumber: 'فاتورة ١٢٣')),
      'فاتورة-بيع-فاتورة-١٢٣.pdf',
    );
    expect(
      service.purchaseOrderFileName(_purchaseOrder(orderNumber: 'شراء ٤٥٦')),
      'فاتورة-مشتريات-شراء-٤٥٦.pdf',
    );
  });
}

SaleOrder _saleOrder({required String receiptNumber}) {
  return SaleOrder(
    id: 1,
    receiptNumber: receiptNumber,
    status: 'paid',
    lines: const [],
    payments: const [],
    subtotal: 0,
    total: 0,
  );
}

PurchaseOrder _purchaseOrder({required String orderNumber}) {
  return PurchaseOrder(
    id: 1,
    orderNumber: orderNumber,
    status: 'received',
    lineCount: 0,
    lines: const [],
    receipts: const [],
    adjustments: const [],
    landedCostEntries: const [],
    subtotal: 0,
    total: 0,
    canReturn: false,
    canRefund: false,
    canExchange: false,
  );
}
