import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../shared/pdf/pdf.dart';
import '../models/printer_config.dart';
import 'barcode_label_document_service.dart';

/// Test sheets for working out a label printer's geometry.
///
/// Every number in [PrinterEndpoint]'s die-cut settings is a measurement, and
/// guessing at them costs a roll of labels and an afternoon. Each sheet turns
/// one unknown into something a person can read straight off the sticker.
enum BarcodeLabelCalibrationSheet {
  /// A millimetre scale across the full head width: where the sticker's left and
  /// right edges land gives the horizontal offset and the sticker width.
  acrossRuler,

  /// A millimetre scale down the feed, repeating once per label: where the
  /// sticker's top and bottom edges land gives the vertical offset and height.
  feedRuler,

  /// Columns marching down the strip at slightly different pitches, in 0.4 mm
  /// steps — the column that stays level on every sticker is the pitch.
  pitchCombCoarse,

  /// The same comb in 0.1 mm steps, for pinning the pitch down once the coarse
  /// comb has put it in range. A tenth of a millimetre is a whole label over a
  /// run of a hundred, so this step matters.
  pitchCombFine,
}

/// Builds the calibration sheets. Pure layout — printing is
/// [BarcodeLabelDocumentService.printCalibration]'s job.
class BarcodeLabelCalibrationDocument {
  const BarcodeLabelCalibrationDocument({
    required this.endpoint,
    required this.fonts,
  });

  final PrinterEndpoint endpoint;
  final PointyPdfFonts fonts;

  static const double _mm = PdfPageFormat.mm;
  static const _ink = PdfColor.fromInt(0xff000000);

  /// How many labels each sheet spans. The combs need the length: a 0.1 mm
  /// error only becomes visible once it has accumulated over ten labels.
  static const _rulerLabels = 6;
  static const _combLabels = 10;
  static const _combColumns = 7;

  double get _widthMm => endpoint.labelWidthMm.toDouble();
  double get _heightMm => endpoint.labelHeightMm.toDouble();
  double get _offsetXMm => endpoint.labelPdfOffsetXMm.toDouble();
  double get _offsetYMm => endpoint.labelPdfOffsetYMm.toDouble();

  /// The pitch to centre the combs on, falling back to the sticker itself when
  /// it has never been measured.
  double get _pitchMm => endpoint.labelPdfPitchMm > 0
      ? endpoint.labelPdfPitchMm
      : _heightMm + _offsetYMm;

  Future<BarcodeLabelDocument> build(BarcodeLabelCalibrationSheet sheet) {
    return switch (sheet) {
      BarcodeLabelCalibrationSheet.acrossRuler => _acrossRuler(),
      BarcodeLabelCalibrationSheet.feedRuler => _feedRuler(),
      BarcodeLabelCalibrationSheet.pitchCombCoarse => _pitchComb(0.4),
      BarcodeLabelCalibrationSheet.pitchCombFine => _pitchComb(0.1),
    };
  }

  pw.Document _document() => pw.Document(
    title: 'معايرة ملصقات الباركود',
    creator: 'دفتر',
    subject: 'barcode label calibration',
  );

  pw.Widget _tick({
    required double leftMm,
    required double topMm,
    required double widthMm,
    required double heightMm,
  }) {
    return pw.Positioned(
      left: leftMm * _mm,
      top: topMm * _mm,
      child: pw.Container(
        width: widthMm * _mm,
        height: heightMm * _mm,
        color: _ink,
      ),
    );
  }

  pw.Widget _number(
    String text,
    double leftMm,
    double topMm, {
    double size = 8,
  }) {
    return pw.Positioned(
      left: leftMm * _mm,
      top: topMm * _mm,
      child: pw.Text(
        text,
        textDirection: pw.TextDirection.ltr,
        style: pw.TextStyle(font: fonts.base, fontSize: size, color: _ink),
      ),
    );
  }

  /// Scale across the head. Spans the printer's full width, not just the
  /// sticker: the whole point is to find where the sticker sits within it.
  Future<BarcodeLabelDocument> _acrossRuler() async {
    final pageWidthMm = endpoint.paperWidthMm.toDouble().clamp(20.0, 210.0);
    final pageHeightMm = _pitchMm;
    final pdf = _document();
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(pageWidthMm * _mm, pageHeightMm * _mm),
        margin: pw.EdgeInsets.zero,
        build: (context) => pw.Stack(
          children: [
            for (var x = 0; x <= pageWidthMm.floor(); x += 1) ...[
              _tick(
                leftMm: x.toDouble(),
                topMm: 0,
                widthMm: 0.25,
                heightMm: x % 10 == 0
                    ? 5
                    : x % 5 == 0
                    ? 3.5
                    : 2,
              ),
              if (x % 10 == 0) _number('$x', x + 0.6, 5.4),
            ],
          ],
        ),
      ),
    );
    return BarcodeLabelDocument(
      bytes: await pdf.save(),
      mediaWidthMm: pageWidthMm,
      mediaHeightMm: pageHeightMm,
    );
  }

  /// Scale down the feed, restarting at every label so each sticker carries the
  /// same numbers — which also shows at a glance whether the pitch is holding.
  Future<BarcodeLabelDocument> _feedRuler() async {
    final pageWidthMm = _offsetXMm + _widthMm;
    final pageHeightMm = _rulerLabels * _pitchMm;
    final pdf = _document();
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(pageWidthMm * _mm, pageHeightMm * _mm),
        margin: pw.EdgeInsets.zero,
        build: (context) => pw.Stack(
          children: [
            for (var label = 0; label < _rulerLabels; label++)
              for (var d = 0; d <= _pitchMm.floor(); d += 1) ...[
                _tick(
                  leftMm: _offsetXMm + 1,
                  topMm: label * _pitchMm + d,
                  widthMm: d % 5 == 0 ? 8 : 4,
                  heightMm: 0.25,
                ),
                if (d % 5 == 0)
                  _number(
                    '$d',
                    _offsetXMm + 10,
                    label * _pitchMm + d - 1.4,
                    size: 7,
                  ),
              ],
          ],
        ),
      ),
    );
    return BarcodeLabelDocument(
      bytes: await pdf.save(),
      mediaWidthMm: pageWidthMm,
      mediaHeightMm: pageHeightMm,
    );
  }

  /// The pitch comb. Each column steps down the strip at its own pitch, so the
  /// column that stays level on every sticker names the true one — one print and
  /// one glance, instead of a print-and-nudge round per guess.
  Future<BarcodeLabelDocument> _pitchComb(double stepMm) async {
    final pitches = [
      for (var c = 0; c < _combColumns; c++)
        _pitchMm + (c - (_combColumns - 1) / 2) * stepMm,
    ].where((pitch) => pitch > 1).toList();
    final tallest = pitches.reduce((a, b) => a > b ? a : b);
    final pageWidthMm = _offsetXMm + _widthMm;
    final pageHeightMm = _offsetYMm + _combLabels * tallest;
    final columnWidthMm = _widthMm / pitches.length;

    final pdf = _document();
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(pageWidthMm * _mm, pageHeightMm * _mm),
        margin: pw.EdgeInsets.zero,
        build: (context) => pw.Stack(
          children: [
            for (var c = 0; c < pitches.length; c++)
              for (var i = 0; i < _combLabels; i++) ...[
                _tick(
                  leftMm: _offsetXMm + c * columnWidthMm + 0.5,
                  topMm: _offsetYMm + i * pitches[c],
                  widthMm: columnWidthMm - 1,
                  heightMm: 1.8,
                ),
                _number(
                  '${c + 1}',
                  _offsetXMm + c * columnWidthMm + 1,
                  _offsetYMm + i * pitches[c] + 2.1,
                  size: 7,
                ),
              ],
          ],
        ),
      ),
    );
    return BarcodeLabelDocument(
      bytes: await pdf.save(),
      mediaWidthMm: pageWidthMm,
      mediaHeightMm: pageHeightMm,
    );
  }

  /// The pitch each comb column is printed at, so the settings screen can name
  /// the numbers the reader is choosing between.
  List<double> combPitches(double stepMm) => [
    for (var c = 0; c < _combColumns; c++)
      _pitchMm + (c - (_combColumns - 1) / 2) * stepMm,
  ].where((pitch) => pitch > 1).toList();
}
