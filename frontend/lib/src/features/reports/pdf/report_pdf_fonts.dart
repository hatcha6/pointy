import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class ReportPdfFonts {
  const ReportPdfFonts({
    required this.base,
    required this.bold,
    this.italic,
    this.boldItalic,
    this.fallback = const [],
  });

  factory ReportPdfFonts.type1ForTests() {
    return ReportPdfFonts(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
      italic: pw.Font.helveticaOblique(),
      boldItalic: pw.Font.helveticaBoldOblique(),
    );
  }

  factory ReportPdfFonts.ttf({
    required ByteData base,
    required ByteData bold,
    ByteData? italic,
    ByteData? boldItalic,
    List<ByteData> fallback = const [],
  }) {
    return ReportPdfFonts(
      base: pw.Font.ttf(base),
      bold: pw.Font.ttf(bold),
      italic: italic == null ? null : pw.Font.ttf(italic),
      boldItalic: boldItalic == null ? null : pw.Font.ttf(boldItalic),
      fallback: [for (final font in fallback) pw.Font.ttf(font)],
    );
  }

  final pw.Font base;
  final pw.Font bold;
  final pw.Font? italic;
  final pw.Font? boldItalic;
  final List<pw.Font> fallback;

  pw.ThemeData toThemeData() {
    return pw.ThemeData.withFont(
      base: base,
      bold: bold,
      italic: italic,
      boldItalic: boldItalic,
      fontFallback: fallback,
    );
  }
}

class ReportPdfFontLoader {
  const ReportPdfFontLoader();

  Future<ReportPdfFonts> load() async {
    final regular = await PdfGoogleFonts.notoNaskhArabicRegular();
    final bold = await PdfGoogleFonts.notoNaskhArabicBold();
    final cairo = await PdfGoogleFonts.cairoRegular();
    return ReportPdfFonts(base: regular, bold: bold, fallback: [cairo]);
  }
}
