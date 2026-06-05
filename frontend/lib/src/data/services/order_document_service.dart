import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/printer_config.dart';
import '../models/purchase_submission.dart';
import '../models/sale_order.dart';
import '../models/shop_settings.dart';
import 'order_document_action.dart';
import 'order_document_web_delivery.dart';
import 'print_transport.dart';

export 'order_document_action.dart';

class OrderDocumentService {
  const OrderDocumentService({
    this.labels = const OrderDocumentLabels.arabic(),
    this.fontLoader = const OrderDocumentFontLoader(),
    this.webDelivery = const OrderDocumentWebDelivery(),
  });

  final OrderDocumentLabels labels;
  final OrderDocumentFontLoader fontLoader;
  final OrderDocumentWebDelivery webDelivery;

  String get deliveryChannel {
    if (kIsWeb) {
      return webDelivery.deliveryChannel;
    }
    return _shouldSaveWithDialog ? 'file_save_dialog' : 'native_share_sheet';
  }

  Future<List<PrinterEndpoint>> discoverDocumentPrinters() async {
    final info = await Printing.info();
    if (!info.canPrint) {
      return const [];
    }

    final endpoints = <String, PrinterEndpoint>{
      'system-default': const PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: '',
        address: '',
        outputMode: PrinterOutputMode.pdfA4,
      ),
    };

    if (!info.canListPrinters) {
      return endpoints.values.toList(growable: false);
    }

    final printers = await Printing.listPrinters();
    for (final printer in printers) {
      if (!printer.isAvailable) {
        continue;
      }
      endpoints[printer.url] = PrinterEndpoint(
        kind: PrintTransportKind.system,
        name: printer.name,
        address: printer.url,
        outputMode: PrinterOutputMode.pdfA4,
      );
    }
    return endpoints.values.toList(growable: false);
  }

  Future<PrintTransportStatus> printerStatus(PrinterEndpoint endpoint) async {
    try {
      final info = await Printing.info();
      if (!info.canPrint) {
        return const PrintTransportStatus(
          isAvailable: false,
          message: 'document printing unavailable',
        );
      }
      if (endpoint.address.trim().isEmpty || !info.canListPrinters) {
        return const PrintTransportStatus(
          isAvailable: true,
          message: 'system print dialog ready',
        );
      }
      final printer = await _resolvePrinter(endpoint);
      return PrintTransportStatus(
        isAvailable: printer?.isAvailable ?? false,
        message: printer?.isAvailable == true
            ? 'document printer ready'
            : 'document printer unavailable',
      );
    } on Object catch (error) {
      return PrintTransportStatus(
        isAvailable: false,
        message: 'document printer status failed: $error',
      );
    }
  }

  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    try {
      final printed = await _printPdf(
        bytesBuilder: () => _buildTestPdf(),
        jobName: labels.testPrintTitle,
        endpoint: endpoint,
      );
      return printed
          ? const PrintTransportResult.success('document test print sent')
          : const PrintTransportResult.failure('document print canceled');
    } on Object catch (error) {
      return PrintTransportResult.failure('document test print failed: $error');
    }
  }

  Future<bool> printSaleInvoice({
    required SaleOrder order,
    ShopSettings? shopSettings,
    PrinterEndpoint? endpoint,
  }) {
    return _printPdf(
      bytesBuilder: () =>
          buildSaleInvoiceBytes(order: order, shopSettings: shopSettings),
      jobName: saleInvoiceFileName(order),
      endpoint: endpoint,
    );
  }

  Future<bool> printPurchaseOrder({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
    PrinterEndpoint? endpoint,
  }) {
    return _printPdf(
      bytesBuilder: () =>
          buildPurchaseOrderBytes(order: order, shopSettings: shopSettings),
      jobName: purchaseOrderFileName(order),
      endpoint: endpoint,
    );
  }

  Future<OrderDocumentActionStatus> shareSaleInvoice({
    required SaleOrder order,
    ShopSettings? shopSettings,
    Rect? bounds,
  }) async {
    try {
      final bytes = await buildSaleInvoiceBytes(
        order: order,
        shopSettings: shopSettings,
      );
      return _deliverPdf(
        bytes: bytes,
        filename: saleInvoiceFileName(order),
        subject: labels.saleInvoiceTitle,
        bounds: bounds,
      );
    } on Object {
      return OrderDocumentActionStatus.failed;
    }
  }

  Future<OrderDocumentActionStatus> sharePurchaseOrder({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
    Rect? bounds,
  }) async {
    try {
      final bytes = await buildPurchaseOrderBytes(
        order: order,
        shopSettings: shopSettings,
      );
      return _deliverPdf(
        bytes: bytes,
        filename: purchaseOrderFileName(order),
        subject: labels.purchaseOrderTitle,
        bounds: bounds,
      );
    } on Object {
      return OrderDocumentActionStatus.failed;
    }
  }

  Future<Uint8List> buildSaleInvoiceBytes({
    required SaleOrder order,
    ShopSettings? shopSettings,
  }) async {
    final fonts = await fontLoader.load();
    final document = _DocumentFrame(
      title: labels.saleInvoiceTitle,
      reference: _saleReference(order),
      shopSettings: shopSettings,
      labels: labels,
      fonts: fonts,
      sections: [
        _DocumentSection(
          title: labels.summary,
          rows: [
            _DocumentField(labels.invoiceNumber, _saleReference(order)),
            _DocumentField(labels.status, labels.saleStatus(order.status)),
            if (order.customerName?.trim().isNotEmpty == true)
              _DocumentField(labels.customer, order.customerName!.trim()),
            if (order.registerSessionNumber?.trim().isNotEmpty == true)
              _DocumentField(
                labels.registerSession,
                order.registerSessionNumber!.trim(),
              ),
            if (order.createdAt != null)
              _DocumentField(
                labels.issueDate,
                _formatDateTime(order.createdAt!),
              ),
          ],
        ),
        _DocumentSection(
          title: labels.items,
          table: _DocumentTable(
            columns: [
              labels.product,
              labels.quantity,
              labels.unitPrice,
              labels.lineTotal,
            ],
            rows: [
              for (final line in order.lines)
                [
                  _saleLineName(line),
                  '${line.quantity}',
                  _formatMoney(line.unitPrice),
                  _formatMoney(line.total),
                ],
            ],
            columnFlex: const [2.8, 0.8, 1.1, 1.1],
          ),
        ),
        if (order.payments.isNotEmpty)
          _DocumentSection(
            title: labels.payments,
            table: _DocumentTable(
              columns: [labels.paymentMethod, labels.amount],
              rows: [
                for (final payment in order.payments)
                  [
                    labels.paymentMethodLabel(payment.method),
                    _formatMoney(payment.amount),
                  ],
              ],
              columnFlex: const [2, 1],
            ),
          ),
        _DocumentSection(
          title: labels.totals,
          rows: [
            _DocumentField(labels.subtotal, _formatMoney(order.subtotal)),
            if (order.discountTotal > 0)
              _DocumentField(
                labels.discount,
                _formatMoney(order.discountTotal),
              ),
            _DocumentField(
              labels.total,
              _formatMoney(order.total),
              strong: true,
            ),
          ],
        ),
      ],
    );
    return document.build();
  }

  Future<Uint8List> buildPurchaseOrderBytes({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
  }) async {
    final fonts = await fontLoader.load();
    final document = _DocumentFrame(
      title: labels.purchaseOrderTitle,
      reference: _purchaseReference(order),
      shopSettings: shopSettings,
      labels: labels,
      fonts: fonts,
      sections: [
        _DocumentSection(
          title: labels.summary,
          rows: [
            _DocumentField(
              labels.purchaseOrderNumber,
              _purchaseReference(order),
            ),
            if (order.supplierInvoiceNumber.trim().isNotEmpty)
              _DocumentField(
                labels.supplierInvoiceNumber,
                order.supplierInvoiceNumber.trim(),
              ),
            if (order.supplierName?.trim().isNotEmpty == true)
              _DocumentField(labels.supplier, order.supplierName!.trim()),
            _DocumentField(labels.status, labels.purchaseStatus(order.status)),
            if (order.createdAt != null)
              _DocumentField(
                labels.createdAt,
                _formatDateTime(order.createdAt!),
              ),
            if (order.submittedAt != null)
              _DocumentField(
                labels.submittedAt,
                _formatDateTime(order.submittedAt!),
              ),
            if (order.receivedAt != null)
              _DocumentField(
                labels.receivedAt,
                _formatDateTime(order.receivedAt!),
              ),
            if (order.dueDate != null)
              _DocumentField(labels.dueDate, _formatDate(order.dueDate!)),
          ],
        ),
        _DocumentSection(
          title: labels.items,
          table: _DocumentTable(
            columns: [
              labels.product,
              labels.quantity,
              labels.received,
              labels.unitCost,
              labels.lineTotal,
            ],
            rows: [
              for (final line in order.lines)
                [
                  line.displayName.trim().isEmpty
                      ? labels.unknownProduct
                      : line.displayName.trim(),
                  '${line.quantity}',
                  '${line.receivedQuantity}',
                  _formatMoney(line.effectiveUnitCost ?? line.unitCost),
                  _formatMoney(line.landedLineTotal ?? line.total),
                ],
            ],
            columnFlex: const [2.5, 0.7, 0.8, 1, 1],
          ),
        ),
        _DocumentSection(
          title: labels.totals,
          rows: [
            _DocumentField(labels.subtotal, _formatMoney(order.subtotal)),
            if (order.discountTotal > 0)
              _DocumentField(
                labels.discount,
                _formatMoney(order.discountTotal),
              ),
            if (order.landedCostTotal > 0)
              _DocumentField(
                labels.landedCost,
                _formatMoney(order.landedCostTotal),
              ),
            _DocumentField(
              labels.total,
              _formatMoney(order.total),
              strong: true,
            ),
            if (order.paidTotal > 0)
              _DocumentField(labels.paid, _formatMoney(order.paidTotal)),
            if (order.balanceDue > 0)
              _DocumentField(
                labels.balanceDue,
                _formatMoney(order.balanceDue),
                strong: true,
              ),
          ],
        ),
      ],
    );
    return document.build();
  }

  String saleInvoiceFileName(SaleOrder order) {
    return 'sale-invoice-${_safeReference(_saleReference(order))}.pdf';
  }

  String purchaseOrderFileName(PurchaseOrder order) {
    return 'purchase-order-${_safeReference(_purchaseReference(order))}.pdf';
  }

  Future<bool> _printPdf({
    required Future<Uint8List> Function() bytesBuilder,
    required String jobName,
    PrinterEndpoint? endpoint,
  }) async {
    final bytes = await bytesBuilder();
    final selectedPrinter = endpoint == null
        ? null
        : await _resolvePrinter(endpoint);
    if (selectedPrinter != null) {
      return Printing.directPrintPdf(
        printer: selectedPrinter,
        name: jobName,
        format: PdfPageFormat.a4,
        onLayout: (_) async => bytes,
        usePrinterSettings: true,
      );
    }
    return Printing.layoutPdf(
      name: jobName,
      format: PdfPageFormat.a4,
      usePrinterSettings: true,
      onLayout: (_) async => bytes,
    );
  }

  Future<Printer?> _resolvePrinter(PrinterEndpoint endpoint) async {
    final info = await Printing.info();
    if (!info.canListPrinters) {
      return null;
    }
    final printers = await Printing.listPrinters();
    final address = endpoint.address.trim();
    if (address.isNotEmpty) {
      return printers
          .where((printer) => printer.url == address && printer.isAvailable)
          .firstOrNull;
    }
    return printers.where((printer) => printer.isDefault).firstOrNull;
  }

  Future<OrderDocumentActionStatus> _deliverPdf({
    required Uint8List bytes,
    required String filename,
    String? subject,
    Rect? bounds,
  }) async {
    if (kIsWeb) {
      return webDelivery.deliverPdf(
        bytes: bytes,
        filename: filename,
        subject: subject,
      );
    }

    if (_shouldSaveWithDialog) {
      final path = await FilePicker.saveFile(
        dialogTitle: labels.savePdfDialogTitle,
        fileName: filename,
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        bytes: bytes,
      );
      return path == null
          ? OrderDocumentActionStatus.canceled
          : OrderDocumentActionStatus.completed;
    }

    final shared = await Printing.sharePdf(
      bytes: bytes,
      filename: filename,
      subject: subject,
      bounds: bounds,
    );
    return shared
        ? OrderDocumentActionStatus.completed
        : OrderDocumentActionStatus.canceled;
  }

  bool get _shouldSaveWithDialog {
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => false,
    };
  }

  Future<Uint8List> _buildTestPdf() async {
    final fonts = await fontLoader.load();
    return _DocumentFrame(
      title: labels.testPrintTitle,
      reference: labels.testPrintReference,
      labels: labels,
      fonts: fonts,
      sections: [
        _DocumentSection(
          title: labels.summary,
          rows: [
            _DocumentField(labels.issueDate, _formatDateTime(DateTime.now())),
            _DocumentField(labels.total, _formatMoney(0), strong: true),
          ],
        ),
      ],
    ).build();
  }
}

class OrderDocumentLabels {
  const OrderDocumentLabels({
    required this.saleInvoiceTitle,
    required this.purchaseOrderTitle,
    required this.testPrintTitle,
    required this.testPrintReference,
    required this.savePdfDialogTitle,
    required this.summary,
    required this.items,
    required this.payments,
    required this.totals,
    required this.invoiceNumber,
    required this.purchaseOrderNumber,
    required this.supplierInvoiceNumber,
    required this.customer,
    required this.supplier,
    required this.registerSession,
    required this.status,
    required this.issueDate,
    required this.createdAt,
    required this.submittedAt,
    required this.receivedAt,
    required this.dueDate,
    required this.product,
    required this.quantity,
    required this.received,
    required this.unitPrice,
    required this.unitCost,
    required this.lineTotal,
    required this.paymentMethod,
    required this.amount,
    required this.subtotal,
    required this.discount,
    required this.landedCost,
    required this.total,
    required this.paid,
    required this.balanceDue,
    required this.unknownProduct,
    required this.walkInCustomer,
    required this.emptyValue,
    required this.page,
    required this.ofPages,
  });

  const OrderDocumentLabels.arabic()
    : saleInvoiceTitle = 'فاتورة بيع',
      purchaseOrderTitle = 'فاتورة مشتريات',
      testPrintTitle = 'اختبار طباعة الفواتير',
      testPrintReference = 'TEST',
      savePdfDialogTitle = 'حفظ ملف PDF',
      summary = 'الملخص',
      items = 'العناصر',
      payments = 'المدفوعات',
      totals = 'الإجماليات',
      invoiceNumber = 'رقم الفاتورة',
      purchaseOrderNumber = 'رقم أمر الشراء',
      supplierInvoiceNumber = 'رقم فاتورة المورد',
      customer = 'العميل',
      supplier = 'المورد',
      registerSession = 'جلسة الدرج',
      status = 'الحالة',
      issueDate = 'تاريخ الإصدار',
      createdAt = 'تاريخ الإنشاء',
      submittedAt = 'تاريخ الإرسال',
      receivedAt = 'تاريخ الاستلام',
      dueDate = 'تاريخ الاستحقاق',
      product = 'المنتج',
      quantity = 'الكمية',
      received = 'المستلم',
      unitPrice = 'سعر الوحدة',
      unitCost = 'تكلفة الوحدة',
      lineTotal = 'الإجمالي',
      paymentMethod = 'طريقة الدفع',
      amount = 'المبلغ',
      subtotal = 'المجموع الفرعي',
      discount = 'الخصم',
      landedCost = 'تكاليف الشحن والتوريد',
      total = 'الإجمالي',
      paid = 'المدفوع',
      balanceDue = 'المتبقي',
      unknownProduct = 'منتج غير معروف',
      walkInCustomer = 'عميل نقدي',
      emptyValue = '-',
      page = 'صفحة',
      ofPages = 'من';

  final String saleInvoiceTitle;
  final String purchaseOrderTitle;
  final String testPrintTitle;
  final String testPrintReference;
  final String savePdfDialogTitle;
  final String summary;
  final String items;
  final String payments;
  final String totals;
  final String invoiceNumber;
  final String purchaseOrderNumber;
  final String supplierInvoiceNumber;
  final String customer;
  final String supplier;
  final String registerSession;
  final String status;
  final String issueDate;
  final String createdAt;
  final String submittedAt;
  final String receivedAt;
  final String dueDate;
  final String product;
  final String quantity;
  final String received;
  final String unitPrice;
  final String unitCost;
  final String lineTotal;
  final String paymentMethod;
  final String amount;
  final String subtotal;
  final String discount;
  final String landedCost;
  final String total;
  final String paid;
  final String balanceDue;
  final String unknownProduct;
  final String walkInCustomer;
  final String emptyValue;
  final String page;
  final String ofPages;

  String paymentMethodLabel(PaymentMethod method) {
    return switch (method) {
      PaymentMethod.cash => 'نقدًا',
      PaymentMethod.card => 'بطاقة',
      PaymentMethod.transfer => 'تحويل',
    };
  }

  String saleStatus(String status) {
    return switch (status) {
      'paid' => 'مدفوعة',
      'void' || 'voided' => 'ملغاة',
      'open' => 'مفتوحة',
      _ => status.isEmpty ? emptyValue : status,
    };
  }

  String purchaseStatus(String status) {
    return switch (status) {
      'draft' => 'مسودة',
      'submitted' => 'مرسل',
      'partial' || 'partially_received' => 'مستلم جزئيًا',
      'received' => 'مستلم',
      'cancelled' || 'canceled' => 'ملغى',
      _ => status.isEmpty ? emptyValue : status,
    };
  }
}

class OrderDocumentFontLoader {
  const OrderDocumentFontLoader();

  Future<OrderDocumentFonts> load() async {
    final regular = await PdfGoogleFonts.notoNaskhArabicRegular();
    final bold = await PdfGoogleFonts.notoNaskhArabicBold();
    final cairo = await PdfGoogleFonts.cairoRegular();
    return OrderDocumentFonts(base: regular, bold: bold, fallback: [cairo]);
  }
}

class OrderDocumentFonts {
  const OrderDocumentFonts({
    required this.base,
    required this.bold,
    this.fallback = const [],
  });

  final pw.Font base;
  final pw.Font bold;
  final List<pw.Font> fallback;

  pw.ThemeData toThemeData() {
    return pw.ThemeData.withFont(
      base: base,
      bold: bold,
      fontFallback: fallback,
    );
  }
}

class _DocumentFrame {
  const _DocumentFrame({
    required this.title,
    required this.reference,
    required this.labels,
    required this.fonts,
    required this.sections,
    this.shopSettings,
  });

  final String title;
  final String reference;
  final ShopSettings? shopSettings;
  final OrderDocumentLabels labels;
  final OrderDocumentFonts fonts;
  final List<_DocumentSection> sections;

  Future<Uint8List> build() async {
    final pdf = pw.Document(
      title: '$title $reference',
      author: _shopName,
      creator: 'Pointy',
      subject: title,
    );

    pdf.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4.applyMargin(
            left: 16 * PdfPageFormat.mm,
            top: 14 * PdfPageFormat.mm,
            right: 16 * PdfPageFormat.mm,
            bottom: 14 * PdfPageFormat.mm,
          ),
          theme: fonts.toThemeData(),
          textDirection: pw.TextDirection.rtl,
        ),
        header: (_) => _header(),
        footer: (context) => _footer(context),
        build: (_) => [
          for (final section in sections) ...[
            section.build(labels),
            pw.SizedBox(height: 12),
          ],
          if (_footerText.isNotEmpty) ...[
            pw.SizedBox(height: 4),
            pw.Text(
              _footerText,
              style: const pw.TextStyle(fontSize: 9, color: _PdfColors.muted),
              textAlign: pw.TextAlign.center,
            ),
          ],
        ],
      ),
    );

    return pdf.save();
  }

  String get _shopName {
    final name = shopSettings?.shopName.trim() ?? '';
    return name.isEmpty ? 'Pointy' : name;
  }

  String get _headerText => shopSettings?.receiptHeader.trim() ?? '';

  String get _footerText => shopSettings?.receiptFooter.trim() ?? '';

  pw.Widget _header() {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 10),
      decoration: const pw.BoxDecoration(
        border: pw.Border(bottom: pw.BorderSide(color: _PdfColors.border)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      _shopName,
                      style: pw.TextStyle(
                        fontSize: 11,
                        color: _PdfColors.muted,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    if (_headerText.isNotEmpty) ...[
                      pw.SizedBox(height: 3),
                      pw.Text(
                        _headerText,
                        style: const pw.TextStyle(
                          fontSize: 9,
                          color: _PdfColors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              pw.SizedBox(width: 16),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    title,
                    style: pw.TextStyle(
                      fontSize: 18,
                      fontWeight: pw.FontWeight.bold,
                      color: _PdfColors.ink,
                    ),
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    reference,
                    style: const pw.TextStyle(
                      fontSize: 11,
                      color: _PdfColors.muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _footer(pw.Context context) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _PdfColors.border)),
      ),
      child: pw.Align(
        alignment: pw.Alignment.centerLeft,
        child: pw.Text(
          '${labels.page} ${context.pageNumber} ${labels.ofPages} ${context.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: _PdfColors.muted),
        ),
      ),
    );
  }
}

class _DocumentSection {
  const _DocumentSection({
    required this.title,
    this.rows = const [],
    this.table,
  });

  final String title;
  final List<_DocumentField> rows;
  final _DocumentTable? table;

  pw.Widget build(OrderDocumentLabels labels) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          title,
          style: pw.TextStyle(
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
            color: _PdfColors.ink,
          ),
        ),
        pw.SizedBox(height: 6),
        if (rows.isNotEmpty) _fieldGrid(rows),
        if (table != null) table!.build(labels),
      ],
    );
  }

  pw.Widget _fieldGrid(List<_DocumentField> rows) {
    return pw.Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final row in rows)
          pw.Container(
            width: 240,
            padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: pw.BoxDecoration(
              color: _PdfColors.fill,
              border: pw.Border.all(color: _PdfColors.border, width: 0.5),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(3)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  row.label,
                  style: const pw.TextStyle(
                    fontSize: 8,
                    color: _PdfColors.muted,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  row.value,
                  style: pw.TextStyle(
                    fontSize: 10,
                    color: _PdfColors.ink,
                    fontWeight: row.strong ? pw.FontWeight.bold : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _DocumentTable {
  const _DocumentTable({
    required this.columns,
    required this.rows,
    this.columnFlex = const [],
  });

  final List<String> columns;
  final List<List<String>> rows;
  final List<double> columnFlex;

  pw.Widget build(OrderDocumentLabels labels) {
    final widths = <int, pw.TableColumnWidth>{};
    for (var index = 0; index < columnFlex.length; index += 1) {
      widths[index] = pw.FlexColumnWidth(columnFlex[index]);
    }
    return pw.TableHelper.fromTextArray(
      headers: columns.map(_tableValue).toList(growable: false),
      data: rows.isEmpty
          ? [
              [labels.emptyValue, ...List.filled(columns.length - 1, '')],
            ]
          : [
              for (final row in rows)
                row.map(_tableValue).toList(growable: false),
            ],
      border: pw.TableBorder.all(color: _PdfColors.border, width: 0.5),
      headerDecoration: const pw.BoxDecoration(color: _PdfColors.fill),
      headerStyle: pw.TextStyle(
        color: _PdfColors.ink,
        fontSize: 9,
        fontWeight: pw.FontWeight.bold,
      ),
      cellStyle: const pw.TextStyle(color: _PdfColors.ink, fontSize: 9),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      headerPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      cellAlignment: pw.Alignment.centerRight,
      headerAlignment: pw.Alignment.centerRight,
      columnWidths: widths.isEmpty ? null : widths,
      tableDirection: pw.TextDirection.rtl,
      headerDirection: pw.TextDirection.rtl,
    );
  }

  String _tableValue(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 120) {
      return normalized.isEmpty ? '-' : normalized;
    }
    return '${normalized.substring(0, 117)}...';
  }
}

class _DocumentField {
  const _DocumentField(this.label, this.value, {this.strong = false});

  final String label;
  final String value;
  final bool strong;
}

class _PdfColors {
  static const ink = PdfColor.fromInt(0xff202124);
  static const muted = PdfColor.fromInt(0xff5f6368);
  static const border = PdfColor.fromInt(0xffdadce0);
  static const fill = PdfColor.fromInt(0xfff8f9fa);
}

String _saleReference(SaleOrder order) {
  final receiptNumber = order.receiptNumber?.trim() ?? '';
  return receiptNumber.isEmpty ? '${order.id}' : receiptNumber;
}

String _purchaseReference(PurchaseOrder order) {
  final orderNumber = order.orderNumber.trim();
  return orderNumber.isEmpty ? '${order.id}' : orderNumber;
}

String _saleLineName(SaleOrderLine line) {
  final product = line.productName?.trim() ?? '';
  final variant = line.variantName?.trim() ?? '';
  if (product.isEmpty && variant.isEmpty) {
    return '${line.productId}';
  }
  if (variant.isEmpty || variant == product) {
    return product;
  }
  if (product.isEmpty) {
    return variant;
  }
  return '$product - $variant';
}

String _formatMoney(double value) => '${value.toStringAsFixed(2)} د.ل';

String _formatDateTime(DateTime value) {
  return DateFormat('yyyy/MM/dd HH:mm').format(value.toLocal());
}

String _formatDate(DateTime value) {
  return DateFormat('yyyy/MM/dd').format(value.toLocal());
}

String _safeReference(String value) {
  final normalized = value
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return normalized.isEmpty ? 'document' : normalized;
}
