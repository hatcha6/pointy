import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../shared/date_formatters.dart';
import '../../shared/formatters.dart';
import '../../shared/pdf/pdf.dart';
import '../models/barcode_label.dart';
import '../models/printer_config.dart';
import 'barcode_label_calibration.dart';
import 'cups_pdf_spooler_stub.dart'
    if (dart.library.io) 'cups_pdf_spooler_io.dart';
import 'print_transport.dart';

/// Renders and prints barcode-label stickers through the PDF/document path (the
/// [PrinterOutputMode.pdfA4] output mode used by system / driver printers), the
/// same route receipts take on a driver-PDF thermal printer. This lets the very
/// same label/receipt printers that only understand their vendor PDF/graphics
/// driver — not raw ESC/POS or ZPL — print proper stickers instead of gibberish.
///
/// The page **is** the media: for [BarcodeLabelPdfSize.sticker] it is exactly
/// the die-cut label the endpoint is configured for
/// ([PrinterEndpoint.labelWidthMm] × [PrinterEndpoint.labelHeightMm]), and the
/// job asks the spooler for that same media size. Nothing is left for the driver
/// to fit, rotate or pad — see [_printPdf] for why that matters.
class BarcodeLabelDocumentService {
  const BarcodeLabelDocumentService({
    this.fontLoader = const PointyPdfFontLoader(),
  });

  final PointyPdfFontLoader fontLoader;

  Future<PrintTransportResult> printLabels({
    required List<BarcodeLabelPrintLine> lines,
    required PrinterEndpoint endpoint,
  }) async {
    try {
      final document = await buildLabelsDocument(
        lines: lines,
        endpoint: endpoint,
      );
      if (document.bytes.isEmpty) {
        return const PrintTransportResult.failure('no barcode labels to print');
      }
      return _printPdf(
        document: document,
        endpoint: endpoint,
        jobName: 'barcode-labels',
      );
    } on Object catch (error) {
      return PrintTransportResult.failure('label print failed: $error');
    }
  }

  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) {
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
    );
  }

  /// Prints a calibration sheet — a ruler or a pitch comb — through the same
  /// path a label takes, so what it measures is what a label will do.
  Future<PrintTransportResult> printCalibration({
    required PrinterEndpoint endpoint,
    required BarcodeLabelCalibrationSheet sheet,
  }) async {
    try {
      final document = await BarcodeLabelCalibrationDocument(
        endpoint: endpoint,
        fonts: await fontLoader.load(),
      ).build(sheet);
      return _printPdf(
        document: document,
        endpoint: endpoint,
        jobName: 'label-calibration',
      );
    } on Object catch (error) {
      return PrintTransportResult.failure('calibration print failed: $error');
    }
  }

  /// Builds the label sheet as PDF bytes. Returns an empty list when no line has
  /// a printable (non-empty) barcode.
  Future<Uint8List> buildLabelsPdf({
    required List<BarcodeLabelPrintLine> lines,
    required PrinterEndpoint endpoint,
  }) async {
    final document = await buildLabelsDocument(
      lines: lines,
      endpoint: endpoint,
    );
    return document.bytes;
  }

  /// Builds the label sheet together with the media size its pages were laid
  /// out for, so the print job can ask the spooler for exactly that media.
  Future<BarcodeLabelDocument> buildLabelsDocument({
    required List<BarcodeLabelPrintLine> lines,
    required PrinterEndpoint endpoint,
  }) async {
    final stickers = _expand(lines);
    if (stickers.isEmpty) {
      return BarcodeLabelDocument(bytes: Uint8List(0));
    }
    final fonts = await fontLoader.load();
    return _BarcodeLabelSheet(
      stickers: stickers,
      size: endpoint.labelPdfSize,
      stickerWidthMm: endpoint.labelWidthMm.toDouble(),
      stickerHeightMm: endpoint.labelHeightMm.toDouble(),
      stickerOffsetXMm: endpoint.labelPdfOffsetXMm.toDouble(),
      stickerOffsetYMm: endpoint.labelPdfOffsetYMm.toDouble(),
      stickerPitchMm: endpoint.labelPdfPitchMm,
      dpi: endpoint.labelDpi,
      rotationQuarterTurns: endpoint.labelRotationQuarterTurns,
      fonts: fonts,
    ).build();
  }

  /// Hands the PDF to the platform.
  ///
  /// On Linux and macOS this goes through CUPS (`lp`) with an explicit media
  /// size, because the printing plugin cannot express label media there: its
  /// Linux job builder ignores the requested page size outright (it passes a
  /// fresh `GtkPageSetup`, i.e. the locale default A4) and its macOS one marks
  /// every page wider than tall as landscape. The driver then falls back to the
  /// queue's own page — 80 × 297 mm on a typical label/receipt PPD — so one
  /// sticker came out rotated, softened by the fit-to-page upscale, and trailed
  /// by ~270 mm of blank labels. `lp -o media=Custom.WxHmm` pins the page to the
  /// sticker instead. The plugin remains the fallback (Windows, Android, and any
  /// box without a CUPS client), where the driver's own paper setting governs.
  Future<PrintTransportResult> _printPdf({
    required BarcodeLabelDocument document,
    required PrinterEndpoint endpoint,
    required String jobName,
  }) async {
    final width = document.mediaWidthMm;
    final height = document.mediaHeightMm;
    if (width != null && height != null) {
      final spooled = await spoolPdfToCups(
        bytes: document.bytes,
        queue: endpoint.address,
        jobName: jobName,
        mediaWidthMm: width,
        mediaHeightMm: height,
        // Die-cut stock only: on a continuous roll there is no gap to seek and
        // the printer would feed until it times out.
        registerLabelTop: endpoint.labelPdfSize == BarcodeLabelPdfSize.sticker,
      );
      if (spooled.succeeded) {
        return const PrintTransportResult.success('barcode labels printed');
      }
      if (spooled.supported) {
        return PrintTransportResult.failure(
          'label print failed: ${spooled.error}',
        );
      }
    }

    // On macOS the plugin fallback below is not a fallback, it is a hang. Its
    // print operation runs modally on the main thread and blocks on a semaphore
    // inside `knowsPageRange`, waiting for the Dart `onLayout` reply — which can
    // only be delivered on that same main thread. The app freezes with no error
    // and has to be killed. (Observed under the App Sandbox, which forbids
    // exec'ing `lp` and so sent the label down this path; the deadlock itself is
    // the plugin's, not the sandbox's.) A named failure the caller can show
    // beats a frozen till.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      return const PrintTransportResult.failure(
        'label print failed: CUPS is unavailable — on macOS labels must spool '
        'through `lp` (an unsandboxed build), because the document print '
        'fallback deadlocks',
      );
    }

    final format = document.platformPageFormat;
    final printer = await _resolvePrinter(endpoint);
    final printed = printer != null
        ? await Printing.directPrintPdf(
            printer: printer,
            name: jobName,
            format: format,
            usePrinterSettings: true,
            onLayout: (_) async => document.bytes,
          )
        : await Printing.layoutPdf(
            name: jobName,
            format: format,
            usePrinterSettings: true,
            onLayout: (_) async => document.bytes,
          );
    return printed
        ? const PrintTransportResult.success('barcode labels printed')
        : const PrintTransportResult.failure('document print canceled');
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
      final barcode = line.label.barcode
          .replaceAll(RegExp(r'[\r\n]'), '')
          .trim();
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

/// A rendered label sheet plus the media its pages were laid out for.
/// [mediaWidthMm]/[mediaHeightMm] are null only for the A4 grid, whose media is
/// the standard sheet every driver already knows.
class BarcodeLabelDocument {
  const BarcodeLabelDocument({
    required this.bytes,
    this.mediaWidthMm,
    this.mediaHeightMm,
  });

  final Uint8List bytes;
  final double? mediaWidthMm;
  final double? mediaHeightMm;

  /// Page-format hint for the printing-plugin fallback. The true geometry is
  /// baked into the PDF bytes.
  PdfPageFormat get platformPageFormat {
    final width = mediaWidthMm;
    final height = mediaHeightMm;
    if (width == null || height == null) {
      return PdfPageFormat.a4;
    }
    return PdfPageFormat(width * PdfPageFormat.mm, height * PdfPageFormat.mm);
  }
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

  String? get expiryLine => expiryText == null ? null : 'ينتهي $expiryText';
}

/// Lays label stickers out on the page. Thermal/label heads are 1-bit, so
/// everything is drawn in pure black on a bold base to survive a low-dpi head.
class _BarcodeLabelSheet {
  _BarcodeLabelSheet({
    required this.stickers,
    required this.size,
    required this.stickerWidthMm,
    required this.stickerHeightMm,
    required this.stickerOffsetXMm,
    required this.stickerOffsetYMm,
    required this.stickerPitchMm,
    required this.dpi,
    required this.rotationQuarterTurns,
    required this.fonts,
  });

  final List<_LabelSticker> stickers;
  final BarcodeLabelPdfSize size;
  final double stickerWidthMm;
  final double stickerHeightMm;
  final double stickerOffsetXMm;
  final double stickerOffsetYMm;
  final double stickerPitchMm;
  final int dpi;
  final int rotationQuarterTurns;
  final PointyPdfFonts fonts;

  static const _ink = PdfColor.fromInt(0xff000000);
  static const double _mm = PdfPageFormat.mm;

  /// Die-cut sticker sizes outside this range are a mis-entered setting (or a
  /// legacy 0) rather than real media; clamping keeps the page printable.
  static const _minStickerMm = 10.0;
  static const _maxStickerMm = 210.0;

  int get _rotation => ((rotationQuarterTurns % 4) + 4) % 4;

  Future<BarcodeLabelDocument> build() {
    return switch (size) {
      BarcodeLabelPdfSize.sticker => _buildStickerPages(),
      BarcodeLabelPdfSize.roll50 => _buildRollPages(50),
      BarcodeLabelPdfSize.roll70 => _buildRollPages(70),
      BarcodeLabelPdfSize.roll80 => _buildRollPages(80),
      BarcodeLabelPdfSize.a4 => _buildA4Grid(),
    };
  }

  pw.Document _newDocument() => pw.Document(
    title: 'ملصقات الباركود',
    creator: 'دفتر',
    subject: 'barcode labels',
  );

  pw.ThemeData _theme() {
    return pw.ThemeData.withFont(
      base: fonts.bold,
      bold: fonts.bold,
      fontFallback: fonts.fallback,
    );
  }

  /// Die-cut stickers, laid out as a continuous strip.
  ///
  /// The page is the label as loaded in the printer, plus the run-up from the
  /// printer's origin to where the label actually sits
  /// ([PrinterEndpoint.labelPdfOffsetXMm] across the head and
  /// [PrinterEndpoint.labelPdfOffsetYMm] down the feed — a driver starts every
  /// page at its first dot, which is rarely a corner of the sticker).
  ///
  /// With [PrinterEndpoint.labelPdfPitchMm] set, a whole run goes on **one**
  /// page, each sticker placed a pitch below the last, instead of one page per
  /// sticker. A page boundary is where registration is lost: the printer only
  /// re-registers between pages, and a printer whose feed runs even a
  /// millimetre short of the page it was given creeps down the roll until
  /// labels straddle two stickers. Inside a single page the positions are ours,
  /// exact to the dot, and the feed motor never gets a say. Left at zero, the
  /// printer gets a page per sticker and is trusted to find each gap itself.
  ///
  /// Rotation turns the artwork **inside** the sticker — the media can't turn
  /// with it, so swapping the page dimensions (what this used to do) only ever
  /// asked the driver for paper the printer doesn't have.
  Future<BarcodeLabelDocument> _buildStickerPages() async {
    final widthMm = stickerWidthMm.clamp(_minStickerMm, _maxStickerMm);
    final heightMm = stickerHeightMm.clamp(_minStickerMm, _maxStickerMm);
    final offsetXMm = stickerOffsetXMm.clamp(0.0, _maxStickerMm);
    final offsetYMm = stickerOffsetYMm.clamp(0.0, _maxStickerMm);
    // Quiet zone. Across the head registration is exact, so 1.2 mm is plenty —
    // the old 1.5 mm was label the shop paid for and could not use. Down the
    // feed it is not exact (that is the whole reason the pitch has to be
    // calibrated), so the vertical margin stays wide enough to absorb the
    // registration this printer actually delivers. Cutting it to 1.0 mm to win
    // 4% of a 23 mm sticker was a bad trade: it spends the tolerance that keeps
    // the top line off the die-cut edge.
    final marginXMm = math.min(1.2, widthMm * 0.05);
    final marginYMm = math.min(1.8, heightMm * 0.08);
    // How far apart the stickers repeat on the roll. Zero means "one page per
    // label": the printer seeks the gap between pages and re-registers every
    // sticker, which is what gap-sensing label media is for. Set it only for a
    // printer that can't do that, where a strip laid out at a known pitch is
    // the only way to keep a long run aligned.
    final stripMode = stickerPitchMm > 0;
    final pitchMm = stripMode
        ? math.max(heightMm, stickerPitchMm)
        : heightMm + offsetYMm;
    final contentWidth = (widthMm - 2 * marginXMm) * _mm;
    final contentHeight = (heightMm - 2 * marginYMm) * _mm;
    // Odd quarter-turns lay the card out across the page's *other* axis.
    final swap = _rotation.isOdd;
    final cardWidth = swap ? contentHeight : contentWidth;
    final cardHeight = swap ? contentWidth : contentHeight;

    final pageWidthMm = widthMm + offsetXMm;
    // CUPS custom media tops out at 8500 pt (~3 m), so a long run spills onto
    // further strips — each costing one re-registration, once every hundred-odd
    // labels rather than every label. Every page in a job must be the same size
    // (CUPS takes one media size per job), so the run is split into equal
    // strips: a short tail would otherwise be padded out to a full strip in
    // blank labels.
    final maxPerStrip = stripMode
        ? math.max(1, math.min(100, (2800 / pitchMm).floor()))
        : 1;
    final stripCount = (stickers.length / maxPerStrip).ceil();
    final perStrip = (stickers.length / stripCount).ceil();

    // A strip is a WHOLE number of label pitches, so the roll ends a job in the
    // same phase it began: the head is left the same distance from the next
    // sticker's leading edge as it was at the start, and the job after this one
    // lands on the labels without anyone touching FEED.
    //
    // The run-up ([stickerOffsetYMm]) is spent *inside* the first pitch, never
    // added on top of it. Added on top — which is what this used to do — every
    // job overshot by exactly that run-up and the print walked one offset down
    // the roll per job. The ceiling covers the rare geometry whose sticker plus
    // run-up is longer than one pitch, at the cost of a blank label.
    final minStripHeightMm = offsetYMm + (perStrip - 1) * pitchMm + heightMm;
    final stripHeightMm = stripMode
        ? (minStripHeightMm / pitchMm).ceil() * pitchMm
        : offsetYMm + heightMm;

    final pdf = _newDocument();
    for (var start = 0; start < stickers.length; start += perStrip) {
      final chunk = stickers.sublist(
        start,
        math.min(start + perStrip, stickers.length),
      );
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(pageWidthMm * _mm, stripHeightMm * _mm),
          margin: pw.EdgeInsets.zero,
          theme: _theme(),
          textDirection: pw.TextDirection.rtl,
          build: (context) => pw.Stack(
            children: [
              for (var i = 0; i < chunk.length; i++)
                pw.Positioned(
                  // Everything left of and above a sticker is run-up over the
                  // liner (or thin air); the gap after it is the pitch's tail.
                  top: (offsetYMm + i * pitchMm) * _mm,
                  right: 0,
                  child: pw.SizedBox(
                    width: widthMm * _mm,
                    height: heightMm * _mm,
                    child: pw.Center(
                      child: pw.Transform.rotateBox(
                        angle: _rotation * (math.pi / 2),
                        child: _card(
                          chunk[i],
                          cardWidth: cardWidth,
                          cardHeight: cardHeight,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return BarcodeLabelDocument(
      bytes: await pdf.save(),
      mediaWidthMm: pageWidthMm,
      mediaHeightMm: stripHeightMm,
    );
  }

  /// One sticker per continuous-roll page: fixed width, content-measured height
  /// (no wasted tail). Every page gets the tallest measured height so the whole
  /// job has a single media size to ask the spooler for. Rotation only flips
  /// (180°) here — a roll's width already equals the label width, so 90°/270°
  /// would not fit the media.
  Future<BarcodeLabelDocument> _buildRollPages(double widthMm) async {
    const marginMm = 2.0;
    final contentWidth = (widthMm - 2 * marginMm) * _mm;
    final cardHeight = widthMm * 0.62 * _mm;
    final pageHeight = cardHeight + 2 * marginMm * _mm;

    final pdf = _newDocument();
    for (final sticker in stickers) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(widthMm * _mm, pageHeight),
          margin: const pw.EdgeInsets.all(marginMm * _mm),
          theme: _theme(),
          textDirection: pw.TextDirection.rtl,
          build: (context) {
            final card = _card(
              sticker,
              cardWidth: contentWidth,
              cardHeight: cardHeight,
            );
            return _rotation == 2
                ? pw.Transform.rotateBox(angle: math.pi, child: card)
                : card;
          },
        ),
      );
    }
    return BarcodeLabelDocument(
      bytes: await pdf.save(),
      mediaWidthMm: widthMm,
      mediaHeightMm: pageHeight / _mm,
    );
  }

  /// Tiles die-cut stickers into a grid across A4 sheets (the Avery-style label
  /// sheet case), paginating automatically. Thin cut guides frame each cell.
  Future<BarcodeLabelDocument> _buildA4Grid() async {
    final cellWidthMm = stickerWidthMm.clamp(_minStickerMm, _maxStickerMm);
    final cellHeightMm = stickerHeightMm.clamp(_minStickerMm, _maxStickerMm);
    const gapMm = 2.0;
    final paddingMm = math.min(1.0, math.min(cellWidthMm, cellHeightMm) * 0.05);
    final cardWidth = (cellWidthMm - 2 * paddingMm) * _mm;
    final cardHeight = (cellHeightMm - 2 * paddingMm) * _mm;

    final cells = <pw.Widget>[
      for (final sticker in stickers)
        pw.Container(
          width: cellWidthMm * _mm,
          height: cellHeightMm * _mm,
          padding: pw.EdgeInsets.all(paddingMm * _mm),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: _ink, width: 0.3),
          ),
          child: () {
            final card = _card(
              sticker,
              cardWidth: cardWidth,
              cardHeight: cardHeight,
            );
            return _rotation == 2
                ? pw.Transform.rotateBox(angle: math.pi, child: card)
                : card;
          }(),
        ),
    ];

    final pdf = _newDocument();
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
    return BarcodeLabelDocument(bytes: await pdf.save());
  }

  /// The sticker face: product name, barcode (with human-readable digits) and,
  /// when the line asks for them, the price and an expiry date. RTL, all pure
  /// black.
  ///
  /// The name and the price are the two things read from arm's length — off a
  /// shelf, at a glance — so they are set in the same face at the same size and
  /// take an equal share of the card. Nothing else competes with them: the shop
  /// already owns the shelf the sticker is on, so its name is not repeated here.
  ///
  /// Every row is a **fixed** box, the boxes together fill the card exactly, and
  /// each row scales only its own text down to fit. Nothing scales the card as a
  /// whole: a card-wide scale factor is what used to shrink the type below what
  /// a 203-dpi head can hold together (the soft, thin look next to a receipt)
  /// and it would also drag the barcode off the printer's dot grid.
  ///
  /// A sticker with no footer hands that share to the name and the bars rather
  /// than leaving the label part empty.
  ///
  /// The **bars** are the one row that flexes: every other row is a fixed share
  /// of the card, and the symbol takes whatever is left, so nothing here can
  /// change how tall the sticker is. They are also the row that can best afford
  /// to give — a scanner decodes module *widths*, and bar height buys only
  /// aiming tolerance, which 8 mm of bar still has at counter range.
  pw.Widget _card(
    _LabelSticker sticker, {
    required double cardWidth,
    required double cardHeight,
  }) {
    final hasFooter = sticker.priceText != null || sticker.expiryLine != null;
    final name = sticker.name.isEmpty ? '\u2014' : sticker.name;

    // The one size the name and the price are both set at.
    final headlineFontSize = cardHeight * (hasFooter ? 0.15 : 0.17);
    // A name too long for two lines is set smaller until it fits, instead of
    // being clipped mid-word.
    final nameLines = (_estimatedWidth(name, headlineFontSize) / cardWidth)
        .ceil();
    final nameFontSize = nameLines <= 2
        ? headlineFontSize
        : headlineFontSize * 2 / nameLines;

    // How tall the barcode digits themselves come out on paper — the figures,
    // not a line of text; see [_digits]. Plus the air that keeps them clear of
    // the bars above. A narrow card may set them smaller than this, and then
    // this is all the bars give up.
    final digitsHeight = cardHeight * 0.1;
    final digitsGap = cardHeight * 0.03;
    final footerHeight = hasFooter ? headlineFontSize * 1.34 : 0.0;
    final footer = _footer(sticker, fontSize: headlineFontSize);

    // Bars wider than ~60 mm buy nothing but ink: a scanner needs module width,
    // not overall length.
    final modules = _moduleCount(sticker.barcode);
    final barcodeWidth = _snappedBarcodeWidth(
      modules,
      math.min(cardWidth, 60 * _mm),
    );

    return pw.SizedBox(
      width: cardWidth,
      height: cardHeight,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // The name takes exactly the one or two lines it needs — never a
          // fixed box it has to be shrunk into, and never a fixed box it leaves
          // half empty. Whatever it doesn't use goes to the bars below.
          pw.Text(
            name,
            maxLines: 2,
            overflow: pw.TextOverflow.clip,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: nameFontSize,
              fontWeight: pw.FontWeight.bold,
              color: _ink,
            ),
          ),
          pw.Expanded(
            child: pw.Center(
              child: pw.SizedBox(
                width: barcodeWidth,
                child: modules <= 0
                    ? pw.BarcodeWidget(
                        barcode: pw.Barcode.code128(),
                        data: sticker.barcode,
                        drawText: false,
                        color: _ink,
                      )
                    : _DotSnappedBarcode(
                        data: sticker.barcode,
                        modules: modules,
                        dpi: dpi <= 0 ? 203 : dpi,
                        color: _ink,
                      ),
              ),
            ),
          ),
          _digits(
            sticker.barcode,
            height: digitsHeight,
            width: cardWidth,
            gap: digitsGap,
          ),
          if (footer != null)
            _row(height: footerHeight, width: cardWidth, child: footer),
        ],
      ),
    );
  }

  /// Roughly how wide [text] sets at [fontSize] — enough to decide whether the
  /// product name needs a second line.
  ///
  /// Exact metrics would need the document's own `PdfFont`, which only exists
  /// inside a page's build, and would still misjudge Arabic: the metrics table
  /// lists isolated glyphs, while what prints are the narrower joined forms. So
  /// this errs wide, and guessing wrong only costs the line the row's own
  /// scale-to-fit would have taken back anyway.
  double _estimatedWidth(String text, double fontSize) {
    var ems = 0.0;
    for (final rune in text.runes) {
      ems += rune == 0x20 ? 0.28 : 0.55;
    }
    return ems * fontSize;
  }

  /// One fixed-height row of the card. The text inside is laid out at the card's
  /// full width — so it wraps rather than running off — then scaled down only if
  /// it still overflows its own row.
  pw.Widget _row({
    required double height,
    required double width,
    required pw.Widget child,
  }) {
    return pw.SizedBox(
      height: height,
      child: pw.FittedBox(
        fit: pw.BoxFit.scaleDown,
        alignment: pw.Alignment.center,
        child: pw.SizedBox(width: width, child: child),
      ),
    );
  }

  /// The human-readable barcode: the fallback for when the bars won't scan and
  /// someone has to read the number off the sticker and key it in.
  ///
  /// [height] is what the digits *measure on paper*, not the row they sit in.
  /// The two used to be confused, and the digits lost: a line of text is sized
  /// to the face's ascender and descender, which for this one is 1.5 em, while
  /// digits — no ascenders, no descenders — fill only 0.72 em of it. Asking for
  /// a row and setting text at 85% of it therefore printed figures barely half
  /// the row's height: eight dots on the shop's 23 mm roll, which is the least
  /// a 203-dpi head can form a digit out of at all, and not reliably legible.
  ///
  /// So the size is solved from the face's own figure height, and `tightBounds`
  /// makes the row the height of the glyphs rather than of a line — which is
  /// what makes [height] exactly what the printer lays down, and what makes
  /// this row cost the bars only what the digits actually use. [gap] is the air
  /// above them, keeping them clear of the bars.
  ///
  /// A number too long to set that tall takes [width] as its limit instead and
  /// comes out smaller, but whole — and its row shrinks with it, so the bars
  /// keep the difference. It used to come out **clipped**: a row can only scale
  /// down text that overflows its own box, and this one is handed the card's
  /// full width to lay out in, so a long code simply ran off the end and lost
  /// its last digits with nothing to show for it. A partial number is worse
  /// than a small one — it is a number someone will key in and get the wrong
  /// product — and on a quarter-turned sticker, where the card is as narrow as
  /// the label is tall, it was every code of ordinary length.
  pw.Widget _digits(
    String barcode, {
    required double height,
    required double width,
    required double gap,
  }) {
    return pw.Builder(
      builder: (context) {
        // Metrics come back per em, so each one divides into the room there is
        // to give the size that exactly fills it. `height` spans the glyphs'
        // own top and bottom — the figure height this string really has, not a
        // line's — and `advanceWidth` is the width it sets to.
        final metrics = fonts.base.getFont(context).stringMetrics(barcode);
        final byHeight = metrics.height > 0 ? height / metrics.height : height;
        final byWidth = metrics.advanceWidth > 0
            ? width / metrics.advanceWidth
            : byHeight;
        return pw.Padding(
          padding: pw.EdgeInsets.only(top: gap),
          child: pw.Text(
            barcode,
            tightBounds: true,
            maxLines: 1,
            overflow: pw.TextOverflow.clip,
            textAlign: pw.TextAlign.center,
            textDirection: pw.TextDirection.ltr,
            style: pw.TextStyle(
              fontSize: math.min(byHeight, byWidth),
              color: _ink,
              font: fonts.base,
            ),
          ),
        );
      },
    );
  }

  /// Price (and expiry, when the line carries one). The price is set in the
  /// name's face at the name's size — [fontSize] is the very number the name
  /// used — so the two read as one pair from across an aisle.
  pw.Widget? _footer(_LabelSticker sticker, {required double fontSize}) {
    final price = sticker.priceText;
    final expiry = sticker.expiryLine;
    if (price == null && expiry == null) {
      return null;
    }
    final priceStyle = pw.TextStyle(
      fontSize: fontSize,
      fontWeight: pw.FontWeight.bold,
      color: _ink,
    );
    if (price == null || expiry == null) {
      return pw.Text(
        (price ?? expiry)!,
        maxLines: 1,
        overflow: pw.TextOverflow.clip,
        textAlign: pw.TextAlign.center,
        style: priceStyle,
      );
    }
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Text(
          price,
          maxLines: 1,
          overflow: pw.TextOverflow.clip,
          style: priceStyle,
        ),
        pw.SizedBox(width: 4),
        pw.Text(
          expiry,
          maxLines: 1,
          overflow: pw.TextOverflow.clip,
          style: pw.TextStyle(
            fontSize: fontSize * 0.6,
            fontWeight: pw.FontWeight.bold,
            color: _ink,
          ),
        ),
      ],
    );
  }

  double _snappedBarcodeWidth(int modules, double available) {
    if (modules <= 0) {
      return available;
    }
    final dotsPerPoint = (dpi <= 0 ? 203 : dpi) / PdfPageFormat.inch;
    final dotsPerModule = available * dotsPerPoint / modules;
    if (dotsPerModule < 2) {
      // Dense data on a small label: there is no room to round down without
      // throwing away most of the symbol (rounding 1.8 dots down to 1 halves
      // it), and a sub-2-dot module is at the head's limit anyway. Use every
      // millimetre the label has instead.
      return available;
    }
    return modules * dotsPerModule.floorToDouble() / dotsPerPoint;
  }

  /// Number of Code 128 modules [data] encodes to, measured off a trial layout:
  /// the narrowest bar in any 1D symbology is exactly one module wide, so the
  /// probe width divided by that bar gives the module count. (The `Barcode1D`
  /// class that would answer directly isn't exported by the barcode package.)
  int _moduleCount(String data) {
    const probeWidth = 1000.0;
    try {
      final bars = pw.Barcode.code128()
          .make(data, width: probeWidth, height: 10)
          .whereType<pw.BarcodeBar>()
          .where((bar) => bar.width > 0);
      if (bars.isEmpty) {
        return 0;
      }
      final module = bars.map((bar) => bar.width).reduce(math.min);
      return module <= 0 ? 0 : (probeWidth / module).round();
    } on Object {
      // Data this symbology can't express: let the widget report it as it will.
      return 0;
    }
  }
}

/// Code 128 bars drawn on whole printer dots.
///
/// [pw.BarcodeWidget] places bars at whatever fractional point the layout lands
/// on, and a 203-dpi head can only round that to the nearest dot — so a nominal
/// 2-dot module prints as a mix of 1-, 2- and 3-dot bars, which is what a
/// scanner reads as a fuzzy, hard-to-decode symbol. Bars here are snapped to the
/// device grid in page coordinates: every module comes out the same whole number
/// of dots wide. (Under a rotation or a scale-down the canvas transform moves
/// the grid, and this degrades to the same fractional placement as before.)
class _DotSnappedBarcode extends pw.Widget {
  _DotSnappedBarcode({
    required this.data,
    required this.modules,
    required this.dpi,
    required this.color,
  });

  final String data;
  final int modules;
  final int dpi;
  final PdfColor color;

  @override
  void layout(
    pw.Context context,
    pw.BoxConstraints constraints, {
    bool parentUsesSize = false,
  }) {
    box = PdfRect.fromPoints(PdfPoint.zero, constraints.biggest);
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final rect = box;
    if (rect == null || modules <= 0) {
      return;
    }
    final dotsPerPoint = dpi / PdfPageFormat.inch;
    final dotsPerModule = rect.width * dotsPerPoint / modules;
    // Below two dots a module can't be rounded to the grid without losing most
    // of the symbol, so a dense code on a small label keeps its exact width and
    // lets the head round each bar (see _snappedBarcodeWidth).
    final snapToDots = dotsPerModule >= 2;
    final moduleWidth = snapToDots
        ? dotsPerModule.floorToDouble() / dotsPerPoint
        : rect.width / modules;

    // Widgets paint in their parent's coordinate space, so the printer's dot
    // grid has to be found through the canvas transform. Follow the image of
    // our own x axis: upright or quarter-turned it still lands on a page axis
    // (only the sign and which axis change), and the bars can be pinned to whole
    // dots along it. Under a scale it no longer maps to whole dots at all — the
    // bars stay evenly sized, they just can't be pinned.
    final matrix = context.canvas.getTransform();
    final alongX = matrix.entry(0, 0);
    final alongY = matrix.entry(1, 0);
    bool isUnit(double value) => (value.abs() - 1).abs() < 1e-6;
    bool isZero(double value) => value.abs() < 1e-6;
    final double scale;
    final double origin;
    if (isZero(alongY) && isUnit(alongX)) {
      scale = alongX;
      origin = matrix.entry(0, 3);
    } else if (isZero(alongX) && isUnit(alongY)) {
      scale = alongY;
      origin = matrix.entry(1, 3);
    } else {
      scale = 0;
      origin = 0;
    }
    var left = rect.left;
    if (scale != 0 && snapToDots) {
      final absolute = origin + left * scale;
      final snapped = (absolute * dotsPerPoint).roundToDouble() / dotsPerPoint;
      left = (snapped - origin) / scale;
    }

    // Laying the symbol out `modules` points wide makes every element's left
    // and width an exact module count.
    for (final element in pw.Barcode.code128().make(
      data,
      width: modules.toDouble(),
      height: 1,
    )) {
      if (element is! pw.BarcodeBar || !element.black || element.width <= 0) {
        continue;
      }
      context.canvas.drawRect(
        left + element.left.roundToDouble() * moduleWidth,
        rect.bottom,
        element.width.roundToDouble() * moduleWidth,
        rect.height,
      );
    }
    context.canvas
      ..setFillColor(color)
      ..fillPath();
  }
}
