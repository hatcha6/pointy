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
import '../../shared/formatters.dart';
import '../../shared/pdf/pdf.dart';

export 'order_document_action.dart';

class OrderDocumentService {
  const OrderDocumentService({
    this.labels = const OrderDocumentLabels.arabic(),
    this.fontLoader = const PointyPdfFontLoader(),
    this.webDelivery = const OrderDocumentWebDelivery(),
  });

  final OrderDocumentLabels labels;
  final PointyPdfFontLoader fontLoader;
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
    Uint8List? shopLogoBytes,
    PrinterEndpoint? endpoint,
  }) {
    return _printPdf(
      bytesBuilder: () => buildSaleInvoiceBytes(
        order: order,
        shopSettings: shopSettings,
        shopLogoBytes: shopLogoBytes,
      ),
      jobName: saleInvoiceFileName(order),
      endpoint: endpoint,
    );
  }

  Future<bool> printPurchaseOrder({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    PrinterEndpoint? endpoint,
  }) {
    return _printPdf(
      bytesBuilder: () => buildPurchaseOrderBytes(
        order: order,
        shopSettings: shopSettings,
        shopLogoBytes: shopLogoBytes,
      ),
      jobName: purchaseOrderFileName(order),
      endpoint: endpoint,
    );
  }

  Future<bool> printProofOfPayment({
    required PaymentProof proof,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    PrinterEndpoint? endpoint,
  }) {
    return _printPdf(
      bytesBuilder: () => buildProofOfPaymentBytes(
        proof: proof,
        shopSettings: shopSettings,
        shopLogoBytes: shopLogoBytes,
      ),
      jobName: proofOfPaymentFileName(proof),
      endpoint: endpoint,
    );
  }

  Future<OrderDocumentActionStatus> shareSaleInvoice({
    required SaleOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    Rect? bounds,
  }) async {
    try {
      final bytes = await buildSaleInvoiceBytes(
        order: order,
        shopSettings: shopSettings,
        shopLogoBytes: shopLogoBytes,
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
    Uint8List? shopLogoBytes,
    Rect? bounds,
  }) async {
    try {
      final bytes = await buildPurchaseOrderBytes(
        order: order,
        shopSettings: shopSettings,
        shopLogoBytes: shopLogoBytes,
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
    Uint8List? shopLogoBytes,
  }) async {
    final fontData = await fontLoader.loadData();
    final template = saleInvoiceTemplate(
      order: order,
      shopSettings: shopSettings,
    );
    return _renderDocument(template, shopLogoBytes, fontData);
  }

  Future<Uint8List> buildPurchaseOrderBytes({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) async {
    final fontData = await fontLoader.loadData();
    final template = purchaseOrderTemplate(
      order: order,
      shopSettings: shopSettings,
    );
    return _renderDocument(template, shopLogoBytes, fontData);
  }

  Future<Uint8List> buildProofOfPaymentBytes({
    required PaymentProof proof,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) async {
    final fontData = await fontLoader.loadData();
    final template = proofOfPaymentTemplate(
      proof: proof,
      shopSettings: shopSettings,
    );
    return _renderDocument(template, shopLogoBytes, fontData);
  }

  /// Renders [template] to PDF bytes. On native platforms the heavy synchronous
  /// `pw.Document.save()` runs in a background isolate so a checkout (or a
  /// share/print) never blocks the UI thread; the web target has no isolates,
  /// so it renders inline.
  Future<Uint8List> _renderDocument(
    OrderDocumentTemplate template,
    Uint8List? logoBytes,
    PointyPdfFontData fontData,
  ) {
    final request = _OrderDocumentBuildRequest(
      template: template,
      logoBytes: logoBytes,
      labels: labels,
      fontData: fontData,
    );
    if (kIsWeb) {
      return _buildOrderDocumentBytes(request);
    }
    return compute(_buildOrderDocumentBytes, request);
  }

  OrderDocumentTemplate saleInvoiceTemplate({
    required SaleOrder order,
    ShopSettings? shopSettings,
  }) {
    final isQuotation = order.saleType == SaleType.quotation;
    final paidTotal = order.payments.fold<double>(
      0,
      (sum, payment) => sum + payment.amount,
    );
    final balanceDue = _balanceDue(total: order.total, paid: paidTotal);
    final statusText = _saleStatusText(order, paidTotal, balanceDue);
    return OrderDocumentTemplate(
      title: isQuotation ? labels.quotationTitle : labels.saleInvoiceTitle,
      reference: _saleReference(order),
      publicInvoiceUrl: _publicInvoiceUrl(order),
      shopName: _shopName(shopSettings),
      shopHeaderLines: _shopHeaderLines(shopSettings),
      recipientTitle: labels.billTo,
      recipientLines: _nonBlankStrings([
        order.customerName,
        order.customerNumber,
        order.customerPhone,
        order.customerEmail,
      ]),
      details: [
        if (order.createdAt != null)
          OrderDocumentField(labels.issueDate, formatPdfDate(order.createdAt!)),
        // A quotation is valid until its expiry, not a money status; a sale
        // shows its paid/partial/unpaid status. Either way the line is the
        // highlighted "what is this document" cue at the top of the details.
        if (isQuotation) ...[
          if (order.validUntil != null)
            OrderDocumentField(
              labels.quotationValidUntil,
              formatPdfDate(order.validUntil!),
              strong: true,
              highlight: true,
            ),
          OrderDocumentField(
            labels.paymentStatusLabel,
            labels.paymentStatusQuotation,
            strong: true,
            highlight: true,
          ),
        ] else ...[
          OrderDocumentField(
            labels.paymentStatusLabel,
            statusText,
            strong: true,
            highlight: true,
          ),
          // Keep the explicit balance-due row for credit/partial sales.
          if (balanceDue > 0)
            OrderDocumentField(
              labels.balanceDue,
              _formatMoney(balanceDue),
              strong: true,
              highlight: true,
            ),
        ],
      ],
      itemsTable: OrderDocumentTable(
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
              _formatQuantityWithUnit(line.quantity, line.unitLabel),
              _formatMoney(line.unitPrice),
              _formatMoney(line.total),
            ],
        ],
        columnFlex: const [2.8, 0.9, 1.1, 1.1],
      ),
      totals: [
        OrderDocumentField(labels.subtotal, _formatMoney(order.subtotal)),
        if (order.discountTotal > 0)
          OrderDocumentField(
            labels.discount,
            _formatMoney(order.discountTotal),
          ),
        OrderDocumentField(
          labels.total,
          _formatMoney(order.total),
          strong: true,
        ),
        // A quote owes nothing, so it carries no paid/balance money framing.
        if (!isQuotation && paidTotal > 0)
          OrderDocumentField(labels.paid, _formatMoney(paidTotal)),
        if (!isQuotation && balanceDue > 0)
          OrderDocumentField(labels.balanceDue, _formatMoney(balanceDue)),
      ],
      // A quotation reminds the reader it is not a tax/sale invoice.
      terms: isQuotation ? labels.quotationNotice : null,
      notes: _shopFooterNote(shopSettings),
    );
  }

  /// Resolves the printed status text for a sale. Prefers the server's
  /// `payment_status`; falls back to deriving it from the paid/balance figures
  /// for older payloads that omit it.
  String _saleStatusText(SaleOrder order, double paidTotal, double balanceDue) {
    final serverStatus = order.paymentStatus.trim();
    if (serverStatus.isNotEmpty) {
      return labels.paymentStatusText(serverStatus);
    }
    if (balanceDue <= 0 && order.total > 0) {
      return labels.paymentStatusPaid;
    }
    if (paidTotal > 0) {
      return labels.paymentStatusPartial;
    }
    return labels.paymentStatusUnpaid;
  }

  OrderDocumentTemplate purchaseOrderTemplate({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
  }) {
    return OrderDocumentTemplate(
      title: labels.purchaseOrderTitle,
      reference: _purchaseReference(order),
      shopName: _shopName(shopSettings),
      shopHeaderLines: _shopHeaderLines(shopSettings),
      recipientTitle: labels.billFrom,
      recipientLines: _nonBlankStrings([
        order.supplierName,
        order.supplierContactName,
        order.supplierPhone,
        order.supplierEmail,
        order.supplierAddress,
      ]),
      details: [
        if (order.createdAt != null)
          OrderDocumentField(labels.issueDate, formatPdfDate(order.createdAt!)),
        if (order.supplierInvoiceDate != null)
          OrderDocumentField(
            labels.supplierInvoiceDate,
            formatPdfDate(order.supplierInvoiceDate!),
          ),
        if (order.supplierInvoiceNumber.trim().isNotEmpty)
          OrderDocumentField(
            labels.supplierInvoiceNumber,
            order.supplierInvoiceNumber.trim(),
          ),
        if (order.dueDate != null)
          OrderDocumentField(labels.dueDate, formatPdfDate(order.dueDate!)),
        if (order.balanceDue > 0)
          OrderDocumentField(
            labels.balanceDue,
            _formatMoney(order.balanceDue),
            strong: true,
            highlight: true,
          ),
      ],
      itemsTable: OrderDocumentTable(
        columns: [
          labels.product,
          labels.quantity,
          labels.unitCost,
          labels.lineTotal,
        ],
        rows: [
          for (final line in order.lines)
            [
              line.displayName.trim().isEmpty
                  ? labels.unknownProduct
                  : line.displayName.trim(),
              _formatQuantityWithUnit(line.quantity.toDouble(), line.unitLabel),
              _formatMoney(line.effectiveUnitCost ?? line.unitCost),
              _formatMoney(line.landedLineTotal ?? line.total),
            ],
        ],
        columnFlex: const [2.8, 0.9, 1.1, 1.1],
      ),
      totals: [
        OrderDocumentField(labels.subtotal, _formatMoney(order.subtotal)),
        if (order.discountTotal > 0)
          OrderDocumentField(
            labels.discount,
            _formatMoney(order.discountTotal),
          ),
        if (order.landedCostTotal > 0)
          OrderDocumentField(
            labels.landedCost,
            _formatMoney(order.landedCostTotal),
          ),
        OrderDocumentField(
          labels.total,
          _formatMoney(order.total),
          strong: true,
        ),
        if (order.paidTotal > 0)
          OrderDocumentField(labels.paid, _formatMoney(order.paidTotal)),
      ],
      notes: _shopFooterNote(shopSettings),
    );
  }

  /// A standalone proof-of-payment slip for a single payment: a "سند قبض"
  /// (money in, from a customer) or "سند صرف" (money out, to a supplier).
  /// Reuses the invoice document frame but carries no line-items table — the
  /// payment particulars render as field rows in the totals block.
  OrderDocumentTemplate proofOfPaymentTemplate({
    required PaymentProof proof,
    ShopSettings? shopSettings,
  }) {
    final isReceipt = proof.kind == PaymentProofKind.receipt;
    return OrderDocumentTemplate(
      title: isReceipt
          ? labels.proofOfReceiptTitle
          : labels.proofOfPaymentTitle,
      reference: proof.reference.trim().isEmpty
          ? labels.emptyValue
          : proof.reference.trim(),
      shopName: _shopName(shopSettings),
      shopHeaderLines: _shopHeaderLines(shopSettings),
      recipientTitle: isReceipt ? labels.proofReceivedFrom : labels.proofPaidTo,
      recipientLines: _nonBlankStrings([proof.partyName, proof.partyContact]),
      details: [
        OrderDocumentField(
          labels.issueDate,
          formatPdfDate(proof.createdAt ?? DateTime.now()),
        ),
        if ((proof.relatedDocumentNumber?.trim().isNotEmpty ?? false))
          OrderDocumentField(
            isReceipt
                ? labels.proofRelatedInvoice
                : labels.proofRelatedPurchaseOrder,
            proof.relatedDocumentNumber!.trim(),
          ),
      ],
      // Payment particulars render through the shared styled table (the same
      // PointyPdfTable the invoice line-items use), so the proof matches the
      // rest of our documents rather than a bespoke layout.
      itemsTable: OrderDocumentTable(
        columns: [labels.proofParticular, labels.proofParticularValue],
        rows: [
          [labels.paymentMethod, proof.method],
          if (proof.commissionAmount != null && proof.commissionAmount! > 0)
            [labels.proofCommission, _formatMoney(proof.commissionAmount!)],
          if (proof.externalReference?.trim().isNotEmpty ?? false)
            [labels.proofReference, proof.externalReference!.trim()],
          if (proof.handledBy?.trim().isNotEmpty ?? false)
            [
              isReceipt ? labels.proofCollectedBy : labels.proofPaidBy,
              proof.handledBy!.trim(),
            ],
        ],
        columnFlex: const [1.4, 2.0],
      ),
      totals: [
        OrderDocumentField(
          labels.proofAmount,
          _formatMoney(proof.amount),
          strong: true,
          highlight: true,
        ),
        if (proof.balanceAfter != null)
          OrderDocumentField(
            labels.proofBalanceAfter,
            _formatMoney(proof.balanceAfter!),
            strong: true,
          ),
      ],
      notes: _shopFooterNote(shopSettings),
    );
  }

  String saleInvoiceFileName(SaleOrder order) {
    return 'فاتورة-بيع-${_safeReference(_saleReference(order))}.pdf';
  }

  String purchaseOrderFileName(PurchaseOrder order) {
    return 'فاتورة-مشتريات-${_safeReference(_purchaseReference(order))}.pdf';
  }

  String proofOfPaymentFileName(PaymentProof proof) {
    final prefix = proof.kind == PaymentProofKind.receipt
        ? 'سند-قبض'
        : 'سند-صرف';
    return '$prefix-${_safeReference(proof.reference)}.pdf';
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
      template: OrderDocumentTemplate(
        title: labels.testPrintTitle,
        reference: labels.testPrintReference,
        shopName: _shopName(null),
        shopHeaderLines: const [],
        recipientTitle: labels.billTo,
        recipientLines: const [],
        details: [
          OrderDocumentField(labels.issueDate, _formatDateTime(DateTime.now())),
        ],
        itemsTable: OrderDocumentTable(
          columns: [
            labels.product,
            labels.quantity,
            labels.unitPrice,
            labels.lineTotal,
          ],
          rows: const [],
          columnFlex: const [2.8, 0.8, 1.1, 1.1],
        ),
        totals: [
          OrderDocumentField(labels.total, _formatMoney(0), strong: true),
        ],
      ),
      labels: labels,
      fonts: fonts,
    ).build();
  }
}

/// Sendable bundle for [_buildOrderDocumentBytes] so PDF rendering can run in a
/// background isolate. Every field is plain data (the template and labels) or
/// raw bytes (the logo and font data) — no pdf widgets or closures cross over.
class _OrderDocumentBuildRequest {
  const _OrderDocumentBuildRequest({
    required this.template,
    required this.logoBytes,
    required this.labels,
    required this.fontData,
  });

  final OrderDocumentTemplate template;
  final Uint8List? logoBytes;
  final OrderDocumentLabels labels;
  final PointyPdfFontData fontData;
}

/// Top-level so it can serve as an isolate entry point: parses the font bytes
/// and performs the heavy synchronous PDF encoding.
Future<Uint8List> _buildOrderDocumentBytes(_OrderDocumentBuildRequest request) {
  return _DocumentFrame(
    template: request.template,
    shopLogoBytes: request.logoBytes,
    labels: request.labels,
    fonts: request.fontData.toFonts(),
  ).build();
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
    required this.supplierInvoiceDate,
    required this.billTo,
    required this.billFrom,
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
    required this.notes,
    required this.terms,
    required this.unknownProduct,
    required this.walkInCustomer,
    required this.emptyValue,
    required this.page,
    required this.ofPages,
    required this.onlineInvoice,
    required this.scanOnlineInvoice,
    required this.paymentStatusLabel,
    required this.paymentStatusPaid,
    required this.paymentStatusPartial,
    required this.paymentStatusUnpaid,
    required this.paymentStatusQuotation,
    required this.quotationTitle,
    required this.quotationValidUntil,
    required this.quotationNotice,
    required this.proofOfReceiptTitle,
    required this.proofOfPaymentTitle,
    required this.proofReceivedFrom,
    required this.proofPaidTo,
    required this.proofRelatedInvoice,
    required this.proofRelatedPurchaseOrder,
    required this.proofAmount,
    required this.proofCommission,
    required this.proofReference,
    required this.proofParticular,
    required this.proofParticularValue,
    required this.proofCollectedBy,
    required this.proofPaidBy,
    required this.proofBalanceAfter,
  });

  const OrderDocumentLabels.arabic()
    : saleInvoiceTitle = 'فاتورة بيع',
      purchaseOrderTitle = 'فاتورة مشتريات',
      testPrintTitle = 'اختبار طباعة الفواتير',
      testPrintReference = 'اختبار',
      savePdfDialogTitle = 'حفظ ملف PDF',
      summary = 'الملخص',
      items = 'العناصر',
      payments = 'المدفوعات',
      totals = 'الإجماليات',
      invoiceNumber = 'رقم الفاتورة',
      purchaseOrderNumber = 'رقم أمر الشراء',
      supplierInvoiceNumber = 'رقم فاتورة المورد',
      supplierInvoiceDate = 'تاريخ فاتورة المورد',
      billTo = 'فاتورة إلى:',
      billFrom = 'فاتورة من:',
      customer = 'العميل',
      supplier = 'المورد',
      registerSession = 'جلسة الدرج',
      status = 'الحالة',
      issueDate = 'تاريخ الإصدار',
      createdAt = 'تاريخ الإنشاء',
      submittedAt = 'تاريخ الإرسال',
      receivedAt = 'تاريخ الاستلام',
      dueDate = 'تاريخ الاستحقاق',
      product = 'الصنف',
      quantity = 'الكمية',
      received = 'المستلم',
      unitPrice = 'السعر',
      unitCost = 'السعر',
      lineTotal = 'الإجمالي',
      paymentMethod = 'طريقة الدفع',
      amount = 'المبلغ',
      subtotal = 'المجموع الفرعي',
      discount = 'الخصم',
      landedCost = 'تكاليف الشحن والتوريد',
      total = 'الإجمالي',
      paid = 'المدفوع',
      balanceDue = 'المتبقي',
      notes = 'ملاحظات',
      terms = 'الشروط',
      unknownProduct = 'منتج غير معروف',
      walkInCustomer = 'عميل نقدي',
      emptyValue = '-',
      page = 'صفحة',
      ofPages = 'من',
      onlineInvoice = 'الفاتورة عبر الإنترنت',
      scanOnlineInvoice = 'امسح الرمز لعرض الفاتورة',
      paymentStatusLabel = 'حالة الدفع',
      paymentStatusPaid = 'مدفوعة بالكامل',
      paymentStatusPartial = 'مدفوعة جزئيًا',
      paymentStatusUnpaid = 'آجل — غير مدفوعة',
      paymentStatusQuotation = 'عرض سعر',
      quotationTitle = 'فاتورة عرض',
      quotationValidUntil = 'صالح حتى',
      quotationNotice =
          'هذا عرض سعر وليس فاتورة بيع أو فاتورة ضريبية، ولا يُلزم بأي دفع.',
      proofOfReceiptTitle = 'سند قبض',
      proofOfPaymentTitle = 'سند صرف',
      proofReceivedFrom = 'استلمنا من',
      proofPaidTo = 'صرفنا إلى',
      proofRelatedInvoice = 'بخصوص الفاتورة',
      proofRelatedPurchaseOrder = 'بخصوص أمر الشراء',
      proofAmount = 'المبلغ',
      proofCommission = 'العمولة',
      proofReference = 'المرجع',
      proofParticular = 'البيان',
      proofParticularValue = 'التفاصيل',
      proofCollectedBy = 'حصّلها',
      proofPaidBy = 'صرفها',
      proofBalanceAfter = 'الرصيد بعد الدفع';

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
  final String supplierInvoiceDate;
  final String billTo;
  final String billFrom;
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
  final String notes;
  final String terms;
  final String unknownProduct;
  final String walkInCustomer;
  final String emptyValue;
  final String page;
  final String ofPages;
  final String onlineInvoice;
  final String scanOnlineInvoice;
  final String paymentStatusLabel;
  final String paymentStatusPaid;
  final String paymentStatusPartial;
  final String paymentStatusUnpaid;
  final String paymentStatusQuotation;
  final String quotationTitle;
  final String quotationValidUntil;
  final String quotationNotice;
  final String proofOfReceiptTitle;
  final String proofOfPaymentTitle;
  final String proofReceivedFrom;
  final String proofPaidTo;
  final String proofRelatedInvoice;
  final String proofRelatedPurchaseOrder;
  final String proofAmount;
  final String proofCommission;
  final String proofReference;
  final String proofParticular;
  final String proofParticularValue;
  final String proofCollectedBy;
  final String proofPaidBy;
  final String proofBalanceAfter;

  /// Localized money-status line for a printed sale, keyed on the server's
  /// `payment_status` (`paid` | `partial` | `unpaid` | `quotation`).
  String paymentStatusText(String paymentStatus) {
    return switch (paymentStatus) {
      'paid' => paymentStatusPaid,
      'partial' => paymentStatusPartial,
      'unpaid' => paymentStatusUnpaid,
      'quotation' => paymentStatusQuotation,
      _ => emptyValue,
    };
  }

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

@immutable
class OrderDocumentTemplate {
  const OrderDocumentTemplate({
    required this.title,
    required this.reference,
    required this.shopName,
    required this.shopHeaderLines,
    required this.recipientTitle,
    required this.recipientLines,
    required this.details,
    required this.totals,
    this.itemsTable,
    this.notes,
    this.terms,
    this.publicInvoiceUrl,
  });

  final String title;
  final String reference;
  final String shopName;
  final List<String> shopHeaderLines;
  final String recipientTitle;
  final List<String> recipientLines;
  final List<OrderDocumentField> details;

  /// Line-items table. Null for documents with no line items (e.g. a
  /// proof-of-payment slip), in which case the frame omits the table entirely.
  final OrderDocumentTable? itemsTable;
  final List<OrderDocumentField> totals;
  final String? notes;
  final String? terms;
  final String? publicInvoiceUrl;
}

class _DocumentFrame {
  const _DocumentFrame({
    required this.template,
    required this.labels,
    required this.fonts,
    this.shopLogoBytes,
  });

  final OrderDocumentTemplate template;
  final Uint8List? shopLogoBytes;
  final OrderDocumentLabels labels;
  final PointyPdfFonts fonts;

  Future<Uint8List> build() async {
    final pdf = pw.Document(
      title: '${template.title} ${template.reference}',
      author: template.shopName,
      creator: 'دفتر',
      subject: template.title,
    );

    pdf.addPage(
      buildPointyPdfMultiPage(
        fonts: fonts,
        footer: _footer,
        build: (_) => [
          _hero(),
          pw.SizedBox(height: 32),
          _documentParties(),
          pw.SizedBox(height: 24),
          if (template.itemsTable != null) ...[
            template.itemsTable!.build(labels),
            pw.SizedBox(height: 24),
          ],
          _bottomSection(),
        ],
      ),
    );

    return pdf.save();
  }

  pw.Widget _hero() {
    return pw.Directionality(
      textDirection: pw.TextDirection.ltr,
      child: PointyPdfMasthead(
        leading: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              template.title,
              style: pw.TextStyle(
                fontSize: 32,
                fontWeight: pw.FontWeight.bold,
                color: PointyPdfPalette.ink,
              ),
              textDirection: pw.TextDirection.rtl,
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              '# ${template.reference}',
              style: const pw.TextStyle(
                fontSize: 14,
                color: PointyPdfPalette.muted,
              ),
              textDirection: pw.TextDirection.ltr,
            ),
          ],
        ),
        trailing: _heroSide(pdfLogoProvider(shopLogoBytes)),
      ),
    );
  }

  pw.Widget? _heroSide(pw.ImageProvider? logoProvider) {
    final children = <pw.Widget>[];
    if (logoProvider != null) {
      children.add(
        pw.Container(
          width: 84,
          height: 52,
          alignment: pw.Alignment.topRight,
          child: pw.Image(logoProvider, fit: pw.BoxFit.contain),
        ),
      );
    }
    final url = template.publicInvoiceUrl?.trim() ?? '';
    if (url.isNotEmpty) {
      if (children.isNotEmpty) {
        children.add(pw.SizedBox(width: 14));
      }
      children.add(_onlineInvoiceQr(url));
    }
    if (children.isEmpty) {
      return null;
    }
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: children,
    );
  }

  pw.Widget _onlineInvoiceQr(String url) {
    return pw.Container(
      width: 100,
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PointyPdfPalette.border),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            labels.onlineInvoice,
            style: pw.TextStyle(
              fontSize: 9,
              color: PointyPdfPalette.ink,
              fontWeight: pw.FontWeight.bold,
            ),
            textAlign: pw.TextAlign.center,
            textDirection: pw.TextDirection.rtl,
          ),
          pw.SizedBox(height: 4),
          pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(),
            data: url,
            width: 58,
            height: 58,
            drawText: false,
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            labels.scanOnlineInvoice,
            style: const pw.TextStyle(
              fontSize: 7,
              color: PointyPdfPalette.muted,
            ),
            textAlign: pw.TextAlign.center,
            textDirection: pw.TextDirection.rtl,
          ),
        ],
      ),
    );
  }

  pw.Widget _documentParties() {
    return pw.Directionality(
      textDirection: pw.TextDirection.ltr,
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.SizedBox(width: 220, child: _detailRows(template.details)),
          pw.SizedBox(
            width: 250,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  template.shopName,
                  style: pw.TextStyle(
                    fontSize: 14,
                    color: PointyPdfPalette.ink,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  textDirection: pw.TextDirection.rtl,
                ),
                pw.SizedBox(height: 4),
                for (final line in template.shopHeaderLines) ...[
                  pw.Text(
                    line,
                    style: const pw.TextStyle(
                      fontSize: 11,
                      color: PointyPdfPalette.ink,
                    ),
                    textDirection: pw.TextDirection.rtl,
                  ),
                  pw.SizedBox(height: 2),
                ],
                if (template.recipientLines.isNotEmpty) ...[
                  pw.SizedBox(height: 24),
                  pw.Text(
                    template.recipientTitle,
                    style: const pw.TextStyle(
                      fontSize: 11,
                      color: PointyPdfPalette.ink,
                    ),
                    textDirection: pw.TextDirection.rtl,
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    template.recipientLines.first,
                    style: pw.TextStyle(
                      fontSize: 12,
                      color: PointyPdfPalette.ink,
                      fontWeight: pw.FontWeight.bold,
                    ),
                    textDirection: pw.TextDirection.rtl,
                  ),
                  pw.SizedBox(height: 4),
                  for (final line in template.recipientLines.skip(1)) ...[
                    pw.Text(
                      line,
                      style: const pw.TextStyle(
                        fontSize: 11,
                        color: PointyPdfPalette.ink,
                      ),
                      textDirection: pw.TextDirection.rtl,
                    ),
                    pw.SizedBox(height: 2),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _detailRows(List<OrderDocumentField> rows) {
    if (rows.isEmpty) {
      return pw.SizedBox();
    }
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 8),
            child: PointyPdfFieldRow(
              label: row.label,
              value: row.value,
              strong: row.strong,
              highlighted: row.highlight,
            ),
          ),
      ],
    );
  }

  pw.Widget _bottomSection() {
    // Notes (the shop footer message) now live in the page footer; the body
    // bottom section is the optional terms block beside the totals.
    return pw.Directionality(
      textDirection: pw.TextDirection.rtl,
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: _termsBlock()),
          pw.SizedBox(width: 24),
          pw.SizedBox(
            width: 250,
            child: pw.Column(
              children: [
                for (final row in template.totals)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 10),
                    child: PointyPdfFieldRow(
                      label: row.label,
                      value: row.value,
                      strong: row.strong,
                      highlighted: row.highlight,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _termsBlock() {
    final terms = template.terms;
    if (terms == null) {
      return pw.SizedBox();
    }
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          '${labels.terms}:',
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11),
        ),
        pw.SizedBox(height: 4),
        pw.Text(terms, style: const pw.TextStyle(fontSize: 11)),
      ],
    );
  }

  pw.Widget _footer(pw.Context context) {
    return PointyPdfFooter(
      pageLabel:
          '${labels.page} ${context.pageNumber} ${labels.ofPages} ${context.pagesCount}',
      shopFooter: compactPdfText(template.notes, maxCharacters: 150),
    );
  }
}

class OrderDocumentTable {
  const OrderDocumentTable({
    required this.columns,
    required this.rows,
    this.columnFlex = const [],
  });

  final List<String> columns;
  final List<List<String>> rows;
  final List<double> columnFlex;

  pw.Widget build(OrderDocumentLabels labels) {
    return PointyPdfTable.invoice(
      columns: columns,
      rows: rows,
      columnFlex: columnFlex,
      emptyValue: labels.emptyValue,
      valueFormatter: _tableValue,
    ).build();
  }

  String _tableValue(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 120) {
      return normalized.isEmpty ? '-' : normalized;
    }
    return '${normalized.substring(0, 117)}...';
  }
}

class OrderDocumentField {
  const OrderDocumentField(
    this.label,
    this.value, {
    this.strong = false,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool strong;
  final bool highlight;
}

/// Whether a payment proof records money coming in (a customer paying us — a
/// "سند قبض" receipt) or money going out (us paying a supplier — a "سند صرف"
/// disbursement). Drives the title, the party label, and the audit kind.
enum PaymentProofKind { receipt, disbursement }

/// Plain, isolate-sendable description of a single payment for the standalone
/// proof-of-payment slip (سند قبض / سند صرف). Every field is a primitive so the
/// document can render in a background isolate like the invoice/PO templates.
@immutable
class PaymentProof {
  const PaymentProof({
    required this.kind,
    required this.reference,
    required this.partyName,
    required this.amount,
    required this.method,
    this.partyContact,
    this.relatedDocumentNumber,
    this.commissionAmount,
    this.externalReference,
    this.handledBy,
    this.balanceAfter,
    this.createdAt,
  });

  final PaymentProofKind kind;

  /// Human-facing slip number/reference shown next to the title (e.g. the
  /// payment id or invoice/PO number).
  final String reference;

  /// Customer (receipt) or supplier (disbursement) name.
  final String partyName;

  /// Optional party contact line (number/phone) under the name.
  final String? partyContact;

  /// Invoice or purchase-order number this payment settles, if any.
  final String? relatedDocumentNumber;

  final double amount;

  /// Localized payment-method label (resolved by the caller, which has the
  /// l10n context the isolate does not).
  final String method;

  /// Card/transfer commission, when charged.
  final double? commissionAmount;

  /// Free-text reference captured at payment time (RRN, transfer note, …).
  final String? externalReference;

  /// Who collected (receipt) or disbursed (disbursement) the money.
  final String? handledBy;

  /// The party's running balance after this payment.
  final double? balanceAfter;

  final DateTime? createdAt;
}

String _saleReference(SaleOrder order) {
  final receiptNumber = order.receiptNumber?.trim() ?? '';
  return receiptNumber.isEmpty ? '${order.id}' : receiptNumber;
}

String? _publicInvoiceUrl(SaleOrder order) {
  final url = order.publicInvoiceUrl.trim();
  return url.isEmpty ? null : url;
}

String _purchaseReference(PurchaseOrder order) {
  final orderNumber = order.orderNumber.trim();
  return orderNumber.isEmpty ? '${order.id}' : orderNumber;
}

String _shopName(ShopSettings? settings) {
  final name = settings?.shopName.trim() ?? '';
  return name.isEmpty ? 'نقطة البيع' : name;
}

List<String> _shopHeaderLines(ShopSettings? settings) {
  final header = settings?.receiptHeader.trim() ?? '';
  if (header.isEmpty) {
    return const [];
  }
  return _nonBlankStrings(header.split(RegExp(r'\r?\n')));
}

String? _shopFooterNote(ShopSettings? settings) {
  final footer = settings?.receiptFooter.trim() ?? '';
  return footer.isEmpty ? null : footer;
}

double _balanceDue({required double total, required double paid}) {
  final due = total - paid;
  return due <= 0 ? 0 : due;
}

List<String> _nonBlankStrings(Iterable<Object?> values) {
  final lines = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final normalized = value?.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized == null || normalized.isEmpty || !seen.add(normalized)) {
      continue;
    }
    lines.add(normalized);
  }
  return List.unmodifiable(lines);
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

String _formatMoney(double value) =>
    '${value.toStringAsFixed(2)} $currencySymbol';

/// Whole quantities render bare ("2"); fractional keep up to three places with
/// trailing zeros trimmed ("1.5"), so the invoice never shows "2.0".
String _formatQuantity(num value) {
  final quantity = value.toDouble();
  if (quantity == quantity.roundToDouble()) {
    return quantity.toInt().toString();
  }
  return quantity
      .toStringAsFixed(3)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// "2 صندوق" — the quantity with its unit label appended for invoice/PO rows.
String _formatQuantityWithUnit(num value, String unitLabel) {
  final quantity = _formatQuantity(value);
  final unit = unitLabel.trim();
  return unit.isEmpty ? quantity : '$quantity $unit';
}

String _formatDateTime(DateTime value) {
  return DateFormat('yyyy/MM/dd HH:mm').format(value.toLocal());
}

String _safeReference(String value) {
  final buffer = StringBuffer();
  var lastWasSeparator = false;
  for (final rune in value.runes) {
    final isAsciiLetter =
        (rune >= 65 && rune <= 90) || (rune >= 97 && rune <= 122);
    final isDigit = rune >= 48 && rune <= 57;
    final isArabic = rune >= 0x0600 && rune <= 0x06ff;
    final isSafePunctuation = rune == 45 || rune == 46 || rune == 95;
    if (isAsciiLetter || isDigit || isArabic || isSafePunctuation) {
      buffer.write(String.fromCharCode(rune));
      lastWasSeparator = false;
      continue;
    }
    if (!lastWasSeparator && buffer.isNotEmpty) {
      buffer.write('-');
      lastWasSeparator = true;
    }
  }
  final normalized = buffer
      .toString()
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  return normalized.isEmpty ? 'مستند' : normalized;
}
