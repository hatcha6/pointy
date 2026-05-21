import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../pdf/report_pdf.dart';

class ReportPdfPreviewScreen extends StatefulWidget {
  const ReportPdfPreviewScreen({
    super.key,
    required this.document,
    this.initialBytes,
    this.printingService = const ReportPrintingService(),
  });

  final BusinessReportPdfDocument document;
  final Uint8List? initialBytes;
  final ReportPrintingService printingService;

  @override
  State<ReportPdfPreviewScreen> createState() => _ReportPdfPreviewScreenState();
}

class _ReportPdfPreviewScreenState extends State<ReportPdfPreviewScreen> {
  late Future<Uint8List> _previewBytes;

  @override
  void initState() {
    super.initState();
    _previewBytes = _buildPreviewBytes();
  }

  @override
  void didUpdateWidget(covariant ReportPdfPreviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document ||
        oldWidget.initialBytes != widget.initialBytes ||
        oldWidget.printingService != widget.printingService) {
      _previewBytes = _buildPreviewBytes();
    }
  }

  Future<Uint8List> _buildPreviewBytes() {
    final bytes = widget.initialBytes;
    if (bytes != null) {
      return Future.value(bytes);
    }
    return widget.printingService.buildBytes(
      widget.document,
      requestedPageFormat: PdfPageFormat.a4,
    );
  }

  Future<Uint8List> _cachedLayout(PdfPageFormat _) {
    return _previewBytes;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.reportPdfPreviewTitle)),
      body: SafeArea(
        child: PdfPreview(
          build: _cachedLayout,
          initialPageFormat: PdfPageFormat.a4,
          pdfFileName: widget.document.suggestedFileName,
          canChangeOrientation: false,
          canChangePageFormat: false,
          canDebug: false,
        ),
      ),
    );
  }
}
