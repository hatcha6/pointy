import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/barcode_label_calibration.dart';
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

  test('the across ruler spans the whole head, not just the sticker', () async {
    // Finding where the roll sits under the head is the point, so the scale has
    // to cover paper the sticker isn't on.
    final sheet = await (await document()).build(
      BarcodeLabelCalibrationSheet.acrossRuler,
    );
    expect(sheet.mediaWidthMm, 80);
    expect(sheet.mediaHeightMm, closeTo(26.9, 0.01));
    expect(sheet.bytes, isNotEmpty);
  });

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
