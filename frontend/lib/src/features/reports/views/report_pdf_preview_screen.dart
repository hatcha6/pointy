import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../pdf/report_pdf.dart';

class ReportPdfPreviewScreen extends StatelessWidget {
  const ReportPdfPreviewScreen({
    super.key,
    required this.document,
    this.printingService = const ReportPrintingService(),
  });

  final BusinessReportPdfDocument document;
  final ReportPrintingService printingService;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.reportPdfPreviewTitle)),
      body: SafeArea(
        child: PdfPreview(
          build: printingService.previewLayoutCallback(document),
          initialPageFormat: PdfPageFormat.a4,
          pdfFileName: document.suggestedFileName,
          canChangeOrientation: false,
          canChangePageFormat: false,
          canDebug: false,
        ),
      ),
    );
  }
}
