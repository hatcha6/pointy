import 'dart:math' as math;
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
import 'cups_pdf_spooler_stub.dart'
    if (dart.library.io) 'cups_pdf_spooler_io.dart';
import 'order_document_action.dart';
import 'order_document_web_delivery.dart';
import 'print_transport.dart';
import 'receipt_integration_rows.dart';
import '../../shared/branding_assets.dart';
import '../../shared/date_formatters.dart';
import '../../shared/formatters.dart';
import '../../shared/pdf/pdf.dart';

export 'order_document_action.dart';

class OrderDocumentService {
  const OrderDocumentService({
    this.labels = const OrderDocumentLabels.arabic(),
    this.fontLoader = const PointyPdfFontLoader(),
    this.brandLogoLoader = const PointyBrandLogoLoader(),
    this.webDelivery = const OrderDocumentWebDelivery(),
  });

  final OrderDocumentLabels labels;
  final PointyPdfFontLoader fontLoader;
  final PointyBrandLogoLoader brandLogoLoader;
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
        renderBuilder: () => _buildTestPdf(
          pageSize: endpoint.pdfPageSize,
          compact: endpoint.compactReceipt,
        ),
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
    final pageSize = endpoint?.pdfPageSize ?? PdfPageSize.a4;
    return _printPdf(
      renderBuilder: () => buildSaleInvoiceRender(
        order: order,
        shopSettings: shopSettings,
        shopLogoBytes: shopLogoBytes,
        pageSize: pageSize,
        compact: endpoint?.compactReceipt ?? false,
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
    final pageSize = endpoint?.pdfPageSize ?? PdfPageSize.a4;
    return _printPdf(
      renderBuilder: () => buildPurchaseOrderRender(
        order: order,
        shopSettings: shopSettings,
        shopLogoBytes: shopLogoBytes,
        pageSize: pageSize,
        compact: endpoint?.compactReceipt ?? false,
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
    final pageSize = endpoint?.pdfPageSize ?? PdfPageSize.a4;
    return _printPdf(
      renderBuilder: () => buildProofOfPaymentRender(
        proof: proof,
        shopSettings: shopSettings,
        shopLogoBytes: shopLogoBytes,
        pageSize: pageSize,
        compact: endpoint?.compactReceipt ?? false,
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
    PdfPageSize pageSize = PdfPageSize.a4,
    bool compact = false,
  }) async {
    final render = await buildSaleInvoiceRender(
      order: order,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
      pageSize: pageSize,
      compact: compact,
    );
    return render.bytes;
  }

  Future<OrderDocumentRender> buildSaleInvoiceRender({
    required SaleOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    PdfPageSize pageSize = PdfPageSize.a4,
    bool compact = false,
  }) async {
    final fontData = await fontLoader.loadData();
    final brandLogoBytes = await brandLogoLoader.load();
    final template = saleInvoiceTemplate(
      order: order,
      shopSettings: shopSettings,
    );
    return _renderDocument(
      template,
      shopLogoBytes,
      fontData,
      pageSize,
      compact: compact,
      brandLogoBytes: brandLogoBytes,
    );
  }

  Future<Uint8List> buildPurchaseOrderBytes({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    PdfPageSize pageSize = PdfPageSize.a4,
    bool compact = false,
  }) async {
    final render = await buildPurchaseOrderRender(
      order: order,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
      pageSize: pageSize,
      compact: compact,
    );
    return render.bytes;
  }

  Future<OrderDocumentRender> buildPurchaseOrderRender({
    required PurchaseOrder order,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    PdfPageSize pageSize = PdfPageSize.a4,
    bool compact = false,
  }) async {
    final fontData = await fontLoader.loadData();
    final brandLogoBytes = await brandLogoLoader.load();
    final template = purchaseOrderTemplate(
      order: order,
      shopSettings: shopSettings,
    );
    return _renderDocument(
      template,
      shopLogoBytes,
      fontData,
      pageSize,
      compact: compact,
      brandLogoBytes: brandLogoBytes,
    );
  }

  Future<Uint8List> buildProofOfPaymentBytes({
    required PaymentProof proof,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    PdfPageSize pageSize = PdfPageSize.a4,
    bool compact = false,
  }) async {
    final render = await buildProofOfPaymentRender(
      proof: proof,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
      pageSize: pageSize,
      compact: compact,
    );
    return render.bytes;
  }

  Future<OrderDocumentRender> buildProofOfPaymentRender({
    required PaymentProof proof,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    PdfPageSize pageSize = PdfPageSize.a4,
    bool compact = false,
  }) async {
    final fontData = await fontLoader.loadData();
    final brandLogoBytes = await brandLogoLoader.load();
    final template = proofOfPaymentTemplate(
      proof: proof,
      shopSettings: shopSettings,
    );
    return _renderDocument(
      template,
      shopLogoBytes,
      fontData,
      pageSize,
      compact: compact,
      brandLogoBytes: brandLogoBytes,
    );
  }

  /// Renders [template] to PDF bytes. On native platforms the heavy synchronous
  /// `pw.Document.save()` runs in a background isolate so a checkout (or a
  /// share/print) never blocks the UI thread; the web target has no isolates,
  /// so it renders inline. [pageSize] picks the full A4 document or a compact
  /// receipt-width roll.
  Future<OrderDocumentRender> _renderDocument(
    OrderDocumentTemplate template,
    Uint8List? logoBytes,
    PointyPdfFontData fontData,
    PdfPageSize pageSize, {
    bool compact = false,
    Uint8List? brandLogoBytes,
  }) {
    final request = _OrderDocumentBuildRequest(
      template: template,
      logoBytes: logoBytes,
      labels: labels,
      fontData: fontData,
      pageSize: pageSize,
      compact: compact,
      brandLogoBytes: brandLogoBytes,
    );
    if (kIsWeb) {
      return _buildOrderDocumentRender(request);
    }
    return compute(_buildOrderDocumentRender, request);
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
          // Date + time: cashiers reconcile receipts by the minute they were
          // issued, so the sale invoice carries HH:mm, not just the day. (The
          // thermal ESC/POS path already prints the time.)
          OrderDocumentField(
            labels.issueDate,
            formatPdfDateTime(order.createdAt!),
          ),
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
        // Who rang it up and on which drawer: the line that turns a printed
        // copy back into a person and a shift without opening the Z-Report.
        if ((order.cashierName ?? '').trim().isNotEmpty)
          OrderDocumentField(labels.cashier, order.cashierName!.trim()),
        if ((order.registerSessionNumber ?? '').trim().isNotEmpty)
          OrderDocumentField(
            labels.registerSession,
            order.registerSessionNumber!.trim(),
          ),
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
              _saleLineProductName(line),
              _formatQuantityWithUnit(line.quantity, line.unitLabel),
              _formatMoney(line.unitPrice),
              _formatMoney(line.total),
            ],
        ],
        // What each line issued (an IMEI, a lot) and what a provider did for
        // it (a card's PIN, a subscriber's new term), one printed line each.
        rowNotes: [for (final line in order.lines) _saleLineNotes(line)],
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

  /// Hands the rendered document to the platform.
  ///
  /// A receipt-roll page goes through CUPS (`lp`) with its measured media size
  /// on Linux and macOS, for the same reason barcode labels do: the printing
  /// plugin cannot express roll media there. Its Linux job builder ignores the
  /// requested page size outright (a fresh `GtkPageSetup`, i.e. the locale
  /// default A4), so the driver falls back to the queue's own page — 80 × 297 mm
  /// on a typical thermal PPD — and every slip feeds that length whatever the
  /// content. A compact receipt then costs exactly as much paper as a standard
  /// one, which is the "they come out the same height" report.
  ///
  /// The plugin stays the fallback: A4, Windows, Android, any box without a
  /// CUPS client, and — deliberately — a failed `lp`. Printing a receipt is on
  /// the checkout path, so a spooler that is missing or misconfigured must
  /// degrade to a too-long slip, never to no slip at all.
  ///
  /// Windows has no `lp`, and there the same defect has a different cause:
  /// `usePrinterSettings: true` hands the plugin a null `DEVMODE` so the
  /// driver's own paper governs — again the queue's fixed roll page, again the
  /// same length for every slip. A roll job therefore asks for its measured
  /// page instead ([OrderDocumentRender.platformPageFormat]), which the plugin
  /// turns into `dmPaperSize = 0` plus `dmPaperWidth`/`dmPaperLength` in tenths
  /// of a millimetre. A4 keeps the driver's configuration, which is right for a
  /// sheet printer.
  Future<bool> _printPdf({
    required Future<OrderDocumentRender> Function() renderBuilder,
    required String jobName,
    PrinterEndpoint? endpoint,
  }) async {
    final render = await renderBuilder();
    final bytes = render.bytes;
    final width = render.mediaWidthMm;
    final height = render.mediaHeightMm;
    if (endpoint != null && width != null && height != null) {
      final spooled = await spoolPdfToCups(
        bytes: bytes,
        queue: endpoint.address,
        jobName: jobName,
        mediaWidthMm: width,
        mediaHeightMm: height,
        // A receipt is not die-cut stock: there is no gap to seek, and the roll
        // is left wherever the slip ended either way.
        registerLabelTop: false,
        // Bounded well inside the checkout print deadline, because a failure
        // here still has the plugin fallback to pay for.
        timeout: const Duration(seconds: 8),
      );
      if (spooled.succeeded) {
        return true;
      }
    }
    final format = render.platformPageFormat;
    // Deferring to the driver's paper is what pads a roll slip out to the
    // queue's page, so a roll states its page and a sheet does not.
    final usePrinterSettings = width == null || height == null;
    final selectedPrinter = endpoint == null
        ? null
        : await _resolvePrinter(endpoint);
    if (selectedPrinter != null) {
      return Printing.directPrintPdf(
        printer: selectedPrinter,
        name: jobName,
        format: format,
        onLayout: (_) async => bytes,
        usePrinterSettings: usePrinterSettings,
      );
    }
    return Printing.layoutPdf(
      name: jobName,
      format: format,
      usePrinterSettings: usePrinterSettings,
      onLayout: (_) async => bytes,
    );
  }

  /// Prints a document rendered elsewhere — the repair intake receipt — down
  /// the same road as an invoice: CUPS with the render's measured roll media
  /// where there is a CUPS client, the printing plugin everywhere else.
  Future<bool> printRender({
    required Future<OrderDocumentRender> Function() renderBuilder,
    required String jobName,
    PrinterEndpoint? endpoint,
  }) {
    return _printPdf(
      renderBuilder: renderBuilder,
      jobName: jobName,
      endpoint: endpoint,
    );
  }

  /// Prints a finished full-page document built elsewhere (a business report,
  /// a statement) on [endpoint] without a dialog when that printer can be
  /// reached, and through the system print dialog otherwise — including when
  /// no [endpoint] is given, which is how these documents always printed.
  Future<bool> printA4Document({
    required String jobName,
    required LayoutCallback onLayout,
    PdfPageFormat format = PdfPageFormat.a4,
    bool usePrinterSettings = false,
    PrinterEndpoint? endpoint,
  }) async {
    final printer = endpoint == null ? null : await _resolvePrinter(endpoint);
    if (printer != null) {
      return Printing.directPrintPdf(
        printer: printer,
        name: jobName,
        format: format,
        onLayout: onLayout,
        usePrinterSettings: usePrinterSettings,
      );
    }
    return Printing.layoutPdf(
      name: jobName,
      format: format,
      usePrinterSettings: usePrinterSettings,
      onLayout: onLayout,
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

  Future<OrderDocumentRender> _buildTestPdf({
    PdfPageSize pageSize = PdfPageSize.a4,
    bool compact = false,
  }) async {
    final fonts = await fontLoader.load();
    final brandLogoBytes = await brandLogoLoader.load();
    final template = OrderDocumentTemplate(
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
      totals: [OrderDocumentField(labels.total, _formatMoney(0), strong: true)],
    );
    final receiptWidthMm = pdfPageSizeReceiptWidthMm(pageSize);
    if (receiptWidthMm != null) {
      return _ReceiptFrame(
        template: template,
        labels: labels,
        fonts: fonts,
        widthMm: receiptWidthMm,
        compact: compact,
        brandLogoBytes: brandLogoBytes,
      ).build();
    }
    return _DocumentFrame(
      template: template,
      labels: labels,
      fonts: fonts,
      compact: compact,
      brandLogoBytes: brandLogoBytes,
    ).build();
  }
}

/// A rendered document together with the media it was laid out for, so the
/// print job can ask the spooler for exactly that page instead of leaving the
/// driver to guess.
///
/// [mediaWidthMm]/[mediaHeightMm] are set for receipt rolls only — an A4
/// document is a standard page every driver already knows. The height is the
/// **measured** page height (rounded up to a whole millimetre), which is the
/// whole point: a one-item compact slip is ~86 mm and a standard one ~117 mm,
/// and without saying so every slip comes out at the queue's own roll page
/// (80 × 297 mm on a typical thermal PPD) — the same length regardless.
class OrderDocumentRender {
  const OrderDocumentRender({
    required this.bytes,
    this.mediaWidthMm,
    this.mediaHeightMm,
  });

  final Uint8List bytes;
  final double? mediaWidthMm;
  final double? mediaHeightMm;

  /// Page format handed to the platform print channel when the CUPS path is
  /// unavailable (Windows, Android, a box with no CUPS client). The true page
  /// geometry is baked into the bytes; this states it in the terms the platform
  /// understands — a Windows custom paper length, a macOS `paperSize` — and the
  /// height must stay finite because the method channel cannot carry
  /// `double.infinity`.
  PdfPageFormat get platformPageFormat {
    final width = mediaWidthMm;
    final height = mediaHeightMm;
    if (width == null || height == null) {
      return PdfPageFormat.a4;
    }
    // Both platforms flip a page that is wider than tall into landscape — the
    // Windows plugin swaps `dmPaperWidth`/`dmPaperLength`, macOS sets
    // `NSPrintInfo.orientation` — which on a roll would lay the slip across the
    // paper. No real receipt is shorter than the roll is wide, but the failure
    // would be silent, so keep the page portrait by construction.
    final portraitHeight = math.max(height, width + 1);
    return PdfPageFormat(
      width * PdfPageFormat.mm,
      portraitHeight * PdfPageFormat.mm,
    );
  }
}

/// The page height of a receipt roll, in whole millimetres of media. Rounded up
/// so a sub-millimetre remainder can never clip the last line off the slip.
double rollMediaHeightMm(double heightPoints) =>
    (heightPoints / PdfPageFormat.mm).ceilToDouble();

/// A single roll "segment" is at most this many times the paper width tall. It
/// bounds both the media height a roll job asks the spooler for and the
/// point at which a long receipt stops being one continuous page and paginates
/// ([_ReceiptFrame]) — keeping the two in agreement so a driver never receives a
/// page taller than the hint (which pushed a long receipt's total off the top).
const double kRollPageHeightMultiple = 6;

/// Sendable bundle for [_buildOrderDocumentRender] so PDF rendering can run in a
/// background isolate. Every field is plain data (the template and labels) or
/// raw bytes (the logo and font data) — no pdf widgets or closures cross over.
class _OrderDocumentBuildRequest {
  const _OrderDocumentBuildRequest({
    required this.template,
    required this.logoBytes,
    required this.labels,
    required this.fontData,
    required this.pageSize,
    this.compact = false,
    this.brandLogoBytes,
  });

  final OrderDocumentTemplate template;
  final Uint8List? logoBytes;
  final OrderDocumentLabels labels;
  final PointyPdfFontData fontData;
  final PdfPageSize pageSize;

  /// Dense/compact layout: trimmed whitespace so the document uses less paper.
  final bool compact;

  /// Brand mark bytes for the closing "دُوِّنَ في دفتر" tagline (best-effort).
  final Uint8List? brandLogoBytes;
}

/// Top-level so it can serve as an isolate entry point: parses the font bytes
/// and performs the heavy synchronous PDF encoding. Renders the full A4
/// document or, for a receipt-roll [PdfPageSize], the compact receipt frame.
Future<OrderDocumentRender> _buildOrderDocumentRender(
  _OrderDocumentBuildRequest request,
) {
  final receiptWidthMm = pdfPageSizeReceiptWidthMm(request.pageSize);
  final fonts = request.fontData.toFonts();
  if (receiptWidthMm != null) {
    return _ReceiptFrame(
      template: request.template,
      shopLogoBytes: request.logoBytes,
      labels: request.labels,
      fonts: fonts,
      widthMm: receiptWidthMm,
      compact: request.compact,
      brandLogoBytes: request.brandLogoBytes,
    ).build();
  }
  return _DocumentFrame(
    template: request.template,
    shopLogoBytes: request.logoBytes,
    labels: request.labels,
    fonts: fonts,
    compact: request.compact,
    brandLogoBytes: request.brandLogoBytes,
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
    required this.cashier,
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
      cashier = 'الكاشير',
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
  final String cashier;
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
    this.compact = false,
    this.brandLogoBytes,
  });

  final OrderDocumentTemplate template;
  final Uint8List? shopLogoBytes;
  final OrderDocumentLabels labels;
  final PointyPdfFonts fonts;

  /// Dense layout: whitespace between sections and around rows is halved so the
  /// invoice fits more on the page.
  final bool compact;

  /// Brand mark for the closing tagline in the page footer.
  final Uint8List? brandLogoBytes;

  Future<OrderDocumentRender> build() async {
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
          pw.SizedBox(height: compact ? 16 : 32),
          _documentParties(),
          pw.SizedBox(height: compact ? 12 : 24),
          if (template.itemsTable != null) ...[
            template.itemsTable!.build(labels),
            pw.SizedBox(height: compact ? 12 : 24),
          ],
          _bottomSection(),
        ],
      ),
    );

    // A4 is a page every driver already knows: no media override needed.
    return OrderDocumentRender(bytes: await pdf.save());
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
                fontSize: compact ? 24 : 32,
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
            padding: pw.EdgeInsets.only(bottom: compact ? 4 : 8),
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
                    padding: pw.EdgeInsets.only(bottom: compact ? 5 : 10),
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
      brandLogo: pdfLogoProvider(brandLogoBytes),
    );
  }
}

/// A compact, single-column receipt rendering of an [OrderDocumentTemplate],
/// used by the PDF/document path when the printer is set to a receipt roll
/// width. Built as one continuous roll page — a fixed millimetre width and a
/// content-driven (infinite) height — so a receipt printer driven through its
/// own PDF/Windows driver (e.g. the Xprinter N160II) prints a real receipt
/// instead of a shrunken A4 page or ESC/POS gibberish. Reuses the shared PDF
/// palette/fonts so it stays on-brand; money stays RTL so the currency renders
/// correctly (forcing LTR mangles "د.ل").
class _ReceiptFrame {
  const _ReceiptFrame({
    required this.template,
    required this.labels,
    required this.fonts,
    required this.widthMm,
    this.shopLogoBytes,
    this.compact = false,
    this.brandLogoBytes,
  });

  final OrderDocumentTemplate template;
  final Uint8List? shopLogoBytes;
  final OrderDocumentLabels labels;
  final PointyPdfFonts fonts;
  final int widthMm;

  /// Dense layout: tighter dividers, row padding and inter-block gaps so the
  /// roll advances less paper per slip.
  final bool compact;

  /// Brand mark for the closing "دُوِّنَ في دفتر" tagline at the foot of the roll.
  final Uint8List? brandLogoBytes;

  static const double _horizontalMarginMm = 4;
  static const double _verticalMarginMm = 6;

  /// Top/bottom paper margin, trimmed in compact mode.
  double get _verticalMargin => compact ? 4 : _verticalMarginMm;

  /// Compact mode shrinks the type as well as the spacing — the roll advances
  /// per millimetre of content, so smaller glyphs are a direct paper saving.
  /// Kept above ~7pt: below that a 203dpi thermal head starts dropping strokes
  /// off Arabic diacritics.
  double get _bodyFont => compact ? 7.5 : 9;

  double get _detailFont => compact ? 7 : 8;

  double get _emphasisFont => compact ? 8.5 : 10;

  // Thermal receipt heads are 1-bit: a dot is either full black or blank, so any
  // grey (the shared A4 palette's muted labels / hairline rules) prints faint or
  // not at all. The receipt draws EVERYTHING in pure black; _thermalTheme pairs
  // it with a heavier (bold) base so thin glyphs don't fade either. The A4
  // document keeps the palette's greys (via _DocumentFrame) untouched.
  static const _ink = PdfColor.fromInt(0xff000000);

  double get _contentWidth =>
      widthMm * PdfPageFormat.mm - 2 * _horizontalMarginMm * PdfPageFormat.mm;

  /// The tallest a single continuous roll page may be before it is paginated.
  /// Matches the media height a paginated roll job asks for, so no page ever
  /// exceeds what the driver is told to expect.
  double get _maxPageHeight =>
      widthMm * PdfPageFormat.mm * kRollPageHeightMultiple;

  pw.EdgeInsets get _pageMargin => pw.EdgeInsets.symmetric(
    horizontal: _horizontalMarginMm * PdfPageFormat.mm,
    vertical: _verticalMargin * PdfPageFormat.mm,
  );

  Future<OrderDocumentRender> build() async {
    // Render as one continuous roll page (content-height, no blank tail) — the
    // right shape for the common short receipt.
    final continuous = _continuousDocument();
    final bytes = await continuous.save();
    // `save()` resolves the infinite-height page to its measured content height.
    // That measurement is the media the job asks for, so a short slip costs
    // short paper: the roll advances the receipt, not the queue's page.
    final pages = continuous.document.pdfPageList.pages;
    final measured = pages.isEmpty ? 0.0 : pages.first.pageFormat.height;
    if (measured <= _maxPageHeight) {
      return OrderDocumentRender(
        bytes: bytes,
        mediaWidthMm: widthMm.toDouble(),
        mediaHeightMm: rollMediaHeightMm(measured),
      );
    }
    // A long receipt (many items) whose content overruns a roll segment: a
    // single over-tall page overflows the driver's page and lands the total at
    // the top of a garbled slip. Re-render paginated so every item prints and
    // the total sits at the end, across as many segments as it takes.
    return OrderDocumentRender(
      bytes: await _paginatedDocument().save(),
      mediaWidthMm: widthMm.toDouble(),
      mediaHeightMm: rollMediaHeightMm(_maxPageHeight),
    );
  }

  pw.Document _newDocument() => pw.Document(
    title: '${template.title} ${template.reference}',
    author: template.shopName,
    creator: 'دفتر',
    subject: template.title,
  );

  pw.Document _continuousDocument() {
    final pdf = _newDocument();
    pdf.addPage(
      pw.Page(
        // Finite width, infinite height → one continuous roll page whose height
        // is measured from the content (no wasted blank tail on the roll).
        pageFormat: PdfPageFormat(widthMm * PdfPageFormat.mm, double.infinity),
        margin: _pageMargin,
        theme: _thermalTheme(),
        textDirection: pw.TextDirection.rtl,
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          mainAxisSize: pw.MainAxisSize.min,
          children: _bodyChildren(),
        ),
      ),
    );
    return pdf;
  }

  pw.Document _paginatedDocument() {
    final pdf = _newDocument();
    pdf.addPage(
      pw.MultiPage(
        // Bounded roll segments: the same body widgets flow across as many
        // fixed-height pages as needed. Each item row is a top-level widget so
        // the page break can fall between rows, never mid-row.
        pageFormat: PdfPageFormat(widthMm * PdfPageFormat.mm, _maxPageHeight),
        margin: _pageMargin,
        theme: _thermalTheme(),
        textDirection: pw.TextDirection.rtl,
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        maxPages: 200,
        build: (context) => _bodyChildren(),
      ),
    );
    return pdf;
  }

  /// A heavier base so small Arabic survives the ~203-dpi thermal head — old
  /// tills print a uniformly bold, black receipt. Latin/number glyphs fall back
  /// to the same digit font.
  pw.ThemeData _thermalTheme() {
    return pw.ThemeData.withFont(
      base: fonts.bold,
      bold: fonts.bold,
      fontFallback: fonts.fallback,
    );
  }

  /// The receipt body as a FLAT list of widgets — deliberately not wrapped in
  /// one Column, so [_paginatedDocument]'s [pw.MultiPage] can break the page
  /// between any two top-level widgets (notably between item rows) when a long
  /// receipt spills past a single roll segment.
  List<pw.Widget> _bodyChildren() {
    final children = <pw.Widget>[..._header(), _divider(), ..._titleBlock()];

    if (template.details.isNotEmpty) {
      children.add(pw.SizedBox(height: compact ? 2 : 3));
      for (final field in template.details) {
        children.add(_fieldRow(field));
      }
    }

    if (template.recipientLines.isNotEmpty) {
      children.add(_divider());
      children.addAll(_recipient());
    }

    final items = _itemWidgets();
    if (items.isNotEmpty) {
      children.add(_divider());
      children.addAll(items);
    }

    if (template.totals.isNotEmpty) {
      children.add(_divider());
      for (final field in template.totals) {
        children.add(_fieldRow(field));
      }
    }

    final terms = template.terms?.trim();
    if (terms != null && terms.isNotEmpty) {
      children.add(_divider());
      children.add(
        pw.Text(
          terms,
          style: const pw.TextStyle(fontSize: 8, color: _ink),
          textAlign: pw.TextAlign.center,
        ),
      );
    }

    final note = compactPdfText(template.notes, maxCharacters: 160);
    if (note != null) {
      children.add(pw.SizedBox(height: compact ? 3 : 6));
      children.add(
        pw.Text(
          note,
          style: const pw.TextStyle(fontSize: 8, color: _ink),
          textAlign: pw.TextAlign.center,
        ),
      );
    }

    final qr = _qr();
    if (qr != null) {
      children.add(pw.SizedBox(height: compact ? 4 : 8));
      children.add(qr);
    }

    // Closing brand stamp: "دُوِّنَ في [logo] دفتر", centered at the foot of the
    // roll. Pure black so it survives the thermal head; falls back to text when
    // the mark is unavailable.
    children.add(pw.SizedBox(height: compact ? 4 : 8));
    children.add(_divider());
    children.add(
      pw.Center(
        child: PointyPdfTagline(
          brandLogo: pdfLogoProvider(brandLogoBytes),
          fontSize: 8,
          logoHeight: 12,
          color: _ink,
          brandColor: _ink,
        ),
      ),
    );

    return children;
  }

  List<pw.Widget> _header() {
    final widgets = <pw.Widget>[];
    final logo = pdfLogoProvider(shopLogoBytes);
    if (logo != null) {
      widgets.add(
        pw.Center(
          child: pw.Container(
            height: 40,
            constraints: pw.BoxConstraints(maxWidth: _contentWidth * 0.7),
            child: pw.Image(logo, fit: pw.BoxFit.contain),
          ),
        ),
      );
      widgets.add(pw.SizedBox(height: 6));
    }
    widgets.add(
      pw.Text(
        template.shopName,
        style: pw.TextStyle(
          fontSize: 12,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
        textAlign: pw.TextAlign.center,
      ),
    );
    for (final line in template.shopHeaderLines) {
      widgets.add(pw.SizedBox(height: 2));
      widgets.add(
        pw.Text(
          line,
          style: const pw.TextStyle(fontSize: 8, color: _ink),
          textAlign: pw.TextAlign.center,
        ),
      );
    }
    return widgets;
  }

  List<pw.Widget> _titleBlock() {
    return [
      pw.Text(
        template.title,
        style: pw.TextStyle(
          fontSize: 11,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
        textAlign: pw.TextAlign.center,
      ),
      pw.SizedBox(height: 1),
      pw.Text(
        '#${template.reference}',
        style: const pw.TextStyle(fontSize: 8, color: _ink),
        textAlign: pw.TextAlign.center,
      ),
    ];
  }

  List<pw.Widget> _recipient() {
    final widgets = <pw.Widget>[
      pw.Text(
        template.recipientTitle,
        style: const pw.TextStyle(fontSize: 8, color: _ink),
      ),
      pw.SizedBox(height: 2),
      pw.Text(
        template.recipientLines.first,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
    ];
    for (final line in template.recipientLines.skip(1)) {
      widgets.add(pw.SizedBox(height: 1));
      widgets.add(
        pw.Text(line, style: const pw.TextStyle(fontSize: 8, color: _ink)),
      );
    }
    return widgets;
  }

  /// The item rows as separate top-level widgets (with the inter-row spacing
  /// interleaved), so a long list can be paginated between rows. Empty when
  /// there is no items table.
  List<pw.Widget> _itemWidgets() {
    final table = template.itemsTable;
    if (table == null || table.rows.isEmpty) {
      return const [];
    }
    final twoColumn = table.columns.length <= 2;
    final rows = <pw.Widget>[];
    for (var i = 0; i < table.rows.length; i++) {
      if (i > 0) {
        rows.add(pw.SizedBox(height: compact ? 2 : 4));
      }
      final row = _itemRow(table.rows[i], twoColumn: twoColumn);
      final notes = table.notesFor(i);
      // One widget per item, notes included, so a page break can never land
      // between a card and its PIN.
      rows.add(
        notes.isEmpty
            ? row
            : pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [row, for (final note in notes) _itemNote(note)],
              ),
      );
    }
    return rows;
  }

  /// A line beneath an item. Never clipped, even on a compact roll: a PIN
  /// cut off at the edge of the paper is a card the customer cannot use.
  pw.Widget _itemNote(OrderDocumentNote note) {
    if (note.emphasized) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Text(
          note.text,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: _emphasisFont + 4,
            fontWeight: pw.FontWeight.bold,
            color: _ink,
          ),
        ),
      );
    }
    return pw.Text(
      note.text,
      style: pw.TextStyle(fontSize: _detailFont, color: _ink),
    );
  }

  pw.Widget _itemRow(List<String> row, {required bool twoColumn}) {
    final cells = [
      for (final cell in row) cell.replaceAll(RegExp(r'\s+'), ' ').trim(),
    ];
    if (twoColumn) {
      return _labelValueRow(
        cells.isNotEmpty ? cells.first : '',
        cells.length > 1 ? cells.last : '',
      );
    }
    final name = cells.isNotEmpty && cells.first.isNotEmpty
        ? cells.first
        : labels.emptyValue;
    final total = cells.length > 1 ? cells.last : '';
    final middle = cells.length > 2
        ? cells
              .sublist(1, cells.length - 1)
              .where((cell) => cell.isNotEmpty)
              .join(' × ')
        : '';
    // Compact: name, quantity detail and total share one row. The name is the
    // only elastic part, so it takes the clip while the money stays whole.
    if (compact) {
      return pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Text(
              name,
              maxLines: 1,
              overflow: pw.TextOverflow.clip,
              style: pw.TextStyle(fontSize: _bodyFont, color: _ink),
            ),
          ),
          if (middle.isNotEmpty) ...[
            pw.SizedBox(width: 4),
            pw.Text(
              middle,
              style: pw.TextStyle(fontSize: _detailFont, color: _ink),
            ),
          ],
          pw.SizedBox(width: 4),
          pw.Text(
            total,
            style: pw.TextStyle(fontSize: _bodyFont, color: _ink),
          ),
        ],
      );
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          name,
          style: pw.TextStyle(fontSize: _bodyFont, color: _ink),
        ),
        pw.SizedBox(height: 1),
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Text(
                middle,
                style: pw.TextStyle(fontSize: _detailFont, color: _ink),
              ),
            ),
            pw.SizedBox(width: 6),
            pw.Text(
              total,
              style: pw.TextStyle(fontSize: _bodyFont, color: _ink),
            ),
          ],
        ),
      ],
    );
  }

  pw.Widget _fieldRow(OrderDocumentField field) {
    return _labelValueRow(
      field.label,
      field.value,
      emphasised: field.strong || field.highlight,
    );
  }

  pw.Widget _labelValueRow(
    String label,
    String value, {
    bool emphasised = false,
  }) {
    final style = pw.TextStyle(
      fontSize: emphasised ? _emphasisFont : _bodyFont,
      fontWeight: emphasised ? pw.FontWeight.bold : pw.FontWeight.normal,
      color: _ink,
    );
    return pw.Padding(
      padding: pw.EdgeInsets.symmetric(vertical: compact ? 1 : 2),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: pw.Text('$label:', style: style)),
          pw.SizedBox(width: 8),
          pw.Text(value, style: style),
        ],
      ),
    );
  }

  pw.Widget _divider() {
    return pw.Container(
      margin: pw.EdgeInsets.symmetric(vertical: compact ? 2 : 5),
      height: 0.6,
      color: _ink,
    );
  }

  pw.Widget? _qr() {
    final url = template.publicInvoiceUrl?.trim() ?? '';
    if (url.isEmpty) {
      return null;
    }
    final size = _contentWidth * 0.5;
    return pw.Center(
      child: pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Text(
            labels.onlineInvoice,
            style: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
            textAlign: pw.TextAlign.center,
          ),
          pw.SizedBox(height: 3),
          pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(),
            data: url,
            width: size,
            height: size,
            drawText: false,
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            labels.scanOnlineInvoice,
            style: const pw.TextStyle(fontSize: 8, color: _ink),
            textAlign: pw.TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class OrderDocumentTable {
  const OrderDocumentTable({
    required this.columns,
    required this.rows,
    this.rowNotes = const [],
    this.columnFlex = const [],
  });

  final List<String> columns;
  final List<List<String>> rows;

  /// Lines printed beneath a row, parallel to [rows] (missing = none).
  final List<List<OrderDocumentNote>> rowNotes;
  final List<double> columnFlex;

  List<OrderDocumentNote> notesFor(int index) =>
      index < rowNotes.length ? rowNotes[index] : const [];

  pw.Widget build(OrderDocumentLabels labels) {
    return PointyPdfTable.invoice(
      columns: columns,
      rows: [
        for (var index = 0; index < rows.length; index++)
          _withNotes(rows[index], notesFor(index)),
      ],
      columnFlex: columnFlex,
      emptyValue: labels.emptyValue,
      valueFormatter: _tableValue,
    ).build();
  }

  /// The A4 table draws plain text cells, so a row's notes go beneath its
  /// name, inside the same cell, one per line.
  static List<String> _withNotes(
    List<String> row,
    List<OrderDocumentNote> notes,
  ) {
    if (notes.isEmpty || row.isEmpty) {
      return row;
    }
    return [
      [row.first, for (final note in notes) note.text].join('\n'),
      ...row.skip(1),
    ];
  }

  /// Tidies a cell without flattening it: spaces collapse within a line, but
  /// the line breaks a row's notes are laid out on survive, and each line is
  /// capped on its own so a long note cannot swallow the one after it.
  String _tableValue(String value) {
    final lines = [
      for (final line in value.split('\n'))
        if (line.replaceAll(RegExp(r'\s+'), ' ').trim().isNotEmpty)
          _capped(line.replaceAll(RegExp(r'\s+'), ' ').trim()),
    ];
    return lines.isEmpty ? '-' : lines.join('\n');
  }

  static String _capped(String line) =>
      line.length <= 120 ? line : '${line.substring(0, 117)}...';
}

/// One line printed beneath a document row. [emphasized] is a card's PIN —
/// the line that has to be read at arm's length.
@immutable
class OrderDocumentNote {
  const OrderDocumentNote(this.text, {this.emphasized = false});

  final String text;
  final bool emphasized;
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

/// The printed lines beneath a sale line, in order: the identifiers it
/// issued, then what a provider did for it.
///
/// Notes rather than text folded into the name cell. Folded in, they were
/// flattened onto the name's line by the table's whitespace clean-up — and
/// clipped altogether on a compact roll — which for a provider's card would
/// cut off the PIN the customer paid for.
List<OrderDocumentNote> _saleLineNotes(SaleOrderLine line) {
  return [
    for (final identifier in _saleLineIdentifierLines(line))
      OrderDocumentNote(identifier),
    ..._saleLineIntegrationNotes(line),
  ];
}

String _saleLineProductName(SaleOrderLine line) {
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

/// What a provider did for this line — a card's PIN, a subscriber's new term
/// — from the same rows the thermal receipt prints.
List<OrderDocumentNote> _saleLineIntegrationNotes(SaleOrderLine line) {
  final integration = line.integration;
  if (integration == null) {
    return const [];
  }
  return [
    for (final row in receiptIntegrationRows(
      kind: integration.kind,
      status: integration.status,
      printed: integration.receipt,
      subscriberRef: integration.subscriberRef,
      reference: integration.providerReference,
      months: integration.months,
    ))
      OrderDocumentNote(row.text, emphasized: row.emphasized),
  ];
}

/// The IMEIs and lot numbers this line issued, one per printed line.
///
/// Empty for everything a shop counts rather than identifies, so an ordinary
/// invoice is byte-for-byte what it was.
List<String> _saleLineIdentifierLines(SaleOrderLine line) {
  return [
    for (final identifier in line.identifiers)
      if (identifier.code.trim().isNotEmpty)
        [
          identifier.code.trim(),
          if (!identifier.isUnit && identifier.quantity > 0)
            '× ${_formatQuantity(identifier.quantity)}',
          if (identifier.expiryDate != null)
            formatExpiry(identifier.expiryDate!),
        ].join('  '),
  ];
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
