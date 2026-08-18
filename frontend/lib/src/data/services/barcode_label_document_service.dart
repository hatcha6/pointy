import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../shared/date_formatters.dart';
import '../../shared/formatters.dart';
import '../../shared/pdf/pdf.dart';
import '../models/barcode_label.dart';
import '../models/printer_config.dart';
import 'print_transport.dart';

/// Renders and prints barcode-label stickers through the PDF/document path (the
/// [PrinterOutputMode.pdfA4] output mode used by system / driver printers), the
/// same route receipts take on a driver-PDF thermal printer. This lets the very
/// same label/receipt printers that only understand their vendor PDF/graphics
/// driver — not raw ESC/POS or ZPL — print proper stickers instead of gibberish.
///
/// The output adapts to [PrinterEndpoint.labelPdfSize]: a die-cut 40×22 mm
/// sticker (default), a 50/70/80 mm continuous label roll, or a tiled grid on an
/// A4 sheet. [PrinterEndpoint.labelRotationQuarterTurns] rotates the die-cut
/// sticker for printers whose native feed orientation is landscape.
class BarcodeLabelDocumentService {
  const BarcodeLabelDocumentService({
    this.fontLoader = const PointyPdfFontLoader(),
  });

  final PointyPdfFontLoader fontLoader;

  Future<PrintTransportResult> printLabels({
    required List<BarcodeLabelPrintLine> lines,
    required PrinterEndpoint endpoint,
    String? shopName,
    Uint8List? shopLogoBytes,
  }) async {
    try {
      final bytes = await buildLabelsPdf(
        lines: lines,
        endpoint: endpoint,
        shopName: shopName,
        shopLogoBytes: shopLogoBytes,
      );
      if (bytes.isEmpty) {
        return const PrintTransportResult.failure('no barcode labels to print');
      }
      final printed = await _printPdf(
        bytes: bytes,
        endpoint: endpoint,
        jobName: 'barcode-labels',
      );
      return printed
          ? const PrintTransportResult.success('barcode labels printed')
          : const PrintTransportResult.failure('document print canceled');
    } on Object catch (error) {
      return PrintTransportResult.failure('label print failed: $error');
    }
  }

  Future<PrintTransportResult> printTest(
    PrinterEndpoint endpoint, {
    String? shopName,
  }) {
    return printLabels(
      lines: const [
        BarcodeLabelPrintLine(
          label: BarcodeLabelDraft(
            displayName: 'ملصق اختبار',
            productName: 'ملصق اختبار',
            sku: 'TEST-LABEL',
            barcode: '123456789012',
            unitPrice: 1,
          ),
          copies: 1,
          includePrice: true,
        ),
      ],
      endpoint: endpoint,
      shopName: shopName,
    );
  }

  /// Builds the label sheet as PDF bytes. Returns an empty list when no line has
  /// a printable (non-empty) barcode.
  Future<Uint8List> buildLabelsPdf({
    required List<BarcodeLabelPrintLine> lines,
    required PrinterEndpoint endpoint,
    String? shopName,
    Uint8List? shopLogoBytes,
  }) async {
    final stickers = _expand(lines);
    if (stickers.isEmpty) {
      return Uint8List(0);
    }
    final fonts = await fontLoader.load();
    return _BarcodeLabelSheet(
      stickers: stickers,
      size: endpoint.labelPdfSize,
      rotationQuarterTurns: endpoint.labelRotationQuarterTurns,
      shopName: (shopName ?? '').trim(),
      fonts: fonts,
    ).build();
  }

  Future<bool> _printPdf({
    required Uint8List bytes,
    required PrinterEndpoint endpoint,
    required String jobName,
  }) async {
    final format = _platformFormat(endpoint.labelPdfSize);
    final printer = await _resolvePrinter(endpoint);
    if (printer != null) {
      return Printing.directPrintPdf(
        printer: printer,
        name: jobName,
        format: format,
        usePrinterSettings: true,
        onLayout: (_) async => bytes,
      );
    }
    return Printing.layoutPdf(
      name: jobName,
      format: format,
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

  List<_LabelSticker> _expand(List<BarcodeLabelPrintLine> lines) {
    final stickers = <_LabelSticker>[];
    for (final line in lines) {
      final barcode = line.label.barcode.replaceAll(RegExp(r'[\r\n]'), '').trim();
      if (barcode.isEmpty || line.copies <= 0) {
        continue;
      }
      final sticker = _LabelSticker(
        name: line.label.displayName.trim().isEmpty
            ? line.label.productName.trim()
            : line.label.displayName.trim(),
        barcode: barcode,
        priceText: line.includePrice ? formatMoney(line.label.unitPrice) : null,
        expiryText: line.expiryDate == null
            ? null
            : formatDate(line.expiryDate!),
      );
      for (var i = 0; i < line.copies; i++) {
        stickers.add(sticker);
      }
    }
    return stickers;
  }
}

/// The platform page-format hint. The true geometry is baked into the PDF bytes;
/// `usePrinterSettings: true` lets the driver's own label config govern feed/cut.
PdfPageFormat _platformFormat(BarcodeLabelPdfSize size) {
  final widthMm = barcodeLabelPdfWidthMm(size);
  if (widthMm == null) {
    return PdfPageFormat.a4;
  }
  if (size == BarcodeLabelPdfSize.label40x22) {
    return PdfPageFormat(40 * PdfPageFormat.mm, 22 * PdfPageFormat.mm);
  }
  final width = widthMm * PdfPageFormat.mm;
  return PdfPageFormat(width, width * 4);
}

class _LabelSticker {
  const _LabelSticker({
    required this.name,
    required this.barcode,
    this.priceText,
    this.expiryText,
  });

  final String name;
  final String barcode;
  final String? priceText;
  final String? expiryText;

  String? get detailText {
    final parts = <String>[
      ?priceText,
      if (expiryText != null) 'ينتهي $expiryText',
    ];
    return parts.isEmpty ? null : parts.join('   ');
  }
}

/// Lays label stickers out on the page. Thermal/label heads are 1-bit, so
/// everything is drawn in pure black on a bold base to survive a low-dpi head.
class _BarcodeLabelSheet {
  _BarcodeLabelSheet({
    required this.stickers,
    required this.size,
    required this.rotationQuarterTurns,
    required this.shopName,
    required this.fonts,
  });

  final List<_LabelSticker> stickers;
  final BarcodeLabelPdfSize size;
  final int rotationQuarterTurns;
  final String shopName;
  final PointyPdfFonts fonts;

  static const _ink = PdfColor.fromInt(0xff000000);
  static const double _mm = PdfPageFormat.mm;

  Future<Uint8List> build() {
    final pdf = pw.Document(
      title: 'ملصقات الباركود',
      creator: 'دفتر',
      subject: 'barcode labels',
    );
    switch (size) {
      case BarcodeLabelPdfSize.label40x22:
        _addFixedStickerPages(pdf, widthMm: 40, heightMm: 22);
      case BarcodeLabelPdfSize.roll50:
        _addRollStickerPages(pdf, widthMm: 50);
      case BarcodeLabelPdfSize.roll70:
        _addRollStickerPages(pdf, widthMm: 70);
      case BarcodeLabelPdfSize.roll80:
        _addRollStickerPages(pdf, widthMm: 80);
      case BarcodeLabelPdfSize.a4:
        _addA4GridPage(pdf);
    }
    return pdf.save();
  }

  pw.ThemeData _theme() {
    return pw.ThemeData.withFont(
      base: fonts.bold,
      bold: fonts.bold,
      fontFallback: fonts.fallback,
    );
  }

  /// One die-cut sticker per page. Honours all four rotations by swapping the
  /// page dimensions and rotating the content for the quarter-turns.
  void _addFixedStickerPages(
    pw.Document pdf, {
    required double widthMm,
    required double heightMm,
  }) {
    final rot = ((rotationQuarterTurns % 4) + 4) % 4;
    final swap = rot.isOdd;
    final pageWidth = (swap ? heightMm : widthMm) * _mm;
    final pageHeight = (swap ? widthMm : heightMm) * _mm;
    const marginMm = 1.4;
    final contentWidth = (widthMm - 2 * marginMm) * _mm;
    final contentHeight = (heightMm - 2 * marginMm) * _mm;
    final barcodeHeight = math.max(10 * _mm, contentHeight * 0.52);

    for (final sticker in stickers) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(pageWidth, pageHeight),
          margin: pw.EdgeInsets.zero,
          theme: _theme(),
          textDirection: pw.TextDirection.rtl,
          build: (context) => pw.Center(
            child: pw.Transform.rotateBox(
              angle: rot * (math.pi / 2),
              child: pw.SizedBox(
                width: contentWidth,
                height: contentHeight,
                child: pw.FittedBox(
                  fit: pw.BoxFit.scaleDown,
                  child: pw.SizedBox(
                    width: contentWidth,
                    child: _card(
                      sticker,
                      barcodeWidth: contentWidth,
                      barcodeHeight: barcodeHeight,
                      compact: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
  }

  /// One sticker per continuous-roll page: fixed width, content-measured height
  /// (no wasted tail). Rotation only flips (180°) here — a roll's width already
  /// equals the label width, so 90°/270° would not fit the media.
  void _addRollStickerPages(pw.Document pdf, {required double widthMm}) {
    final flip = (((rotationQuarterTurns % 4) + 4) % 4) == 2;
    const marginMm = 3.0;
    final contentWidth = (widthMm - 2 * marginMm) * _mm;
    // A roll is far wider than a barcode needs to be: spanning the full width
    // gives a ~0.7 mm module (nothing gains from that) and a barcode tall
    // enough to dominate the sticker. Keep it comfortably above the ~0.25 mm
    // minimum module instead, and let narrow rolls keep a larger share.
    final barcodeWidth = contentWidth * (widthMm >= 70 ? 0.68 : 0.85);
    final barcodeHeight = math.max(11 * _mm, widthMm * 0.16 * _mm);

    for (final sticker in stickers) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(widthMm * _mm, double.infinity),
          margin: const pw.EdgeInsets.symmetric(
            horizontal: marginMm * _mm,
            vertical: (marginMm + 1) * _mm,
          ),
          theme: _theme(),
          textDirection: pw.TextDirection.rtl,
          build: (context) {
            final card = _card(
              sticker,
              barcodeWidth: barcodeWidth,
              barcodeHeight: barcodeHeight,
              compact: false,
            );
            return flip
                ? pw.Transform.rotateBox(angle: math.pi, child: card)
                : card;
          },
        ),
      );
    }
  }

  /// Tiles 40×22 mm stickers into a grid across A4 sheets (the Avery-style label
  /// sheet case), paginating automatically. Thin cut guides frame each cell.
  void _addA4GridPage(pw.Document pdf) {
    final flip = (((rotationQuarterTurns % 4) + 4) % 4) == 2;
    const cellWidthMm = 40.0;
    const cellHeightMm = 22.0;
    const gapMm = 2.0;
    final barcodeHeight = (cellHeightMm - 2 * 1.4) * 0.52 * _mm;

    final cells = <pw.Widget>[
      for (final sticker in stickers)
        pw.Container(
          width: cellWidthMm * _mm,
          height: cellHeightMm * _mm,
          padding: const pw.EdgeInsets.all(1.4 * _mm),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _ink, width: 0.3),
          ),
          child: pw.FittedBox(
            fit: pw.BoxFit.scaleDown,
            child: pw.SizedBox(
              width: (cellWidthMm - 2 * 1.4) * _mm,
              child: () {
                final card = _card(
                  sticker,
                  barcodeWidth: (cellWidthMm - 2 * 1.4) * _mm,
                  barcodeHeight: barcodeHeight,
                  compact: true,
                );
                return flip
                    ? pw.Transform.rotateBox(angle: math.pi, child: card)
                    : card;
              }(),
            ),
          ),
        ),
    ];

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(8 * _mm),
        theme: _theme(),
        textDirection: pw.TextDirection.rtl,
        build: (context) => [
          pw.Wrap(
            spacing: gapMm * _mm,
            runSpacing: gapMm * _mm,
            alignment: pw.WrapAlignment.center,
            children: cells,
          ),
        ],
      ),
    );
  }

  /// The sticker face: shop name, product name, barcode (with human-readable
  /// digits) and an optional price / expiry line. RTL, all pure black.
  pw.Widget _card(
    _LabelSticker sticker, {
    required double barcodeWidth,
    required double barcodeHeight,
    required bool compact,
  }) {
    final nameSize = compact ? 8.0 : 11.0;
    final shopSize = compact ? 6.5 : 8.5;
    final detailSize = compact ? 6.5 : 9.0;
    final children = <pw.Widget>[];

    if (shopName.isNotEmpty) {
      children.add(
        pw.Text(
          shopName,
          maxLines: 1,
          overflow: pw.TextOverflow.clip,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: shopSize,
            fontWeight: pw.FontWeight.bold,
            color: _ink,
          ),
        ),
      );
      children.add(pw.SizedBox(height: compact ? 1 : 2));
    }

    children.add(
      pw.Text(
        sticker.name.isEmpty ? '—' : sticker.name,
        maxLines: 2,
        overflow: pw.TextOverflow.clip,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: nameSize,
          fontWeight: pw.FontWeight.bold,
          color: _ink,
        ),
      ),
    );
    children.add(pw.SizedBox(height: compact ? 2 : 4));

    // Centred, not stretched: the surrounding column is `stretch`, which would
    // hand the barcode tight full-width constraints and override the width
    // computed for the media. `textPadding` keeps the human-readable digits
    // clear of the bars — the widget defaults it to 0, which prints them
    // touching the bar tips and hurts scanning.
    children.add(
      pw.Center(
        child: pw.BarcodeWidget(
          barcode: pw.Barcode.code128(),
          data: sticker.barcode,
          width: barcodeWidth,
          height: barcodeHeight,
          drawText: true,
          textPadding: compact ? 1.0 : 2.0,
          color: _ink,
          textStyle: pw.TextStyle(
            fontSize: compact ? 6.5 : 8,
            color: _ink,
            font: fonts.base,
          ),
        ),
      ),
    );

    final detail = sticker.detailText;
    if (detail != null) {
      children.add(pw.SizedBox(height: compact ? 1 : 3));
      children.add(
        pw.Text(
          detail,
          maxLines: 1,
          overflow: pw.TextOverflow.clip,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: detailSize,
            fontWeight: pw.FontWeight.bold,
            color: _ink,
          ),
        ),
      );
    }

    return pw.Column(
      mainAxisSize: pw.MainAxisSize.min,
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
