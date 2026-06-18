import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

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

/// A PDF font payload that can cross an isolate boundary. [toFonts] rebuilds the
/// pdf [pw.Font] objects (cheap, pure computation) on whichever isolate ends up
/// rendering the document.
sealed class PointyPdfFontData {
  const PointyPdfFontData();

  PointyPdfFonts toFonts();
}

/// Real (bundled TTF) fonts carried as raw bytes — sendable to a background
/// isolate, where they are parsed into [pw.Font]s.
class TtfPointyPdfFontData extends PointyPdfFontData {
  const TtfPointyPdfFontData({
    required this.base,
    required this.bold,
    this.fallback = const [],
  });

  final ByteData base;
  final ByteData bold;
  final List<ByteData> fallback;

  @override
  PointyPdfFonts toFonts() =>
      PointyPdfFonts.ttf(base: base, bold: bold, fallback: fallback);
}

/// Built-in Helvetica set for tests/previews that don't render Arabic glyphs.
class Type1PointyPdfFontData extends PointyPdfFontData {
  const Type1PointyPdfFontData();

  @override
  PointyPdfFonts toFonts() => PointyPdfFonts.type1ForTests();
}

/// Loads the PDF fonts. Reuses the app's bundled IBM Plex Sans Arabic so PDFs
/// render offline and the raw bytes can be handed to a background isolate.
/// Injectable so tests/previews can swap in lighter fonts; point the asset
/// paths at other bundled TTFs to change the PDF typeface.
class PointyPdfFontLoader {
  const PointyPdfFontLoader();

  static const _baseFontAsset = 'assets/fonts/IBMPlexSansArabic-Regular.ttf';
  static const _boldFontAsset = 'assets/fonts/IBMPlexSansArabic-Bold.ttf';

  Future<PointyPdfFontData> loadData() async {
    final base = await rootBundle.load(_baseFontAsset);
    final bold = await rootBundle.load(_boldFontAsset);
    return TtfPointyPdfFontData(base: base, bold: bold);
  }

  Future<PointyPdfFonts> load() async => (await loadData()).toFonts();
}
