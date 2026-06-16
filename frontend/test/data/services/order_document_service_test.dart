import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/services/order_document_service.dart';
import 'package:pointy_frontend/src/shared/pdf/pdf.dart';

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

  test(
    'sale invoice template uses shop settings and non-empty customer info',
    () {
      const service = OrderDocumentService();
      final template = service.saleInvoiceTemplate(
        order: _saleOrder(
          receiptNumber: 'R-1',
          publicInvoiceUrl:
              'https://relay.example/invoices/installation-1/token',
          customerName: '  سارة أحمد  ',
          customerNumber: 'C-100',
          customerPhone: '',
          customerEmail: 'sara@example.com',
          payments: const [
            SalePayment(
              id: 1,
              method: PaymentMethod.cash,
              amount: 12.5,
              commissionPercent: 0,
              commissionAmount: 0,
            ),
          ],
          subtotal: 50,
          total: 50,
          createdAt: DateTime(2026, 5, 20, 9),
        ),
        shopSettings: _settings,
      );

      expect(template.shopName, 'متجر الربيع');
      expect(
        template.publicInvoiceUrl,
        'https://relay.example/invoices/installation-1/token',
      );
      expect(template.shopHeaderLines, ['شارع السوق', 'طرابلس']);
      expect(template.recipientTitle, 'فاتورة إلى:');
      expect(template.recipientLines, [
        'سارة أحمد',
        'C-100',
        'sara@example.com',
      ]);
      expect(template.details.map((field) => field.label), [
        'تاريخ الإصدار',
        'المتبقي',
      ]);
      expect(template.details.last.value, '37.50 د.ل');
      expect(template.details.last.highlight, isTrue);
      expect(template.itemsTable.columns, [
        'الصنف',
        'الكمية',
        'السعر',
        'الإجمالي',
      ]);
      expect(template.totals.map((field) => field.label), [
        'المجموع الفرعي',
        'الإجمالي',
        'المدفوع',
      ]);
      expect(template.notes, 'ملاحظات الفاتورة');
    },
  );

  test(
    'purchase template skips empty supplier fields and highlights balance due',
    () {
      const service = OrderDocumentService();
      final template = service.purchaseOrderTemplate(
        order: _purchaseOrder(
          orderNumber: 'PO-7',
          supplierName: 'مورد طرابلس',
          supplierContactName: '',
          supplierPhone: '+218911111111',
          supplierEmail: null,
          supplierAddress: 'طريق المطار',
          supplierInvoiceNumber: 'SUP-9',
          supplierInvoiceDate: DateTime(2026, 5, 18),
          dueDate: DateTime(2026, 5, 30),
          paidTotal: 5,
          balanceDue: 95,
        ),
        shopSettings: _settings,
      );

      expect(template.recipientTitle, 'فاتورة من:');
      expect(template.recipientLines, [
        'مورد طرابلس',
        '+218911111111',
        'طريق المطار',
      ]);
      expect(template.itemsTable.columns, [
        'الصنف',
        'الكمية',
        'السعر',
        'الإجمالي',
      ]);
      expect(template.details.map((field) => field.label), [
        'تاريخ فاتورة المورد',
        'رقم فاتورة المورد',
        'تاريخ الاستحقاق',
        'المتبقي',
      ]);
      expect(template.details.last.value, '95.00 د.ل');
      expect(template.details.last.highlight, isTrue);
      expect(
        template.totals.map((field) => field.label),
        isNot(contains('المتبقي')),
      );
      expect(template.totals.last.label, 'المدفوع');
    },
  );

  test('sale invoice PDF renders with an online invoice QR URL', () async {
    const service = OrderDocumentService(fontLoader: _TestFontLoader());

    final bytes = await service.buildSaleInvoiceBytes(
      order: _saleOrder(
        receiptNumber: 'R-QR',
        publicInvoiceUrl: 'https://relay.example/invoices/installation-1/token',
      ),
      shopSettings: _settings,
    );

    expect(bytes, isNotEmpty);
  });
}

class _TestFontLoader extends PointyPdfFontLoader {
  const _TestFontLoader();

  @override
  Future<PointyPdfFonts> load() async {
    return PointyPdfFonts.type1ForTests();
  }
}

SaleOrder _saleOrder({
  required String receiptNumber,
  String? customerName,
  String? customerNumber,
  String? customerPhone,
  String? customerEmail,
  List<SalePayment> payments = const [],
  double subtotal = 0,
  double total = 0,
  DateTime? createdAt,
  String publicInvoiceUrl = '',
}) {
  return SaleOrder(
    id: 1,
    receiptNumber: receiptNumber,
    status: 'paid',
    lines: const [],
    payments: payments,
    subtotal: subtotal,
    total: total,
    customerName: customerName,
    customerNumber: customerNumber,
    customerPhone: customerPhone,
    customerEmail: customerEmail,
    publicInvoiceUrl: publicInvoiceUrl,
    createdAt: createdAt,
  );
}

PurchaseOrder _purchaseOrder({
  required String orderNumber,
  String? supplierName,
  String? supplierContactName,
  String? supplierPhone,
  String? supplierEmail,
  String? supplierAddress,
  String supplierInvoiceNumber = '',
  DateTime? supplierInvoiceDate,
  DateTime? dueDate,
  double paidTotal = 0,
  double balanceDue = 0,
}) {
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
    supplierName: supplierName,
    supplierContactName: supplierContactName,
    supplierPhone: supplierPhone,
    supplierEmail: supplierEmail,
    supplierAddress: supplierAddress,
    supplierInvoiceNumber: supplierInvoiceNumber,
    supplierInvoiceDate: supplierInvoiceDate,
    dueDate: dueDate,
    paidTotal: paidTotal,
    balanceDue: balanceDue,
  );
}

const _settings = ShopSettings(
  shopName: 'متجر الربيع',
  receiptHeader: 'شارع السوق\nطرابلس',
  receiptFooter: 'ملاحظات الفاتورة',
  enableOnlineInvoices: false,
  requireOpeningCash: true,
  autoPrintReceipts: false,
  allowOverselling: false,
  preventSellingAtLoss: true,
  lowStockThreshold: 5,
  cashierReturnWindowHours: 48,
  enableCashPayments: true,
  enableCardPayments: true,
  enableTransferPayments: true,
  requireCardPaymentReceipt: false,
  trustedCardTerminalIds: [],
  cardCommissionPercent: 0,
  transferCommissionPercent: 0,
);
