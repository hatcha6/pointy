import 'dart:typed_data';
import 'dart:ui';

import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../../../data/repositories/printing_repository.dart';
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

  /// Prints [report] on the device's documents printer when
  /// [printingRepository] is given and one is set, and through the system
  /// print dialog otherwise.
  Future<bool> print(
    BusinessReportPdfDocument report, {
    ReportPdfOptions? options,
    String? jobName,
    ReportPdfFonts? fonts,
    PrintingRepository? printingRepository,
  }) {
    final resolvedOptions = options ?? this.options;
    final name = jobName ?? report.title;
    final onLayout = layoutCallback(
      report,
      options: resolvedOptions,
      fonts: fonts ?? this.fonts,
    );
    if (printingRepository != null) {
      return printingRepository.printDocumentPdf(
        jobName: name,
        format: resolvedOptions.pageFormat,
        onLayout: onLayout,
      );
    }
    return Printing.layoutPdf(
      name: name,
      format: resolvedOptions.pageFormat,
      onLayout: onLayout,
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
