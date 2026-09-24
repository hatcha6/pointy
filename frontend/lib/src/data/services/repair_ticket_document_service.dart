import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../shared/branding_assets.dart';
import '../../shared/formatters.dart';
import '../../shared/pdf/pdf.dart';
import '../models/printer_config.dart';
import '../models/repair_ticket.dart';
import 'order_document_service.dart';
import 'print_transport.dart';
import 'repair_intake_printables.dart';

/// The repair intake receipt through the PDF/document path — for receipt
/// printers whose driver takes PDF rather than raw ESC/POS (the same printers
/// the roll invoice exists for), and for a plain sheet printer.
///
/// A roll width gets a receipt: one continuous page as tall as its content,
/// in the thermal house style (pure black on a bold base, so a 203-dpi head
/// keeps every stroke). A4 gets a proper page with room to sign.
class RepairTicketDocumentService {
  const RepairTicketDocumentService({
    this.labels = const RepairTicketLabels.arabic(),
    this.fontLoader = const PointyPdfFontLoader(),
    this.brandLogoLoader = const PointyBrandLogoLoader(),
    this.documentService = const OrderDocumentService(),
  });

  final RepairTicketLabels labels;
  final PointyPdfFontLoader fontLoader;
  final PointyBrandLogoLoader brandLogoLoader;

  /// Owns the print pipeline, so a ticket spools exactly like an invoice.
  final OrderDocumentService documentService;

  Future<PrintTransportResult> printTicket({
    required RepairTicket ticket,
    required PrinterEndpoint endpoint,
    Uint8List? shopLogoBytes,
  }) async {
    try {
      final printed = await documentService.printRender(
        renderBuilder: () => buildRender(
          ticket: ticket,
          shopLogoBytes: shopLogoBytes,
          pageSize: endpoint.pdfPageSize,
          compact: endpoint.compactReceipt,
        ),
        jobName: 'repair-ticket-${ticket.jobNumber}',
        endpoint: endpoint,
      );
      return printed
          ? const PrintTransportResult.success('repair ticket printed')
          : const PrintTransportResult.failure('document print canceled');
    } on Object catch (error) {
      return PrintTransportResult.failure('repair ticket print failed: $error');
    }
  }

  Future<OrderDocumentRender> buildRender({
    required RepairTicket ticket,
    Uint8List? shopLogoBytes,
    PdfPageSize pageSize = PdfPageSize.roll80,
    bool compact = false,
  }) async {
    final request = _RepairTicketRenderRequest(
      ticket: ticket,
      labels: labels,
      fontData: await fontLoader.loadData(),
      pageSize: pageSize,
      compact: compact,
      shopLogoBytes: shopLogoBytes,
      brandLogoBytes: await brandLogoLoader.load(),
      currency: currencySymbol,
    );
    // Rendering is heavy and synchronous; a background isolate keeps the
    // intake screen responsive. The web target has no isolates.
    if (kIsWeb) {
      return _renderRepairTicket(request);
    }
    return compute(_renderRepairTicket, request);
  }
}

class _RepairTicketRenderRequest {
  const _RepairTicketRenderRequest({
    required this.ticket,
    required this.labels,
    required this.fontData,
    required this.pageSize,
    required this.compact,
    required this.currency,
    this.shopLogoBytes,
    this.brandLogoBytes,
  });

  final RepairTicket ticket;
  final RepairTicketLabels labels;
  final PointyPdfFontData fontData;
  final PdfPageSize pageSize;
  final bool compact;

  /// Carried across because the isolate cannot see the configured currency.
  final String currency;
  final Uint8List? shopLogoBytes;
  final Uint8List? brandLogoBytes;
}

Future<OrderDocumentRender> _renderRepairTicket(
  _RepairTicketRenderRequest request,
) {
  final fonts = request.fontData.toFonts();
  final rollWidth = pdfPageSizeReceiptWidthMm(request.pageSize);
  if (rollWidth != null) {
    return _RepairTicketRoll(
      request: request,
      fonts: fonts,
      widthMm: rollWidth,
    ).build();
  }
  return _RepairTicketPage(request: request, fonts: fonts).build();
}

String _money(double value, String currency) =>
    '${value.toStringAsFixed(2)} $currency';

/// The label/value rows a ticket carries under its heading.
List<(String, String)> _detailRows(
  RepairTicket ticket,
  RepairTicketLabels labels,
) {
  return [
    if (ticket.receivedAt != null)
      (labels.receivedAt, formatPdfDateTime(ticket.receivedAt!)),
    if (ticket.dueAt != null) (labels.dueAt, formatPdfDateTime(ticket.dueAt!)),
  ];
}

/// Price, fee and cover — the money the customer was told about at the counter.
List<(String, String, bool)> _moneyRows(
  RepairTicket ticket,
  RepairTicketLabels labels,
  String currency,
) {
  return [
    if (ticket.quotedPrice != null)
      (labels.quotedPrice, _money(ticket.quotedPrice!, currency), true),
    if (ticket.diagnosisFee != null)
      (labels.diagnosisFee, _money(ticket.diagnosisFee!, currency), false),
    if (ticket.warrantyDays > 0)
      (labels.warranty, labels.warrantyDays(ticket.warrantyDays), false),
  ];
}

// ---------------------------------------------------------------------------
// Receipt roll
// ---------------------------------------------------------------------------

class _RepairTicketRoll {
  _RepairTicketRoll({
    required this.request,
    required this.fonts,
    required this.widthMm,
  });

  final _RepairTicketRenderRequest request;
  final PointyPdfFonts fonts;
  final int widthMm;

  RepairTicket get ticket => request.ticket;
  RepairTicketLabels get labels => request.labels;
  bool get compact => request.compact;

  // A thermal head is 1-bit: grey prints faint or not at all, so the roll is
  // drawn in pure black, like the roll invoice.
  static const _ink = PdfColor.fromInt(0xff000000);
  static const double _mm = PdfPageFormat.mm;
  static const double _horizontalMarginMm = 4;

  double get _verticalMarginMm => compact ? 4 : 6;
  double get _contentWidth => (widthMm - 2 * _horizontalMarginMm) * _mm;
  double get _maxPageHeight => widthMm * _mm * kRollPageHeightMultiple;
  bool get _narrow => widthMm <= 58;

  // Held at 7pt and above: below that a 203-dpi head drops strokes off Arabic.
  double get _body => compact ? 7.5 : 9;
  double get _small => compact ? 7 : 8;
  double get _lead => compact ? 9 : 10.5;
  double get _gap => compact ? 2 : 4;

  pw.EdgeInsets get _pageMargin => pw.EdgeInsets.symmetric(
    horizontal: _horizontalMarginMm * _mm,
    vertical: _verticalMarginMm * _mm,
  );

  pw.ThemeData _theme() => pw.ThemeData.withFont(
    base: fonts.bold,
    bold: fonts.bold,
    fontFallback: fonts.fallback,
  );

  pw.Document _newDocument() => pw.Document(
    title: '${labels.title} ${ticket.jobNumber}',
    author: ticket.shopName,
    creator: 'دفتر',
    subject: labels.title,
  );

  /// Measure, then decide — the roll invoice's rule. Almost every ticket is one
  /// continuous page exactly as tall as its content; one whose conditions run
  /// past a roll segment is re-laid across fixed-height pages instead of
  /// handing the driver a page taller than the media it was promised.
  Future<OrderDocumentRender> build() async {
    final continuous = _newDocument()
      ..addPage(
        pw.Page(
          pageFormat: PdfPageFormat(widthMm * _mm, double.infinity),
          margin: _pageMargin,
          theme: _theme(),
          textDirection: pw.TextDirection.rtl,
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            mainAxisSize: pw.MainAxisSize.min,
            children: _blocks(),
          ),
        ),
      );
    final bytes = await continuous.save();
    final pages = continuous.document.pdfPageList.pages;
    final measured = pages.isEmpty ? 0.0 : pages.first.pageFormat.height;
    if (measured <= _maxPageHeight) {
      return OrderDocumentRender(
        bytes: bytes,
        mediaWidthMm: widthMm.toDouble(),
        mediaHeightMm: rollMediaHeightMm(measured),
      );
    }
    final paginated = _newDocument()
      ..addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat(widthMm * _mm, _maxPageHeight),
          margin: _pageMargin,
          theme: _theme(),
          textDirection: pw.TextDirection.rtl,
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          maxPages: 50,
          build: (_) => _blocks(),
        ),
      );
    return OrderDocumentRender(
      bytes: await paginated.save(),
      mediaWidthMm: widthMm.toDouble(),
      mediaHeightMm: rollMediaHeightMm(_maxPageHeight),
    );
  }

  /// A flat list of blocks, so a paginated roll can break between any two.
  List<pw.Widget> _blocks() {
    final currency = request.currency;
    final details = _detailRows(ticket, labels);
    final money = _moneyRows(ticket, labels, currency);
    return [
      ..._masthead(),
      _divider(),
      ..._heading(),
      if (details.isNotEmpty) ...[
        _divider(),
        for (final (label, value) in details) _row(label, value),
      ],
      _divider(),
      _section(labels.customer, [
        _leadLine(ticket.customerName),
        if (ticket.customerPhone.isNotEmpty) _plainLine(ticket.customerPhone),
      ]),
      for (final device in ticket.devices) ...[
        _divider(),
        _section(labels.device, [
          _leadLine(device.name),
          for (final identifier in device.identifiers) _plainLine(identifier),
          if (device.color.isNotEmpty)
            _plainLine('${labels.color}: ${device.color}'),
        ]),
      ],
      if (ticket.problem.isNotEmpty) ...[
        _divider(),
        _section(labels.problem, [_plainLine(ticket.problem, size: _body)]),
      ],
      if (money.isNotEmpty) ...[
        _divider(),
        for (final (label, value, strong) in money)
          _row(label, value, strong: strong),
      ],
      if (ticket.terms.isNotEmpty) ...[_divider(), ..._terms()],
      _divider(),
      ..._signOff(),
      ..._closing(),
    ];
  }

  List<pw.Widget> _masthead() {
    final logo = pdfLogoProvider(request.shopLogoBytes);
    return [
      if (logo != null) ...[
        pw.Center(
          child: pw.Container(
            height: 38,
            constraints: pw.BoxConstraints(maxWidth: _contentWidth * 0.7),
            child: pw.Image(logo, fit: pw.BoxFit.contain),
          ),
        ),
        pw.SizedBox(height: _gap),
      ],
      pw.Text(
        ticket.shopName,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: compact ? 11 : 13,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
      for (final line in ticket.shopHeaderLines)
        pw.Text(
          line,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(fontSize: _small, color: _ink),
        ),
      if (ticket.shopPhone.isNotEmpty)
        pw.Text(
          '${labels.shopPhone}: ${ticket.shopPhone}',
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(fontSize: _small, color: _ink),
        ),
    ];
  }

  /// What this slip is and the number it is found by: the title, the job
  /// number boxed large enough to read across a counter, and the bars under
  /// it for the scanner.
  List<pw.Widget> _heading() {
    final modules = pdfCode128ModuleCount(ticket.scanCode);
    // Wide enough to scan comfortably, never the full roll: bars wider than
    // ~55 mm buy nothing but ink.
    final barcodeWidth = pdfSnappedBarcodeWidth(
      modules,
      math.min(_contentWidth * 0.92, 55 * _mm),
    );
    return [
      pw.Text(
        labels.title,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: compact ? 10 : 12,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
      pw.SizedBox(height: _gap),
      pw.Container(
        // Air on every side: a number printed into its own border reads as
        // cut off, even when every digit is there.
        padding: pw.EdgeInsets.symmetric(
          vertical: compact ? 3 : 5,
          horizontal: _narrow ? 4 : 8,
        ),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: _ink, width: 1.2),
          borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
        ),
        child: pw.Column(
          children: [
            pw.Text(
              labels.jobNumber,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(fontSize: _small, color: _ink),
            ),
            pw.FittedBox(
              fit: pw.BoxFit.scaleDown,
              child: pw.Text(
                ticket.jobNumber,
                textDirection: pw.TextDirection.ltr,
                style: pw.TextStyle(
                  fontSize: _narrow ? 13 : (compact ? 14 : 17),
                  fontWeight: pw.FontWeight.bold,
                  color: _ink,
                ),
              ),
            ),
          ],
        ),
      ),
      if (modules > 0) ...[
        pw.SizedBox(height: _gap + 2),
        pw.Center(
          child: pw.SizedBox(
            width: barcodeWidth,
            height: (compact ? 9 : 12) * _mm,
            child: PointyPdfCode128(
              data: ticket.scanCode,
              modules: modules,
              dpi: 203,
              color: _ink,
            ),
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          ticket.scanCode,
          textAlign: pw.TextAlign.center,
          textDirection: pw.TextDirection.ltr,
          style: pw.TextStyle(fontSize: _small, color: _ink),
        ),
      ],
      pw.SizedBox(height: _gap / 2),
      pw.Text(
        labels.scanHint,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(fontSize: _small, color: _ink),
      ),
    ];
  }

  pw.Widget _section(String title, List<pw.Widget> lines) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(
          title,
          style: pw.TextStyle(fontSize: _small, color: _ink),
        ),
        pw.SizedBox(height: 1),
        ...lines,
      ],
    );
  }

  pw.Widget _leadLine(String text) => pw.Text(
    text,
    style: pw.TextStyle(
      fontSize: _lead,
      fontWeight: pw.FontWeight.bold,
      color: _ink,
    ),
  );

  pw.Widget _plainLine(String text, {double? size}) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 1),
    child: pw.Text(
      text,
      style: pw.TextStyle(fontSize: size ?? _small, color: _ink),
    ),
  );

  /// `label ........ value`, the value never clipped: it is a date or an
  /// amount, and the part that has to be right.
  pw.Widget _row(String label, String value, {bool strong = false}) {
    final style = pw.TextStyle(
      fontSize: strong ? _lead : _body,
      fontWeight: strong ? pw.FontWeight.bold : pw.FontWeight.normal,
      color: _ink,
    );
    return pw.Padding(
      padding: pw.EdgeInsets.symmetric(vertical: compact ? 1 : 1.5),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: pw.Text('$label:', style: style)),
          pw.SizedBox(width: 6),
          pw.Text(value, style: style),
        ],
      ),
    );
  }

  List<pw.Widget> _terms() {
    final size = compact ? 7.0 : 7.5;
    return [
      pw.Text(
        labels.terms,
        style: pw.TextStyle(fontSize: _small, color: _ink),
      ),
      pw.SizedBox(height: 1),
      for (var index = 0; index < ticket.terms.length; index++)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 1),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(
                width: size * 1.6,
                child: pw.Text(
                  '${index + 1}.',
                  style: pw.TextStyle(fontSize: size, color: _ink),
                ),
              ),
              pw.Expanded(
                child: pw.Text(
                  ticket.terms[index],
                  style: pw.TextStyle(fontSize: size, color: _ink),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  /// Who took it in, and room for the customer to sign that the above is what
  /// they handed over.
  List<pw.Widget> _signOff() {
    return [
      if (ticket.receivedBy.isNotEmpty)
        _row(labels.receivedBy, ticket.receivedBy),
      pw.SizedBox(height: compact ? 8 : 14),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Text(
            '${labels.customerSignature}:',
            style: pw.TextStyle(fontSize: _body, color: _ink),
          ),
          pw.SizedBox(width: 6),
          pw.Expanded(
            child: pw.Container(
              height: 1,
              margin: const pw.EdgeInsets.only(bottom: 2),
              color: _ink,
            ),
          ),
        ],
      ),
    ];
  }

  List<pw.Widget> _closing() {
    final note = compactPdfText(ticket.footerNote, maxCharacters: 160);
    return [
      if (note != null) ...[
        pw.SizedBox(height: _gap * 1.5),
        pw.Text(
          note,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(fontSize: _small, color: _ink),
        ),
      ],
      pw.SizedBox(height: _gap * 1.5),
      _divider(),
      pw.Center(
        child: PointyPdfTagline(
          brandLogo: pdfLogoProvider(request.brandLogoBytes),
          fontSize: 8,
          logoHeight: 12,
          color: _ink,
          brandColor: _ink,
        ),
      ),
    ];
  }

  pw.Widget _divider() => pw.Container(
    margin: pw.EdgeInsets.symmetric(vertical: compact ? 2.5 : 5),
    height: 0.6,
    color: _ink,
  );
}

// ---------------------------------------------------------------------------
// A4 page
// ---------------------------------------------------------------------------

class _RepairTicketPage {
  _RepairTicketPage({required this.request, required this.fonts});

  final _RepairTicketRenderRequest request;
  final PointyPdfFonts fonts;

  RepairTicket get ticket => request.ticket;
  RepairTicketLabels get labels => request.labels;

  static const double _mm = PdfPageFormat.mm;

  Future<OrderDocumentRender> build() async {
    final pdf = pw.Document(
      title: '${labels.title} ${ticket.jobNumber}',
      author: ticket.shopName,
      creator: 'دفتر',
      subject: labels.title,
    );
    pdf.addPage(
      buildPointyPdfMultiPage(
        fonts: fonts,
        footer: (context) => PointyPdfFooter(
          pageLabel: '${context.pageNumber} / ${context.pagesCount}',
          shopFooter: compactPdfText(ticket.footerNote, maxCharacters: 150),
          brandLogo: pdfLogoProvider(request.brandLogoBytes),
        ),
        build: (_) => [
          _masthead(),
          pw.SizedBox(height: 18),
          _shopAndDetails(),
          pw.SizedBox(height: 18),
          _partiesRow(),
          if (ticket.problem.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            _panel(labels.problem, [
              pw.Text(
                ticket.problem,
                style: const pw.TextStyle(
                  fontSize: 11,
                  color: PointyPdfPalette.ink,
                ),
              ),
            ]),
          ],
          ..._money(),
          if (ticket.terms.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            ..._terms(),
          ],
          pw.SizedBox(height: 28),
          _signatures(),
        ],
      ),
    );
    return OrderDocumentRender(bytes: await pdf.save());
  }

  /// Title and job number to one side, the shop's logo and the job's barcode
  /// to the other — laid out LTR so the barcode panel sits at the page edge.
  pw.Widget _masthead() {
    final logo = pdfLogoProvider(request.shopLogoBytes);
    final modules = pdfCode128ModuleCount(ticket.scanCode);
    return pw.Directionality(
      textDirection: pw.TextDirection.ltr,
      child: PointyPdfMasthead(
        leading: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (modules > 0)
              pw.Container(
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PointyPdfPalette.border),
                  borderRadius: const pw.BorderRadius.all(
                    pw.Radius.circular(6),
                  ),
                ),
                child: pw.Column(
                  children: [
                    pw.SizedBox(
                      width: pdfSnappedBarcodeWidth(modules, 50 * _mm),
                      height: 13 * _mm,
                      child: PointyPdfCode128(
                        data: ticket.scanCode,
                        modules: modules,
                        dpi: 300,
                        color: PointyPdfPalette.ink,
                      ),
                    ),
                    pw.SizedBox(height: 3),
                    pw.Text(
                      ticket.scanCode,
                      style: const pw.TextStyle(
                        fontSize: 8,
                        color: PointyPdfPalette.muted,
                      ),
                    ),
                  ],
                ),
              ),
            if (logo != null) ...[
              pw.SizedBox(width: 12),
              pw.Container(
                width: 84,
                height: 52,
                alignment: pw.Alignment.topLeft,
                child: pw.Image(logo, fit: pw.BoxFit.contain),
              ),
            ],
          ],
        ),
        trailing: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              labels.title,
              textDirection: pw.TextDirection.rtl,
              style: pw.TextStyle(
                fontSize: 26,
                fontWeight: pw.FontWeight.bold,
                color: PointyPdfPalette.ink,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              ticket.jobNumber,
              style: pw.TextStyle(
                fontSize: 18,
                fontWeight: pw.FontWeight.bold,
                color: PointyPdfPalette.accent,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              labels.scanHint,
              textDirection: pw.TextDirection.rtl,
              style: const pw.TextStyle(
                fontSize: 9,
                color: PointyPdfPalette.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  pw.Widget _shopAndDetails() {
    final details = _detailRows(ticket, labels);
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                ticket.shopName,
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                  color: PointyPdfPalette.ink,
                ),
              ),
              for (final line in ticket.shopHeaderLines)
                pw.Text(
                  line,
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PointyPdfPalette.ink,
                  ),
                ),
              if (ticket.shopPhone.isNotEmpty)
                pw.Text(
                  '${labels.shopPhone}: ${ticket.shopPhone}',
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PointyPdfPalette.ink,
                  ),
                ),
            ],
          ),
        ),
        pw.SizedBox(width: 24),
        pw.SizedBox(
          width: 230,
          child: pw.Column(
            children: [
              for (final (label, value) in details)
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 6),
                  child: PointyPdfFieldRow(label: label, value: value),
                ),
              if (ticket.receivedBy.isNotEmpty)
                PointyPdfFieldRow(
                  label: labels.receivedBy,
                  value: ticket.receivedBy,
                ),
            ],
          ),
        ),
      ],
    );
  }

  pw.Widget _partiesRow() {
    final customer = _panel(labels.customer, [
      _lead(ticket.customerName),
      if (ticket.customerPhone.isNotEmpty) _plain(ticket.customerPhone),
    ]);
    final devices = [
      for (final device in ticket.devices)
        _panel(labels.device, [
          _lead(device.name),
          for (final identifier in device.identifiers) _plain(identifier),
          if (device.color.isNotEmpty)
            _plain('${labels.color}: ${device.color}'),
        ]),
    ];
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(child: customer),
        if (devices.isNotEmpty) ...[
          pw.SizedBox(width: 12),
          pw.Expanded(
            child: pw.Column(
              children: [
                for (var index = 0; index < devices.length; index++) ...[
                  if (index > 0) pw.SizedBox(height: 8),
                  devices[index],
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  List<pw.Widget> _money() {
    final rows = _moneyRows(ticket, labels, request.currency);
    if (rows.isEmpty) {
      return const [];
    }
    return [
      pw.SizedBox(height: 12),
      pw.Row(
        children: [
          pw.Spacer(),
          pw.SizedBox(
            width: 260,
            child: pw.Column(
              children: [
                for (final (label, value, strong) in rows)
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 6),
                    child: PointyPdfFieldRow(
                      label: label,
                      value: value,
                      strong: strong,
                      highlighted: strong,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ];
  }

  List<pw.Widget> _terms() {
    return [
      PointyPdfSectionTitle(labels.terms, fontSize: 11),
      pw.SizedBox(height: 4),
      for (var index = 0; index < ticket.terms.length; index++)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Text(
            '${index + 1}. ${ticket.terms[index]}',
            style: const pw.TextStyle(
              fontSize: 9.5,
              color: PointyPdfPalette.ink,
            ),
          ),
        ),
    ];
  }

  pw.Widget _signatures() {
    pw.Widget line(String label) => pw.Expanded(
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(height: 28),
          pw.Container(height: 0.8, color: PointyPdfPalette.ink),
          pw.SizedBox(height: 4),
          pw.Text(
            label,
            style: const pw.TextStyle(
              fontSize: 10,
              color: PointyPdfPalette.muted,
            ),
          ),
        ],
      ),
    );
    return pw.Row(
      children: [
        line(labels.customerSignature),
        pw.SizedBox(width: 40),
        line(labels.receivedBy),
      ],
    );
  }

  pw.Widget _panel(String title, List<pw.Widget> children) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PointyPdfPalette.fill,
        border: pw.Border.all(color: PointyPdfPalette.border, width: 0.6),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            title,
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: PointyPdfPalette.accent,
            ),
          ),
          pw.SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }

  pw.Widget _lead(String text) => pw.Text(
    text,
    style: pw.TextStyle(
      fontSize: 12,
      fontWeight: pw.FontWeight.bold,
      color: PointyPdfPalette.ink,
    ),
  );

  pw.Widget _plain(String text) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 2),
    child: pw.Text(
      text,
      style: const pw.TextStyle(fontSize: 10, color: PointyPdfPalette.ink),
    ),
  );
}
