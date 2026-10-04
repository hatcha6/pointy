import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/barcode_label.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/barcode_label_calibration.dart';
import 'package:pointy_frontend/src/data/services/barcode_label_document_service.dart';
import 'package:pointy_frontend/src/shared/pdf/pointy_pdf_fonts.dart';

void main() {
  // The geometry this shop's HPRT LPQ80 was calibrated to, so the sheets are
  // exercised against real numbers rather than defaults.
  const endpoint = PrinterEndpoint(
    kind: PrintTransportKind.system,
    name: 'HPRT LPQ80',
    outputMode: PrinterOutputMode.pdfA4,
    paperWidthMm: 80,
    labelWidthMm: 33,
    labelHeightMm: 23,
    labelPdfSize: BarcodeLabelPdfSize.sticker,
    labelPdfOffsetXMm: 22,
    labelPdfOffsetYMm: 1,
    labelPdfPitchMm: 26.9,
  );

  Future<BarcodeLabelCalibrationDocument> document([
    PrinterEndpoint config = endpoint,
  ]) async {
    return BarcodeLabelCalibrationDocument(
      endpoint: config,
      fonts: await const _FileFontLoader().load(),
    );
  }

  test('the across ruler is printed on the very page a label is', () async {
    // A label driver usually centres a page narrower than its head, so pages of
    // different widths land in different places. The ruler used to span the
    // whole head (the 80 mm receipt width): its numbers then held for nothing
    // but itself, and an offset read off it moved the label by something else.
    final doc = await document();
    final sheet = await doc.build(BarcodeLabelCalibrationSheet.acrossRuler);
    // 22 mm of run-up + the 33 mm sticker, as a label's page is.
    expect(sheet.mediaWidthMm, 55);
    expect(sheet.mediaWidthMm, barcodeLabelPageWidthMm(endpoint));
    expect(sheet.mediaHeightMm, closeTo(26.9, 0.01));
    expect(sheet.bytes, isNotEmpty);
  });

  test(
    'every sheet shares the label page width, whatever the settings',
    () async {
      for (final config in [
        endpoint,
        endpoint.copyWith(labelPdfOffsetXMm: 0, labelWidthMm: 50),
        endpoint.copyWith(labelPdfOffsetXMm: 3, labelWidthMm: 40),
      ]) {
        final doc = await document(config);
        final label = await const BarcodeLabelDocumentService(
          fontLoader: _FileFontLoader(),
        ).buildLabelsDocument(lines: [_line], endpoint: config);
        for (final kind in BarcodeLabelCalibrationSheet.values) {
          final sheet = await doc.build(kind);
          expect(
            sheet.mediaWidthMm,
            label.mediaWidthMm,
            reason: '${kind.name} at ${config.labelWidthMm} mm',
          );
        }
      }
    },
  );

  test('the feed ruler repeats across several labels', () async {
    final sheet = await (await document()).build(
      BarcodeLabelCalibrationSheet.feedRuler,
    );
    // Six labels of pitch, on the sticker's own page width.
    expect(sheet.mediaWidthMm, 55);
    expect(sheet.mediaHeightMm, closeTo(6 * 26.9, 0.01));
  });

  test('the combs bracket the configured pitch', () async {
    final doc = await document();
    // Seven columns centred on 26.9: the coarse comb reaches ±1.2 mm, the fine
    // one ±0.3 mm for pinning it down.
    expect(doc.combPitches(0.4).first, closeTo(25.7, 0.001));
    expect(doc.combPitches(0.4).last, closeTo(28.1, 0.001));
    expect(doc.combPitches(0.1).first, closeTo(26.6, 0.001));
    expect(doc.combPitches(0.1).last, closeTo(27.2, 0.001));
  });

  test('a comb runs long enough for a tenth of a mm to show', () async {
    final sheet = await (await document()).build(
      BarcodeLabelCalibrationSheet.pitchCombFine,
    );
    // Ten labels: at 0.1 mm a column drifts a visible millimetre by the end.
    expect(sheet.mediaHeightMm, closeTo(1 + 10 * 27.2, 0.01));
  });

  test('an uncalibrated printer still gets usable sheets', () async {
    // Pitch defaults to the sticker itself until it has been measured.
    final doc = await document(
      endpoint.copyWith(labelPdfPitchMm: 0, labelPdfOffsetYMm: 0),
    );
    final sheet = await doc.build(BarcodeLabelCalibrationSheet.feedRuler);
    expect(sheet.mediaHeightMm, closeTo(6 * 23, 0.01));
    expect(doc.combPitches(0.4), everyElement(greaterThan(1)));
  });
}

const _line = BarcodeLabelPrintLine(
  label: BarcodeLabelDraft(
    displayName: 'شاي',
    productName: 'شاي',
    sku: 'TEA',
    barcode: '6224000123456',
    unitPrice: 3,
  ),
  copies: 1,
  includePrice: true,
);

/// Loads the real bundled Arabic TTFs so the sheets render the same glyphs the
/// printer will see.
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
