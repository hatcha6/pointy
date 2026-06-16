import '../../../shared/pdf/pointy_pdf_fonts.dart';

/// Report fonts are simply the shared Pointy PDF fonts, kept as domain-named
/// aliases so the reports API surface (and its callers) stay stable while the
/// implementation lives in one place.
typedef ReportPdfFonts = PointyPdfFonts;
typedef ReportPdfFontLoader = PointyPdfFontLoader;
