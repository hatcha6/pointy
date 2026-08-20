import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/barcode_label.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/barcode_label_document_service.dart';
import 'package:pointy_frontend/src/shared/pdf/pointy_pdf_fonts.dart';

void main() {
  const service = BarcodeLabelDocumentService(fontLoader: _FileFontLoader());

  const line = BarcodeLabelPrintLine(
    label: BarcodeLabelDraft(
      displayName: 'شامبو للأطفال 400 مل',
      productName: 'شامبو للأطفال 400 مل',
      sku: 'SKU-42',
      barcode: '6224000123456',
      unitPrice: 12.5,
    ),
    copies: 2,
    includePrice: true,
  );

  PrinterEndpoint endpoint(
    BarcodeLabelPdfSize size, {
    int rotation = 0,
    int widthMm = 40,
    int heightMm = 25,
    int offsetXMm = 0,
    int offsetYMm = 0,
    double pitchMm = 0,
  }) {
    return PrinterEndpoint(
      kind: PrintTransportKind.system,
      name: 'Xprinter',
      outputMode: PrinterOutputMode.pdfA4,
      labelWidthMm: widthMm,
      labelHeightMm: heightMm,
      labelPdfSize: size,
      labelPdfOffsetXMm: offsetXMm,
      labelPdfOffsetYMm: offsetYMm,
      labelPdfPitchMm: pitchMm,
      labelRotationQuarterTurns: rotation,
    );
  }

  test('a die-cut sticker page is exactly the configured media', () async {
    final document = await service.buildLabelsDocument(
      lines: [line],
      endpoint: endpoint(BarcodeLabelPdfSize.sticker),
      shopName: 'متجر الأمانة',
    );
    expect(document.bytes, isNotEmpty);
    // 40 mm → 40 * 72 / 25.4 ≈ 113.39 pt, 25 mm → 70.87 pt. The MediaBox is
    // greppable even compressed.
    expect(_mediaBox(document.bytes), _isSize(113.39, 70.87));
    // The spooler is asked for that same media, so the driver has nothing left
    // to fit, rotate, or pad with blank labels.
    expect(document.mediaWidthMm, 40);
    expect(document.mediaHeightMm, 25);
  });

  test('a non-standard sticker size is honoured', () async {
    final document = await service.buildLabelsDocument(
      lines: [line],
      endpoint: endpoint(
        BarcodeLabelPdfSize.sticker,
        widthMm: 58,
        heightMm: 40,
      ),
    );
    expect(_mediaBox(document.bytes), _isSize(164.41, 113.39));
    expect(document.mediaWidthMm, 58);
    expect(document.mediaHeightMm, 40);
  });

  test('an offset widens the page so the artwork reaches the label', () async {
    // A driver starts every page at the head's first dot. When the roll sits
    // further in than that, the page has to span the run-up or the sticker
    // prints half off the label.
    final document = await service.buildLabelsDocument(
      lines: [line],
      endpoint: endpoint(BarcodeLabelPdfSize.sticker, offsetXMm: 20),
      shopName: 'متجر الأمانة',
    );
    // 20 mm run-up + 40 mm sticker = 60 mm → 170.08 pt, height unchanged.
    expect(_mediaBox(document.bytes), _isSize(170.08, 70.87));
    expect(document.mediaWidthMm, 60);
    expect(document.mediaHeightMm, 25);
  });

  test('offsets pad the page on both axes to reach the sticker', () async {
    final document = await service.buildLabelsDocument(
      lines: [line],
      endpoint: endpoint(
        BarcodeLabelPdfSize.sticker,
        offsetXMm: 20,
        offsetYMm: 5,
      ),
      shopName: 'متجر الأمانة',
    );
    // 20 + 40 mm across → 170.08 pt; 5 + 25 mm down → 85.04 pt.
    expect(_mediaBox(document.bytes), _isSize(170.08, 85.04));
    expect(document.mediaWidthMm, 60);
    expect(document.mediaHeightMm, 30);
  });

  test('a pitch lays the run out as one strip, not a page each', () async {
    // Registration is only ever lost at a page boundary, so a run of stickers
    // spaced by a known pitch belongs on a single page.
    final document = await service.buildLabelsDocument(
      lines: [
        BarcodeLabelPrintLine(label: line.label, copies: 4, includePrice: true),
      ],
      endpoint: endpoint(
        BarcodeLabelPdfSize.sticker,
        offsetYMm: 1,
        pitchMm: 26.9,
      ),
      shopName: 'متجر الأمانة',
    );
    // One page: 1 mm run-up + 4 × 26.9 mm → 108.6 mm → 307.8 pt.
    expect(_pageCount(document.bytes), 1);
    expect(_mediaBox(document.bytes).height, closeTo(307.8, 1));
    expect(document.mediaHeightMm, closeTo(108.6, 0.01));
  });

  test('a run longer than one strip splits into equal strips', () async {
    // CUPS takes one media size per job, so an under-filled tail strip would
    // print as blank labels.
    final document = await service.buildLabelsDocument(
      lines: [
        BarcodeLabelPrintLine(
          label: line.label,
          copies: 150,
          includePrice: true,
        ),
      ],
      endpoint: endpoint(BarcodeLabelPdfSize.sticker, pitchMm: 26.9),
    );
    final pages = _pageCount(document.bytes);
    expect(pages, greaterThan(1));
    // Equal strips: 150 across 2 strips → 75 each, so no blank tail.
    expect(document.mediaHeightMm, closeTo(75 * 26.9, 0.01));
  });

  test('without a pitch each sticker gets its own page', () async {
    final document = await service.buildLabelsDocument(
      lines: [
        BarcodeLabelPrintLine(label: line.label, copies: 3, includePrice: true),
      ],
      endpoint: endpoint(BarcodeLabelPdfSize.sticker),
    );
    expect(_pageCount(document.bytes), 3);
    expect(document.mediaHeightMm, 25);
  });

  test('rotating the sticker keeps the page on the same media', () async {
    // The label roll cannot turn with the artwork: rotation turns the content
    // inside the sticker, it never asks the printer for paper it doesn't have.
    for (final rotation in [1, 2, 3]) {
      final document = await service.buildLabelsDocument(
        lines: [line],
        endpoint: endpoint(BarcodeLabelPdfSize.sticker, rotation: rotation),
        shopName: 'متجر الأمانة',
      );
      expect(
        _mediaBox(document.bytes),
        _isSize(113.39, 70.87),
        reason: 'rotation $rotation must not resize the media',
      );
      expect(document.mediaWidthMm, 40);
      expect(document.mediaHeightMm, 25);
    }
  });

  test('rotation changes the rendered sticker', () async {
    final upright = await service.buildLabelsPdf(
      lines: [line],
      endpoint: endpoint(BarcodeLabelPdfSize.sticker),
      shopName: 'متجر الأمانة',
    );
    final turned = await service.buildLabelsPdf(
      lines: [line],
      endpoint: endpoint(BarcodeLabelPdfSize.sticker, rotation: 1),
      shopName: 'متجر الأمانة',
    );
    expect(turned, isNot(equals(upright)));
  });

  test('a roll label gets a single finite media height', () async {
    final document = await service.buildLabelsDocument(
      lines: [line],
      endpoint: endpoint(BarcodeLabelPdfSize.roll80),
      shopName: 'متجر الأمانة',
    );
    expect(document.bytes, isNotEmpty);
    // 80 mm → 226.77 pt wide, with a measured (never infinite) height.
    expect(_mediaBox(document.bytes).width, closeTo(226.77, 1));
    expect(document.mediaWidthMm, 80);
    expect(document.mediaHeightMm, isNotNull);
    expect(document.mediaHeightMm, greaterThan(0));
    expect(document.mediaHeightMm, lessThan(200));
  });

  test('renders an A4 grid sheet on standard media', () async {
    final document = await service.buildLabelsDocument(
      lines: [line],
      endpoint: endpoint(BarcodeLabelPdfSize.a4),
      shopName: 'متجر الأمانة',
    );
    expect(document.bytes, isNotEmpty);
    // A4 width → 595.28 pt. A sheet needs no custom media.
    expect(_mediaBox(document.bytes).width, closeTo(595.28, 1.5));
    expect(document.mediaWidthMm, isNull);
    expect(document.mediaHeightMm, isNull);
  });

  test('skips lines without a barcode', () async {
    final bytes = await service.buildLabelsPdf(
      lines: const [
        BarcodeLabelPrintLine(
          label: BarcodeLabelDraft(
            displayName: 'بلا باركود',
            sku: '',
            barcode: '   ',
            unitPrice: 1,
          ),
          copies: 3,
        ),
      ],
      endpoint: endpoint(BarcodeLabelPdfSize.sticker),
    );
    expect(bytes, isEmpty);
  });

  test(
    'writes sample PDFs for visual inspection when POINTY_LABEL_DUMP set',
    () async {
      final dumpDir = Platform.environment['POINTY_LABEL_DUMP'];
      if (dumpDir == null || dumpDir.isEmpty) {
        return;
      }
      Directory(dumpDir).createSync(recursive: true);
      final samples = <String, PrinterEndpoint>{
        'sticker40x25': endpoint(BarcodeLabelPdfSize.sticker),
        'sticker40x25-rot90': endpoint(
          BarcodeLabelPdfSize.sticker,
          rotation: 1,
        ),
        'sticker40x25-rot180': endpoint(
          BarcodeLabelPdfSize.sticker,
          rotation: 2,
        ),
        'sticker50x30': endpoint(
          BarcodeLabelPdfSize.sticker,
          widthMm: 50,
          heightMm: 30,
        ),
        'roll80': endpoint(BarcodeLabelPdfSize.roll80),
        'a4': endpoint(BarcodeLabelPdfSize.a4),
      };
      for (final entry in samples.entries) {
        final bytes = await service.buildLabelsPdf(
          lines: [line, line],
          endpoint: entry.value,
          shopName: 'متجر الأمانة',
        );
        File('$dumpDir/${entry.key}.pdf').writeAsBytesSync(bytes);
      }
    },
  );
}

/// Page size in points, read off the PDF's own `/MediaBox`.
class _PageSize {
  const _PageSize(this.width, this.height);

  final double width;
  final double height;

  @override
  String toString() =>
      '${width.toStringAsFixed(2)}×${height.toStringAsFixed(2)}pt';
}

Matcher _isSize(double width, double height) => predicate<_PageSize>(
  (size) => (size.width - width).abs() < 1 && (size.height - height).abs() < 1,
  'a page of ${width.toStringAsFixed(2)}×${height.toStringAsFixed(2)}pt',
);

int _pageCount(Uint8List bytes) =>
    RegExp(r'/Type\s*/Page[^s]').allMatches(String.fromCharCodes(bytes)).length;

_PageSize _mediaBox(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final match = RegExp(
    r'/MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\]',
  ).firstMatch(text);
  if (match == null) {
    throw StateError('no MediaBox found in PDF');
  }
  return _PageSize(
    double.parse(match.group(3)!) - double.parse(match.group(1)!),
    double.parse(match.group(4)!) - double.parse(match.group(2)!),
  );
}

/// Loads the real bundled Arabic TTFs straight off disk so the rendered sample
/// PDFs show correct Arabic glyphs (the default test loader is Latin-only).
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
