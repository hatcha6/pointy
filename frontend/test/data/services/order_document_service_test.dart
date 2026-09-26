import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
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

  test('the sale invoice PDF names the cashier and the drawer session', () {
    const service = OrderDocumentService();
    final template = service.saleInvoiceTemplate(
      order: _saleOrder(
        receiptNumber: 'R-9',
        total: 50,
        createdAt: DateTime(2026, 5, 20, 9),
        cashierId: 4,
        cashierName: 'سالم الفيتوري',
        registerSession: 7,
        registerSessionNumber: 'RS-7',
      ),
      shopSettings: _settings,
    );

    final details = {
      for (final field in template.details) field.label: field.value,
    };
    expect(details['الكاشير'], 'سالم الفيتوري');
    expect(details['جلسة الدرج'], 'RS-7');
  });

  test('a sale with no drawer session grows no empty attribution rows', () {
    const service = OrderDocumentService();
    final template = service.saleInvoiceTemplate(
      order: _saleOrder(receiptNumber: 'R-10', total: 50),
      shopSettings: _settings,
    );

    final labels = template.details.map((field) => field.label);
    expect(labels, isNot(contains('الكاشير')));
    expect(labels, isNot(contains('جلسة الدرج')));
  });

  test('a receipt roll pairs the date with the status, the cashier with '
      'the drawer session', () {
    const service = OrderDocumentService();
    final template = service.saleInvoiceTemplate(
      order: _saleOrder(
        receiptNumber: 'R-11',
        total: 50,
        createdAt: DateTime(2026, 5, 20, 14, 5),
        paymentStatus: 'paid',
        cashierName: 'سالم الفيتوري',
        registerSessionNumber: 'RS-7',
      ),
      shopSettings: _settings,
    );

    final byLabel = {for (final field in template.details) field.label: field};
    // The date and the status speak for themselves, so the line carries the
    // values alone.
    expect(byLabel['تاريخ الإصدار']!.rollSide, OrderDocumentRollSide.start);
    expect(byLabel['تاريخ الإصدار']!.rollText, isNull);
    expect(byLabel['حالة الدفع']!.rollSide, OrderDocumentRollSide.end);
    expect(byLabel['حالة الدفع']!.rollText, isNull);
    // A bare name could be anyone's; the session reads as the till says it.
    expect(byLabel['الكاشير']!.rollSide, OrderDocumentRollSide.start);
    expect(byLabel['الكاشير']!.rollText, 'الكاشير: سالم الفيتوري');
    expect(byLabel['جلسة الدرج']!.rollSide, OrderDocumentRollSide.end);
    expect(byLabel['جلسة الدرج']!.rollText, 'جلسة RS-7');
    // A pair only forms from neighbours.
    final labels = template.details.map((field) => field.label).toList();
    expect(labels.indexOf('حالة الدفع'), labels.indexOf('تاريخ الإصدار') + 1);
    expect(labels.indexOf('جلسة الدرج'), labels.indexOf('الكاشير') + 1);
    // The customer line leads with a short label; the page keeps its heading.
    expect(template.recipientLabel, 'العميل:');
    expect(template.recipientTitle, 'فاتورة إلى:');
  });

  test('a subtotal and a payment that only repeat the total say so', () {
    const service = OrderDocumentService();
    SalePayment cash(double amount) => SalePayment(
      id: 1,
      method: PaymentMethod.cash,
      amount: amount,
      commissionPercent: 0,
      commissionAmount: 0,
    );
    Map<String, bool> restating(SaleOrder order) => {
      for (final field
          in service
              .saleInvoiceTemplate(order: order, shopSettings: _settings)
              .totals)
        field.label: field.restatesTotal,
    };

    // No discount, settled in full: both merely repeat the total. Summed in
    // floating point the payments land a hair off 30.30 — still the total.
    expect(
      restating(
        _saleOrder(
          receiptNumber: 'R-12',
          subtotal: 30.3,
          total: 30.3,
          payments: [cash(10.1), cash(20.2)],
        ),
      ),
      {'المجموع الفرعي': true, 'الإجمالي': false, 'المدفوع': true},
    );
    // A discount and a part-payment each tell the reader something new.
    expect(
      restating(
        _saleOrder(
          receiptNumber: 'R-13',
          subtotal: 30,
          discountTotal: 2,
          total: 28,
          payments: [cash(10)],
        ),
      ),
      {
        'المجموع الفرعي': false,
        'الخصم': false,
        'الإجمالي': false,
        'المدفوع': false,
        'المتبقي': false,
      },
    );
  });

  group('a sale that came back', () {
    const service = OrderDocumentService();
    SalePayment cash(double amount) => SalePayment(
      id: 1,
      method: PaymentMethod.cash,
      amount: amount,
      commissionPercent: 0,
      commissionAmount: 0,
    );
    String status(OrderDocumentTemplate template) => template.details
        .firstWhere((field) => field.label == 'حالة الدفع')
        .value;

    test('in part, settled in full, prints nothing left to pay', () {
      // Two at 5.00, paid 10.00, one handed back. The refund is a negative
      // payment, so the payments net 5.00 while the total stays 10.00 — and
      // the server counts the return towards what was settled: nothing owed.
      final template = service.saleInvoiceTemplate(
        order: _saleOrder(
          receiptNumber: 'R-returned',
          subtotal: 10,
          total: 10,
          saleType: SaleType.credit,
          payments: [cash(10), cash(-5)],
          amountPaid: 5,
          balanceDue: 0,
          paymentStatus: 'paid',
        ),
        shopSettings: _settings,
      );

      expect(
        template.details.map((field) => field.label),
        isNot(contains('المتبقي')),
      );
      expect(
        template.totals.map((field) => field.label),
        isNot(contains('المتبقي')),
      );
      expect(status(template), 'مدفوعة بالكامل');
    });

    test('whole prints as void, never as paid in full', () {
      final template = service.saleInvoiceTemplate(
        order: _saleOrder(
          receiptNumber: 'R-void',
          subtotal: 10,
          total: 10,
          payments: [cash(10), cash(-10)],
          amountPaid: 0,
          balanceDue: 0,
          paymentStatus: 'void',
        ),
        shopSettings: _settings,
      );

      expect(status(template), 'ملغاة');
      expect(
        template.totals.map((field) => field.label),
        isNot(anyOf(contains('المدفوع'), contains('المتبقي'))),
      );
    });
  });

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
      // The status follows the date, as on a sale, so a roll can print the
      // two on one line.
      expect(template.details.map((field) => field.label), [
        'تاريخ الإصدار',
        'حالة الدفع',
        'صالح حتى',
      ]);
      expect(template.details[1].value, 'عرض سعر');
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

    test(
      'each receipt roll size renders a narrow page at that width',
      () async {
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
      },
    );

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
      expect(
        _mediaBoxWidths(compact).every((w) => (w - mm(80)).abs() < 1),
        isTrue,
      );
      expect(
        _mediaBoxHeights(compact).single,
        lessThan(_mediaBoxHeights(standard).single),
      );
    });

    test('a roll render carries the media the slip actually needs', () async {
      // The whole reason a compact receipt used to come out the same length as
      // a standard one: nothing told the driver how long the slip was, so it
      // fed the queue's own roll page (80 x 297 mm on a thermal PPD) either
      // way. The render now names the media, per slip.
      final order = _saleOrder(
        receiptNumber: 'R-media',
        subtotal: 5,
        total: 5,
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
      );
      final standard = await service.buildSaleInvoiceRender(
        order: order,
        shopSettings: _settings,
        pageSize: PdfPageSize.roll80,
      );
      final compact = await service.buildSaleInvoiceRender(
        order: order,
        shopSettings: _settings,
        pageSize: PdfPageSize.roll80,
        compact: true,
      );

      for (final render in [standard, compact]) {
        expect(render.mediaWidthMm, 80);
        // The media is the page that was rendered, rounded up to a whole
        // millimetre so a remainder can never clip the last line.
        final pageHeight = _mediaBoxHeights(render.bytes).single;
        expect(render.mediaHeightMm, (pageHeight / mm(1)).ceilToDouble());
        // Comfortably inside a 297 mm roll page — which is exactly what the
        // driver fed before, for every slip.
        expect(render.mediaHeightMm, lessThan(297));
      }

      // And the dense slip asks for less paper than the standard one.
      expect(compact.mediaHeightMm, lessThan(standard.mediaHeightMm!));
    });

    test(
      'a roll render hands the platform its measured page, kept portrait',
      () async {
        // Windows has no `lp`: the plugin builds a DEVMODE from this format, so
        // it is the only thing standing between a compact slip and the driver's
        // fixed roll page. It also swaps width and length for anything wider
        // than tall, hence the portrait floor below.
        final render = await service.buildSaleInvoiceRender(
          order: _saleOrder(
            receiptNumber: 'R-platform',
            subtotal: 40,
            total: 40,
            lines: [
              // Enough rows that the slip is unambiguously taller than the roll
              // is wide, so this measures the page and not the portrait floor.
              for (var i = 0; i < 8; i++)
                SaleOrderLine(
                  id: i + 1,
                  productId: 10 + i,
                  variantId: 0,
                  quantity: 1,
                  returnedQuantity: 0,
                  returnableQuantity: 1,
                  unitLabel: 'قطعة',
                  unitPrice: 5,
                  total: 5,
                  productName: 'شاي $i',
                ),
            ],
          ),
          shopSettings: _settings,
          pageSize: PdfPageSize.roll80,
          compact: true,
        );
        final format = render.platformPageFormat;
        expect(format.width, closeTo(mm(80), 0.01));
        expect(format.height, closeTo(mm(render.mediaHeightMm!), 0.01));
        expect(format.height, greaterThan(format.width));
      },
    );

    test('a page shorter than the roll is wide stays portrait', () {
      // A slip with no line items really is shorter than 80 mm — a test print
      // measures ~55 mm — and a landscape flip would lay it across the paper
      // without a word. The floor costs a few millimetres of feed on the
      // plugin path only; the CUPS path still asks for the exact measurement.
      final render = OrderDocumentRender(
        bytes: Uint8List(0),
        mediaWidthMm: 80,
        mediaHeightMm: 40,
      );
      expect(render.platformPageFormat.width, closeTo(mm(80), 0.01));
      expect(render.platformPageFormat.height, closeTo(mm(81), 0.01));
    });

    test(
      'an A4 document names no media, so the driver keeps its own',
      () async {
        final render = await service.buildSaleInvoiceRender(
          order: _saleOrder(receiptNumber: 'R-a4-media'),
          shopSettings: _settings,
        );
        expect(render.mediaWidthMm, isNull);
        expect(render.mediaHeightMm, isNull);
        expect(render.platformPageFormat, PdfPageFormat.a4);
      },
    );

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

    test(
      'a long receipt paginates instead of overflowing one roll page',
      () async {
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
      },
    );

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

    test('the roll prints a settled sale\'s amount once; the page keeps the '
        'subtotal and the payment', () async {
      final order = _saleOrder(
        receiptNumber: 'R-once',
        subtotal: 28,
        total: 28,
        payments: const [
          SalePayment(
            id: 1,
            method: PaymentMethod.cash,
            amount: 28,
            commissionPercent: 0,
            commissionAmount: 0,
          ),
        ],
      );
      Future<int> timesPrinted(PdfPageSize size) async {
        final bytes = await service.buildSaleInvoiceBytes(
          order: order,
          shopSettings: _settings,
          pageSize: size,
        );
        return _textRuns(bytes).where((run) => run == '28.00').length;
      }

      expect(await timesPrinted(PdfPageSize.roll80), 1);
      expect(await timesPrinted(PdfPageSize.a4), 3);
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

    group('with the real Arabic fonts', () {
      // Whether two details share a line is a question of glyph widths, which
      // the Helvetica test fonts cannot answer for Arabic.
      const arabic = OrderDocumentService(fontLoader: _FileFontLoader());

      Future<double> rollHeight(SaleOrder order, PdfPageSize size) async {
        final bytes = await arabic.buildSaleInvoiceBytes(
          order: order,
          shopSettings: _settings,
          pageSize: size,
        );
        return _mediaBoxHeights(bytes).single;
      }

      test('the drawer session costs no paper beside the cashier', () async {
        final alone = await rollHeight(
          _saleOrder(
            receiptNumber: 'R-1',
            total: 28,
            cashierName: 'سالم الفيتوري',
          ),
          PdfPageSize.roll80,
        );
        final paired = await rollHeight(
          _saleOrder(
            receiptNumber: 'R-1',
            total: 28,
            cashierName: 'سالم الفيتوري',
            registerSessionNumber: 'RS-1234',
          ),
          PdfPageSize.roll80,
        );

        expect(paired, lessThanOrEqualTo(alone));
      });

      test(
        'a pair too wide for the roll takes a second line, never a clip',
        () async {
          const name = 'عبدالرحمن محمد الفيتوري';
          final alone = await rollHeight(
            _saleOrder(receiptNumber: 'R-1', total: 28, cashierName: name),
            PdfPageSize.roll58,
          );
          final paired = await rollHeight(
            _saleOrder(
              receiptNumber: 'R-1',
              total: 28,
              cashierName: name,
              registerSessionNumber: 'RS-1234',
            ),
            PdfPageSize.roll58,
          );

          expect(paired, greaterThan(alone));
        },
      );

      test('the date costs no paper beside the payment status, even on '
          '58 mm', () async {
        final undated = await rollHeight(
          _saleOrder(receiptNumber: 'R-1', total: 28, paymentStatus: 'paid'),
          PdfPageSize.roll58,
        );
        final dated = await rollHeight(
          _saleOrder(
            receiptNumber: 'R-1',
            total: 28,
            paymentStatus: 'paid',
            createdAt: DateTime(2026, 8, 18, 14, 30),
          ),
          PdfPageSize.roll58,
        );

        expect(dated, lessThanOrEqualTo(undated + 0.01));
      });

      test('the customer number and phone ride on the name\'s line', () async {
        final nameOnly = await rollHeight(
          _saleOrder(
            receiptNumber: 'R-1',
            total: 28,
            customerName: 'أحمد المهدي',
          ),
          PdfPageSize.roll80,
        );
        final full = await rollHeight(
          _saleOrder(
            receiptNumber: 'R-1',
            total: 28,
            customerName: 'أحمد المهدي',
            customerNumber: 'C-100',
            customerPhone: '0912345678',
          ),
          PdfPageSize.roll80,
        );

        expect(full, lessThanOrEqualTo(nameOnly + 0.01));
      });
    });

    // Opt-in: writes standard/compact receipt rolls at every thermal width so
    // they can be eyeballed or replayed onto a real printer.
    // Run with POINTY_ROLL_DUMP=<dir>.
    test(
      'writes standard/compact receipt rolls when POINTY_ROLL_DUMP set',
      () async {
        final dumpDir = Platform.environment['POINTY_ROLL_DUMP'];
        if (dumpDir == null || dumpDir.isEmpty) {
          return;
        }
        Directory(dumpDir).createSync(recursive: true);
        // The default loader reads the asset bundle, which is unavailable here,
        // so Arabic would silently fall back to Helvetica. Load the real fonts
        // off disk — the dump exists precisely to inspect Arabic rendering.
        const dumpService = OrderDocumentService(fontLoader: _FileFontLoader());
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
      },
    );
  });
}

/// The literal text runs a PDF draws (`[(text)]TJ`), read out of its deflated
/// content streams. Only meaningful with the Type1 test fonts, which write
/// text as literal strings; an embedded TrueType font writes glyph ids.
List<String> _textRuns(Uint8List bytes) {
  final source = String.fromCharCodes(bytes);
  final runs = <String>[];
  for (final match in RegExp(r'stream\r?\n').allMatches(source)) {
    final end = source.indexOf('endstream', match.end);
    if (end < 0) {
      continue;
    }
    final List<int> content;
    try {
      content = zlib.decode(bytes.sublist(match.end, end));
    } on FormatException {
      continue;
    }
    runs.addAll(
      RegExp(
        r'\[\((.*?)\)\]TJ',
      ).allMatches(String.fromCharCodes(content)).map((run) => run.group(1)!),
    );
  }
  return runs;
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
  double discountTotal = 0,
  double total = 0,
  DateTime? createdAt,
  String publicInvoiceUrl = '',
  SaleType saleType = SaleType.standard,
  String paymentStatus = '',
  DateTime? validUntil,
  int? cashierId,
  String? cashierName,
  int? registerSession,
  String? registerSessionNumber,
  double? amountPaid,
  double? balanceDue,
}) {
  // Unless a test says otherwise, what the server sends for an order with no
  // returns: the payments net, and the rest of the total still owed.
  final paid =
      amountPaid ?? payments.fold<double>(0, (sum, p) => sum + p.amount);
  final owed = balanceDue ?? (total - paid < 0.005 ? 0.0 : total - paid);
  return SaleOrder(
    id: 1,
    receiptNumber: receiptNumber,
    status: 'paid',
    cashierId: cashierId,
    cashierName: cashierName,
    registerSession: registerSession,
    registerSessionNumber: registerSessionNumber,
    lines: lines,
    payments: payments,
    subtotal: subtotal,
    discountTotal: discountTotal,
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
    amountPaid: paid,
    balanceDue: owed,
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
