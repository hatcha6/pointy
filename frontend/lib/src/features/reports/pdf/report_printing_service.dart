import 'dart:typed_data';
import 'dart:ui';

import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import 'report_pdf_fonts.dart';
import 'report_pdf_generator.dart';
import 'report_pdf_models.dart';

class ReportPrintingService {
  const ReportPrintingService({
    this.generator = const ReportPdfGenerator(),
    this.options = const ReportPdfOptions(),
    this.fonts,
  });

  final ReportPdfGenerator generator;
  final ReportPdfOptions options;
  final ReportPdfFonts? fonts;

  LayoutCallback previewLayoutCallback(
    BusinessReportPdfDocument report, {
    ReportPdfOptions? options,
    ReportPdfFonts? fonts,
  }) {
    return layoutCallback(report, options: options, fonts: fonts);
  }

  LayoutCallback layoutCallback(
    BusinessReportPdfDocument report, {
    ReportPdfOptions? options,
    ReportPdfFonts? fonts,
  }) {
    final resolvedOptions = options ?? this.options;
    return (format) => generator.generate(
      report,
      options: resolvedOptions,
      requestedPageFormat: format,
      fonts: fonts ?? this.fonts,
    );
  }

  Future<Uint8List> buildBytes(
    BusinessReportPdfDocument report, {
    ReportPdfOptions? options,
    PdfPageFormat? requestedPageFormat,
    ReportPdfFonts? fonts,
  }) {
    final resolvedOptions = options ?? this.options;
    return generator.generate(
      report,
      options: resolvedOptions,
      requestedPageFormat: requestedPageFormat,
      fonts: fonts ?? this.fonts,
    );
  }

  Future<bool> print(
    BusinessReportPdfDocument report, {
    ReportPdfOptions? options,
    String? jobName,
    ReportPdfFonts? fonts,
  }) {
    final resolvedOptions = options ?? this.options;
    return Printing.layoutPdf(
      name: jobName ?? report.title,
      format: resolvedOptions.pageFormat,
      onLayout: layoutCallback(
        report,
        options: resolvedOptions,
        fonts: fonts ?? this.fonts,
      ),
    );
  }

  Future<bool> share(
    BusinessReportPdfDocument report, {
    ReportPdfOptions? options,
    String? filename,
    String? subject,
    String? body,
    Rect? bounds,
    ReportPdfFonts? fonts,
  }) async {
    final bytes = await buildBytes(report, options: options, fonts: fonts);
    return Printing.sharePdf(
      bytes: bytes,
      filename: filename ?? report.suggestedFileName,
      subject: subject,
      body: body,
      bounds: bounds,
    );
  }
}
