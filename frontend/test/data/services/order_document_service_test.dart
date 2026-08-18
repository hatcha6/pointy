import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
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
        'حالة الدفع',
        'المتبقي',
      ]);
      // No server payment_status on this fixture, so the status is derived from
      // the paid/balance figures: 12.50 paid against a 50.00 total is partial.
      expect(
        template.details
            .firstWhere((field) => field.label == 'حالة الدفع')
            .value,
        'مدفوعة جزئيًا',
      );
      expect(template.details.last.label, 'المتبقي');
      expect(template.details.last.value, '37.50 د.ل');
      expect(template.details.last.highlight, isTrue);
      expect(template.itemsTable!.columns, [
        'الصنف',
        'الكمية',
        'السعر',
        'الإجمالي',
      ]);
      expect(template.totals.map((field) => field.label), [
        'المجموع الفرعي',
        'الإجمالي',
        'المدفوع',
        'المتبقي',
      ]);
      expect(template.notes, 'ملاحظات الفاتورة');
    },
  );

  test('the sale invoice issue date carries the time, not just the day', () {
    const service = OrderDocumentService();
    final template = service.saleInvoiceTemplate(
      order: _saleOrder(
        receiptNumber: 'R-time',
        createdAt: DateTime(2026, 5, 20, 14, 5),
      ),
      shopSettings: _settings,
    );

    final issueDate = template.details
        .firstWhere((field) => field.label == 'تاريخ الإصدار')
        .value;
    expect(issueDate, '2026/05/20 14:05');
  });

  test(
    'quotation template uses the quote title and suppresses paid framing',
    () {
      const service = OrderDocumentService();
      final template = service.saleInvoiceTemplate(
        order: _saleOrder(
          receiptNumber: 'Q-1',
          subtotal: 80,
          total: 80,
          createdAt: DateTime(2026, 5, 20, 9),
          saleType: SaleType.quotation,
          paymentStatus: 'quotation',
          validUntil: DateTime(2026, 6, 20),
        ),
        shopSettings: _settings,
      );

      expect(template.title, 'فاتورة عرض');
      expect(template.details.map((field) => field.label), [
        'تاريخ الإصدار',
        'صالح حتى',
        'حالة الدفع',
      ]);
      expect(template.details.last.value, 'عرض سعر');
      // A quote owes nothing: no paid / balance-due rows in the totals.
      expect(
        template.totals.map((field) => field.label),
        isNot(anyOf(contains('المدفوع'), contains('المتبقي'))),
      );
      expect(template.totals.map((field) => field.label), [
        'المجموع الفرعي',
        'الإجمالي',
      ]);
      // The quote carries a "this is not a sale/tax invoice" notice.
      expect(template.terms, isNotNull);
      expect(template.terms, contains('عرض سعر'));
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
      expect(template.itemsTable!.columns, [
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

  test('receipt proof (سند قبض) carries the amount, party and balance', () {
    const service = OrderDocumentService();
    final template = service.proofOfPaymentTemplate(
      proof: PaymentProof(
        kind: PaymentProofKind.receipt,
        reference: '42',
        partyName: 'سارة أحمد',
        partyContact: 'C-100',
        relatedDocumentNumber: 'R-1',
        amount: 30,
        method: 'نقدًا',
        externalReference: 'REF-9',
        handledBy: 'الكاشير',
        balanceAfter: 20,
        createdAt: DateTime(2026, 5, 20, 9),
      ),
      shopSettings: _settings,
    );

    expect(template.title, 'سند قبض');
    expect(template.recipientTitle, 'استلمنا من');
    expect(template.recipientLines, ['سارة أحمد', 'C-100']);
    // Payment particulars render through the shared styled table (like invoice
    // line-items); only the amount + balance stay in the emphasized totals.
    expect(template.itemsTable!.columns, ['البيان', 'التفاصيل']);
    expect(template.itemsTable!.rows, [
      ['طريقة الدفع', 'نقدًا'],
      ['المرجع', 'REF-9'],
      ['حصّلها', 'الكاشير'],
    ]);
    expect(template.details.map((field) => field.label), [
      'تاريخ الإصدار',
      'بخصوص الفاتورة',
    ]);
    expect(template.totals.map((field) => field.label), [
      'المبلغ',
      'الرصيد بعد الدفع',
    ]);
    expect(template.totals.first.value, '30.00 د.ل');
    expect(template.totals.first.highlight, isTrue);
    expect(template.totals.last.value, '20.00 د.ل');
  });

  test('disbursement proof (سند صرف) uses the supplier framing', () {
    const service = OrderDocumentService();
    final template = service.proofOfPaymentTemplate(
      proof: const PaymentProof(
        kind: PaymentProofKind.disbursement,
        reference: '7',
        partyName: 'مورد طرابلس',
        relatedDocumentNumber: 'PO-7',
        amount: 95,
        method: 'تحويل',
      ),
      shopSettings: _settings,
    );

    expect(template.title, 'سند صرف');
    expect(template.recipientTitle, 'صرفنا إلى');
    expect(template.details.map((field) => field.label), [
      'تاريخ الإصدار',
      'بخصوص أمر الشراء',
    ]);
    // No commission / reference / handler supplied → the table is just the
    // method; with no balance the totals are just the amount.
    expect(template.itemsTable!.rows, [
      ['طريقة الدفع', 'تحويل'],
    ]);
    expect(template.totals.map((field) => field.label), ['المبلغ']);
    expect(
      service.proofOfPaymentFileName(
        const PaymentProof(
          kind: PaymentProofKind.disbursement,
          reference: '7',
          partyName: 'مورد طرابلس',
          amount: 95,
          method: 'تحويل',
        ),
      ),
      'سند-صرف-7.pdf',
    );
  });

  testWidgets('font loader reads the bundled PDF font bytes via rootBundle', (
    tester,
  ) async {
    final data = await const PointyPdfFontLoader().loadData();
    expect(data, isA<TtfPointyPdfFontData>());
  });

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

  group('receipt-width PDF output', () {
    const service = OrderDocumentService(fontLoader: _TestFontLoader());

    // 1 mm in PDF points (1 pt = 1/72 inch).
    double mm(num value) => value * 72 / 25.4;

    test('the default A4 page size renders a full 210mm-wide page', () async {
      final bytes = await service.buildSaleInvoiceBytes(
        order: _saleOrder(receiptNumber: 'R-A4'),
        shopSettings: _settings,
      );
      final widths = _mediaBoxWidths(bytes);
      expect(widths, isNotEmpty);
      expect(widths.every((w) => (w - mm(210)).abs() < 1), isTrue);
    });

    test('each receipt roll size renders a narrow page at that width', () async {
      const cases = <(PdfPageSize, int)>[
        (PdfPageSize.roll58, 58),
        (PdfPageSize.roll70, 70),
        (PdfPageSize.roll80, 80),
      ];
      for (final (size, widthMm) in cases) {
        final bytes = await service.buildSaleInvoiceBytes(
          order: _saleOrder(receiptNumber: 'R-$widthMm'),
          shopSettings: _settings,
          pageSize: size,
        );
        final widths = _mediaBoxWidths(bytes);
        expect(widths, isNotEmpty, reason: 'no page rendered for $size');
        expect(
          widths.every((w) => (w - mm(widthMm)).abs() < 1),
          isTrue,
          reason: '$size should be ${widthMm}mm wide, got $widths',
        );
      }
    });

    test('a receipt roll is a single content-height page, not A4', () async {
      final bytes = await service.buildSaleInvoiceBytes(
        order: _saleOrder(
          receiptNumber: 'R-1',
          subtotal: 10,
          total: 10,
          payments: const [
            SalePayment(
              id: 1,
              method: PaymentMethod.cash,
              amount: 10,
              commissionPercent: 0,
              commissionAmount: 0,
            ),
          ],
          createdAt: DateTime(2026, 5, 20, 9),
        ),
        shopSettings: _settings,
        pageSize: PdfPageSize.roll80,
      );
      final heights = _mediaBoxHeights(bytes);
      expect(heights.length, 1);
      // Content-driven height, comfortably under A4's 841.9pt.
      expect(heights.single, lessThan(mm(297)));
    });

    test('a sale with line items renders on the receipt roll', () async {
      final bytes = await service.buildSaleInvoiceBytes(
        order: _saleOrder(
          receiptNumber: 'R-lines',
          lines: const [
            SaleOrderLine(
              id: 1,
              productId: 10,
              variantId: 0,
              quantity: 2,
              returnedQuantity: 0,
              returnableQuantity: 2,
              unitLabel: 'قطعة',
              unitPrice: 5,
              total: 10,
              productName: 'شاي',
            ),
          ],
        ),
        shopSettings: _settings,
        pageSize: PdfPageSize.roll80,
      );
      final widths = _mediaBoxWidths(bytes);
      expect(widths, isNotEmpty);
      expect(widths.every((w) => (w - mm(80)).abs() < 1), isTrue);
    });

    test('a compact receipt roll is shorter than the standard one', () async {
      final order = _saleOrder(
        receiptNumber: 'R-dense',
        lines: const [
          SaleOrderLine(
            id: 1,
            productId: 10,
            variantId: 0,
            quantity: 2,
            returnedQuantity: 0,
            returnableQuantity: 2,
            unitLabel: 'قطعة',
            unitPrice: 5,
            total: 10,
            productName: 'شاي',
          ),
          SaleOrderLine(
            id: 2,
            productId: 11,
            variantId: 0,
            quantity: 1,
            returnedQuantity: 0,
            returnableQuantity: 1,
            unitLabel: 'قطعة',
            unitPrice: 3,
            total: 3,
            productName: 'قهوة',
          ),
        ],
      );
      final standard = await service.buildSaleInvoiceBytes(
        order: order,
        shopSettings: _settings,
        pageSize: PdfPageSize.roll80,
      );
      final compact = await service.buildSaleInvoiceBytes(
        order: order,
        shopSettings: _settings,
        pageSize: PdfPageSize.roll80,
        compact: true,
      );

      // Same 80mm width, but the dense slip advances less paper.
      expect(_mediaBoxWidths(compact).every((w) => (w - mm(80)).abs() < 1), isTrue);
      expect(_mediaBoxHeights(compact).single, lessThan(_mediaBoxHeights(standard).single));
    });

    test('a compact A4 invoice still renders a full-width page', () async {
      final bytes = await service.buildSaleInvoiceBytes(
        order: _saleOrder(receiptNumber: 'R-A4-dense'),
        shopSettings: _settings,
        compact: true,
      );
      final widths = _mediaBoxWidths(bytes);
      expect(widths, isNotEmpty);
      expect(widths.every((w) => (w - mm(210)).abs() < 1), isTrue);
    });

    test('a long receipt paginates instead of overflowing one roll page', () async {
      // Far more items than fit on a single roll segment.
      final lines = [
        for (var i = 0; i < 80; i++)
          SaleOrderLine(
            id: i + 1,
            productId: 100 + i,
            variantId: 0,
            quantity: 1,
            returnedQuantity: 0,
            returnableQuantity: 1,
            unitLabel: 'قطعة',
            unitPrice: 3,
            total: 3,
            productName: 'صنف رقم $i',
          ),
      ];
      final bytes = await service.buildSaleInvoiceBytes(
        order: _saleOrder(
          receiptNumber: 'R-long',
          lines: lines,
          subtotal: 240,
          total: 240,
        ),
        shopSettings: _settings,
        pageSize: PdfPageSize.roll80,
      );

      final heights = _mediaBoxHeights(bytes);
      final widths = _mediaBoxWidths(bytes);
      // Content overran one segment, so it flows across several pages instead of
      // one over-tall page (which pushed the total off the top of the slip).
      expect(heights.length, greaterThan(1));
      // Every page is a bounded 80mm-wide roll segment no taller than the cap.
      expect(widths.every((w) => (w - mm(80)).abs() < 1), isTrue);
      final cap = mm(80) * 6;
      expect(heights.every((h) => h <= cap + 1), isTrue);
    });

    test('a short receipt stays a single continuous page', () async {
      final bytes = await service.buildSaleInvoiceBytes(
        order: _saleOrder(
          receiptNumber: 'R-short',
          lines: const [
            SaleOrderLine(
              id: 1,
              productId: 10,
              variantId: 0,
              quantity: 1,
              returnedQuantity: 0,
              returnableQuantity: 1,
              unitLabel: 'قطعة',
              unitPrice: 5,
              total: 5,
              productName: 'شاي',
            ),
          ],
          subtotal: 5,
          total: 5,
        ),
        shopSettings: _settings,
        pageSize: PdfPageSize.roll80,
      );

      // A normal receipt is not paginated — one content-height page, no tail.
      expect(_mediaBoxHeights(bytes).length, 1);
    });

    test('purchase orders and proofs honor the receipt width too', () async {
      final poBytes = await service.buildPurchaseOrderBytes(
        order: _purchaseOrder(orderNumber: 'PO-1'),
        shopSettings: _settings,
        pageSize: PdfPageSize.roll58,
      );
      final proofBytes = await service.buildProofOfPaymentBytes(
        proof: const PaymentProof(
          kind: PaymentProofKind.receipt,
          reference: 'P-1',
          partyName: 'سارة',
          amount: 25,
          method: 'نقدًا',
        ),
        shopSettings: _settings,
        pageSize: PdfPageSize.roll58,
      );
      for (final widths in [
        _mediaBoxWidths(poBytes),
        _mediaBoxWidths(proofBytes),
      ]) {
        expect(widths, isNotEmpty);
        expect(widths.every((w) => (w - mm(58)).abs() < 1), isTrue);
      }
    });

    // Opt-in: writes standard/compact receipt rolls at every thermal width so
    // they can be eyeballed or replayed onto a real printer.
    // Run with POINTY_ROLL_DUMP=<dir>.
    test('writes standard/compact receipt rolls when POINTY_ROLL_DUMP set', () async {
      final dumpDir = Platform.environment['POINTY_ROLL_DUMP'];
      if (dumpDir == null || dumpDir.isEmpty) {
        return;
      }
      Directory(dumpDir).createSync(recursive: true);
      // The default loader reads the asset bundle, which is unavailable here,
      // so Arabic would silently fall back to Helvetica. Load the real fonts
      // off disk — the dump exists precisely to inspect Arabic rendering.
      const dumpService = OrderDocumentService(
        fontLoader: _FileFontLoader(),
      );
      final order = _saleOrder(
        receiptNumber: 'R-2026-0042',
        customerName: 'أحمد المهدي',
        subtotal: 41,
        total: 41,
        createdAt: DateTime(2026, 8, 18, 14, 30),
        lines: const [
          SaleOrderLine(
            id: 1,
            productId: 10,
            variantId: 0,
            quantity: 2,
            returnedQuantity: 0,
            returnableQuantity: 2,
            unitLabel: 'قطعة',
            unitPrice: 5,
            total: 10,
            productName: 'شاي أخضر سيلاني ٢٠٠ جرام',
          ),
          SaleOrderLine(
            id: 2,
            productId: 11,
            variantId: 0,
            quantity: 3,
            returnedQuantity: 0,
            returnableQuantity: 3,
            unitLabel: 'كرتونة',
            unitPrice: 6,
            total: 18,
            productName: 'قهوة عربية مطحونة',
          ),
          SaleOrderLine(
            id: 3,
            productId: 12,
            variantId: 0,
            quantity: 1,
            returnedQuantity: 0,
            returnableQuantity: 1,
            unitLabel: 'قطعة',
            unitPrice: 13,
            total: 13,
            productName: 'شامبو للأطفال ٤٠٠ مل خالي من الدموع',
          ),
        ],
      );

      for (final (size, mmWidth) in const [
        (PdfPageSize.roll58, 58),
        (PdfPageSize.roll70, 70),
        (PdfPageSize.roll80, 80),
      ]) {
        for (final compact in const [false, true]) {
          final bytes = await dumpService.buildSaleInvoiceBytes(
            order: order,
            shopSettings: _settings,
            pageSize: size,
            compact: compact,
          );
          final tag = compact ? 'compact' : 'standard';
          await File(
            '$dumpDir/$tag-$mmWidth.pdf',
          ).writeAsBytes(bytes, flush: true);
        }
      }
      expect(Directory(dumpDir).listSync(), isNotEmpty);
    });
  });
}

/// Widths (x1) of every `/MediaBox [x0 y0 x1 y1]` in the PDF bytes. The page
/// dictionary is written inline (not object-streamed) by the `pdf` package, so
/// the media box is greppable — enough to assert the rendered page geometry
/// without a full PDF parser.
List<double> _mediaBoxWidths(Uint8List bytes) => _mediaBox(bytes, 3);

List<double> _mediaBoxHeights(Uint8List bytes) => _mediaBox(bytes, 4);

List<double> _mediaBox(Uint8List bytes, int group) {
  final text = String.fromCharCodes(bytes);
  final re = RegExp(
    r'MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)',
  );
  return re.allMatches(text).map((m) => double.parse(m.group(group)!)).toList();
}

class _TestFontLoader extends PointyPdfFontLoader {
  const _TestFontLoader();

  @override
  Future<PointyPdfFontData> loadData() async => const Type1PointyPdfFontData();
}

SaleOrder _saleOrder({
  required String receiptNumber,
  String? customerName,
  String? customerNumber,
  String? customerPhone,
  String? customerEmail,
  List<SalePayment> payments = const [],
  List<SaleOrderLine> lines = const [],
  double subtotal = 0,
  double total = 0,
  DateTime? createdAt,
  String publicInvoiceUrl = '',
  SaleType saleType = SaleType.standard,
  String paymentStatus = '',
  DateTime? validUntil,
}) {
  return SaleOrder(
    id: 1,
    receiptNumber: receiptNumber,
    status: 'paid',
    lines: lines,
    payments: payments,
    subtotal: subtotal,
    total: total,
    customerName: customerName,
    customerNumber: customerNumber,
    customerPhone: customerPhone,
    customerEmail: customerEmail,
    publicInvoiceUrl: publicInvoiceUrl,
    createdAt: createdAt,
    saleType: saleType,
    paymentStatus: paymentStatus,
    validUntil: validUntil,
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

/// Loads the bundled Arabic TTFs straight off disk so dumped PDFs shape Arabic
/// correctly (the asset bundle is not available under `flutter test`).
class _FileFontLoader extends PointyPdfFontLoader {
  const _FileFontLoader();

  @override
  Future<PointyPdfFontData> loadData() async {
    final base = await File(
      'assets/fonts/IBMPlexSansArabic-Regular.ttf',
    ).readAsBytes();
    final bold = await File(
      'assets/fonts/IBMPlexSansArabic-Bold.ttf',
    ).readAsBytes();
    return TtfPointyPdfFontData(
      base: ByteData.view(Uint8List.fromList(base).buffer),
      bold: ByteData.view(Uint8List.fromList(bold).buffer),
    );
  }
}
