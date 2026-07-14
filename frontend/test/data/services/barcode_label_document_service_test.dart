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
  }) {
    return PrinterEndpoint(
      kind: PrintTransportKind.system,
      name: 'Xprinter',
      outputMode: PrinterOutputMode.pdfA4,
      labelPdfSize: size,
      labelRotationQuarterTurns: rotation,
    );
  }

  test('renders a 40x22 sticker at the exact media width', () async {
    final bytes = await service.buildLabelsPdf(
      lines: [line],
      endpoint: endpoint(BarcodeLabelPdfSize.label40x22),
      shopName: 'متجر الأمانة',
    );
    expect(bytes, isNotEmpty);
    // 40 mm → 40 * 72 / 25.4 ≈ 113.39 pt. MediaBox is greppable even compressed.
    expect(_mediaBoxWidth(bytes), closeTo(113.39, 1.0));
  });

  test('rotating 90° swaps the sticker page to portrait media', () async {
    final bytes = await service.buildLabelsPdf(
      lines: [line],
      endpoint: endpoint(BarcodeLabelPdfSize.label40x22, rotation: 1),
      shopName: 'متجر الأمانة',
    );
    // Width becomes the 22 mm side → 22 * 72 / 25.4 ≈ 62.36 pt.
    expect(_mediaBoxWidth(bytes), closeTo(62.36, 1.0));
  });

  test('renders an 80 mm roll label at the roll width', () async {
    final bytes = await service.buildLabelsPdf(
      lines: [line],
      endpoint: endpoint(BarcodeLabelPdfSize.roll80),
      shopName: 'متجر الأمانة',
    );
    expect(bytes, isNotEmpty);
    // 80 mm → 226.77 pt.
    expect(_mediaBoxWidth(bytes), closeTo(226.77, 1.0));
  });

  test('renders an A4 grid sheet', () async {
    final bytes = await service.buildLabelsPdf(
      lines: [line],
      endpoint: endpoint(BarcodeLabelPdfSize.a4),
      shopName: 'متجر الأمانة',
    );
    expect(bytes, isNotEmpty);
    // A4 width → 595.28 pt.
    expect(_mediaBoxWidth(bytes), closeTo(595.28, 1.5));
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
      endpoint: endpoint(BarcodeLabelPdfSize.label40x22),
    );
    expect(bytes, isEmpty);
  });

  test('writes sample PDFs for visual inspection when POINTY_LABEL_DUMP set', () async {
    final dumpDir = Platform.environment['POINTY_LABEL_DUMP'];
    if (dumpDir == null || dumpDir.isEmpty) {
      return;
    }
    Directory(dumpDir).createSync(recursive: true);
    for (final entry in {
      'label40x22': BarcodeLabelPdfSize.label40x22,
      'label40x22-rot90': BarcodeLabelPdfSize.label40x22,
      'roll80': BarcodeLabelPdfSize.roll80,
      'a4': BarcodeLabelPdfSize.a4,
    }.entries) {
      final rot = entry.key.contains('rot90') ? 1 : 0;
      final bytes = await service.buildLabelsPdf(
        lines: [line, line],
        endpoint: endpoint(entry.value, rotation: rot),
        shopName: 'متجر الأمانة',
      );
      File('$dumpDir/${entry.key}.pdf').writeAsBytesSync(bytes);
    }
  });
}

double _mediaBoxWidth(Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final match = RegExp(
    r'/MediaBox\s*\[\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\]',
  ).firstMatch(text);
  if (match == null) {
    throw StateError('no MediaBox found in PDF');
  }
  return double.parse(match.group(3)!) - double.parse(match.group(1)!);
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
