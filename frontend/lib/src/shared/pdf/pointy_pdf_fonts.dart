import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Fonts for every Pointy PDF. Arabic-first: a Naskh base/bold with a Cairo
/// fallback so digits and Latin tokens stay legible. Shared by invoices,
/// purchase orders, and business reports.
class PointyPdfFonts {
  const PointyPdfFonts({
    required this.base,
    required this.bold,
    this.italic,
    this.boldItalic,
    this.fallback = const [],
  });

  /// Helvetica-only set for widget tests that don't render Arabic glyphs.
  factory PointyPdfFonts.type1ForTests() {
    return PointyPdfFonts(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
      italic: pw.Font.helveticaOblique(),
      boldItalic: pw.Font.helveticaBoldOblique(),
    );
  }

  factory PointyPdfFonts.ttf({
    required ByteData base,
    required ByteData bold,
    ByteData? italic,
    ByteData? boldItalic,
    List<ByteData> fallback = const [],
  }) {
    return PointyPdfFonts(
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

/// Loads the bundled-by-Google fonts at runtime. Injectable so tests (and the
/// offline preview) can supply local TTFs instead of hitting the network.
class PointyPdfFontLoader {
  const PointyPdfFontLoader();

  Future<PointyPdfFonts> load() async {
    final regular = await PdfGoogleFonts.notoNaskhArabicRegular();
    final bold = await PdfGoogleFonts.notoNaskhArabicBold();
    final cairo = await PdfGoogleFonts.cairoRegular();
    return PointyPdfFonts(base: regular, bold: bold, fallback: [cairo]);
  }
}
