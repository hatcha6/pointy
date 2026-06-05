import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/pdf/pointy_pdf_table.dart';
import 'report_pdf_fonts.dart';
import 'report_pdf_labels.dart';
import 'report_pdf_models.dart';

class ReportPdfGenerator {
  const ReportPdfGenerator({
    this.fontLoader = const ReportPdfFontLoader(),
    this.labels = const ReportPdfLabels.arabic(),
  });

  final ReportPdfFontLoader fontLoader;
  final ReportPdfLabels labels;

  Future<Uint8List> generate(
    BusinessReportPdfDocument report, {
    ReportPdfOptions options = const ReportPdfOptions(),
    PdfPageFormat? requestedPageFormat,
    ReportPdfFonts? fonts,
  }) async {
    final resolvedFonts = fonts ?? await fontLoader.load();
    final theme = resolvedFonts.toThemeData();
    final pageFormat = options.resolvedPageFormat(requestedPageFormat);
    final pdf = pw.Document(
      title: report.title,
      author: report.generatedBy,
      creator: 'Pointy',
      subject: labels.typeLabel(report.type),
      keywords: 'pointy, reports, ${report.type.name}',
    );

    pdf.addPage(
      pw.MultiPage(
        maxPages: options.maxPages,
        pageTheme: pw.PageTheme(
          pageFormat: pageFormat.applyMargin(
            left: 16 * PdfPageFormat.mm,
            top: 14 * PdfPageFormat.mm,
            right: 16 * PdfPageFormat.mm,
            bottom: 14 * PdfPageFormat.mm,
          ),
          theme: theme,
          textDirection: pw.TextDirection.rtl,
        ),
        header: (context) => _Header(report: report, labels: labels),
        footer: (context) => _Footer(report: report, labels: labels),
        build: (context) => [
          _MetadataPanel(report: report, labels: labels),
          if (report.shopSettingFields.isNotEmpty) ...[
            pw.SizedBox(height: 10),
            _FieldSection(
              title: labels.shopSettings,
              fields: report.shopSettingFields,
              compact: true,
            ),
          ],
          if (report.metrics.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            _MetricGrid(metrics: report.metrics),
          ],
          if (report.summaryFields.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            _FieldSection(title: labels.summary, fields: report.summaryFields),
          ],
          for (final table in report.tables) ...[
            pw.SizedBox(height: 12),
            ..._reportTableWidgets(table),
          ],
          for (final section in report.sections) ...[
            pw.SizedBox(height: 12),
            ..._reportSectionWidgets(section),
          ],
          if (options.includeAuditTrail && report.auditTrail.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            ..._reportTableWidgets(_auditTrailTable(report.auditTrail, labels)),
          ],
        ],
      ),
    );

    return pdf.save();
  }
}

class _ReportColors {
  static const ink = PdfColor.fromInt(0xff172026);
  static const muted = PdfColor.fromInt(0xff64717a);
  static const border = PdfColor.fromInt(0xffd6dde2);
  static const fill = PdfColor.fromInt(0xfff7f8f6);
  static const accent = PdfColor.fromInt(0xff0b6b64);
  static const accentSoft = PdfColor.fromInt(0xffe8f4f1);
  static const white = PdfColor.fromInt(0xffffffff);
}

const _rowsPerTableChunk = 18;

List<pw.Widget> _reportSectionWidgets(ReportPdfSection section) {
  return [
    _SectionTitle(section.heading),
    for (final paragraph in section.paragraphs) ...[
      pw.SizedBox(height: 6),
      pw.Text(
        paragraph,
        style: const pw.TextStyle(
          color: _ReportColors.ink,
          fontSize: 10,
          lineSpacing: 3,
        ),
        textAlign: pw.TextAlign.right,
      ),
    ],
    if (section.fields.isNotEmpty) ...[
      pw.SizedBox(height: 8),
      _FieldWrap(fields: section.fields),
    ],
    for (final table in section.tables) ...[
      pw.SizedBox(height: 10),
      ..._reportTableWidgets(table),
    ],
  ];
}

List<pw.Widget> _reportTableWidgets(ReportPdfTable table) {
  final rowChunks = _chunkRows(table.rows);

  return [
    if (table.title != null) ...[
      _SectionTitle(table.title!, fontSize: 11),
      pw.SizedBox(height: 6),
    ],
    for (var index = 0; index < rowChunks.length; index += 1) ...[
      if (index > 0) pw.SizedBox(height: 8),
      _buildTableChunk(table: table, rows: rowChunks[index]),
    ],
  ];
}

pw.Widget _buildTableChunk({
  required ReportPdfTable table,
  required List<List<String>> rows,
}) {
  return PointyPdfTable.invoice(
    columns: table.columns,
    rows: rows,
    columnFlex: table.columnFlex,
    valueFormatter: _pdfTableValue,
  ).build();
}

String _pdfTableValue(String value) {
  const maxCellCharacters = 140;
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) {
    return '-';
  }
  if (normalized.length <= maxCellCharacters) {
    return normalized;
  }
  return '${normalized.substring(0, maxCellCharacters - 3)}...';
}

List<List<List<String>>> _chunkRows(List<List<String>> rows) {
  if (rows.isEmpty) {
    return const [[]];
  }

  return [
    for (var start = 0; start < rows.length; start += _rowsPerTableChunk)
      rows.sublist(start, (start + _rowsPerTableChunk).clamp(0, rows.length)),
  ];
}

ReportPdfTable _auditTrailTable(
  List<ReportPdfAuditEntry> entries,
  ReportPdfLabels labels,
) {
  return ReportPdfTable(
    title: labels.auditTrail,
    columns: [
      labels.auditTime,
      labels.auditAction,
      labels.auditActor,
      labels.auditNote,
    ],
    rows: [
      for (final entry in entries)
        [
          _formatDateTime(entry.occurredAt),
          entry.action,
          entry.actor,
          entry.note ?? labels.emptyValue,
        ],
    ],
    columnFlex: const [1.2, 1.2, 1, 1.6],
  );
}

class _Header extends pw.StatelessWidget {
  _Header({required this.report, required this.labels});

  final BusinessReportPdfDocument report;
  final ReportPdfLabels labels;

  @override
  pw.Widget build(pw.Context context) {
    final logoProvider = _logoProvider(report.businessLogoBytes);
    final headerText = _compactText(report.businessHeader, maxCharacters: 110);

    return pw.Container(
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: _ReportColors.fill,
        border: pw.Border.all(color: _ReportColors.border, width: 0.5),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  report.businessName,
                  style: pw.TextStyle(
                    color: _ReportColors.accent,
                    fontSize: 11,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  textAlign: pw.TextAlign.right,
                ),
                if (headerText != null) ...[
                  pw.SizedBox(height: 3),
                  pw.Text(
                    headerText,
                    style: const pw.TextStyle(
                      color: _ReportColors.muted,
                      fontSize: 8.5,
                      lineSpacing: 2,
                    ),
                    textAlign: pw.TextAlign.right,
                  ),
                ],
                pw.SizedBox(height: 6),
                pw.Text(
                  report.title,
                  style: pw.TextStyle(
                    color: _ReportColors.ink,
                    fontSize: 21,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  textAlign: pw.TextAlign.right,
                ),
              ],
            ),
          ),
          pw.SizedBox(width: 12),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              if (logoProvider != null) ...[
                pw.Container(
                  width: 48,
                  height: 48,
                  padding: const pw.EdgeInsets.all(5),
                  decoration: pw.BoxDecoration(
                    color: _ReportColors.white,
                    border: pw.Border.all(color: _ReportColors.border),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(5),
                    ),
                  ),
                  child: pw.Image(logoProvider, fit: pw.BoxFit.contain),
                ),
                pw.SizedBox(height: 8),
              ],
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 9,
                  vertical: 5,
                ),
                decoration: pw.BoxDecoration(
                  color: _ReportColors.accentSoft,
                  border: pw.Border.all(color: _ReportColors.border),
                  borderRadius: const pw.BorderRadius.all(
                    pw.Radius.circular(4),
                  ),
                ),
                child: pw.Text(
                  labels.typeLabel(report.type),
                  style: pw.TextStyle(
                    color: _ReportColors.accent,
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String? _compactText(String? value, {required int maxCharacters}) {
  final normalized = value?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
  if (normalized.isEmpty) {
    return null;
  }
  if (normalized.length <= maxCharacters) {
    return normalized;
  }
  return '${normalized.substring(0, maxCharacters - 3)}...';
}

pw.ImageProvider? _logoProvider(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  try {
    return pw.MemoryImage(bytes);
  } on Object {
    return null;
  }
}

class _Footer extends pw.StatelessWidget {
  _Footer({required this.report, required this.labels});

  final BusinessReportPdfDocument report;
  final ReportPdfLabels labels;

  @override
  pw.Widget build(pw.Context context) {
    final footerText = _compactText(report.businessFooter, maxCharacters: 150);

    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: const pw.BoxDecoration(
        border: pw.Border(top: pw.BorderSide(color: _ReportColors.border)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            '${labels.page} ${context.pageNumber} ${labels.ofPages} ${context.pagesCount}',
            style: const pw.TextStyle(color: _ReportColors.muted, fontSize: 8),
          ),
          if (footerText != null) ...[
            pw.SizedBox(width: 10),
            pw.Expanded(
              child: pw.Text(
                footerText,
                style: const pw.TextStyle(
                  color: _ReportColors.muted,
                  fontSize: 8,
                ),
                textAlign: pw.TextAlign.right,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetadataPanel extends pw.StatelessWidget {
  _MetadataPanel({required this.report, required this.labels});

  final BusinessReportPdfDocument report;
  final ReportPdfLabels labels;

  @override
  pw.Widget build(pw.Context context) {
    final fields = [
      ReportPdfField(
        label: labels.generatedAt,
        value: _formatDateTime(report.generatedAt),
      ),
      if (report.generatedBy != null)
        ReportPdfField(label: labels.generatedBy, value: report.generatedBy!),
      if (report.reference != null)
        ReportPdfField(label: labels.reference, value: report.reference!),
      if (report.period != null) ..._periodFields(report.period!, labels),
    ];

    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 12),
      padding: const pw.EdgeInsets.all(11),
      decoration: pw.BoxDecoration(
        color: _ReportColors.accentSoft,
        border: pw.Border.all(color: _ReportColors.border),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: _FieldWrap(fields: fields),
    );
  }
}

class _MetricGrid extends pw.StatelessWidget {
  _MetricGrid({required this.metrics});

  final List<ReportPdfMetric> metrics;

  @override
  pw.Widget build(pw.Context context) {
    return pw.Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final metric in metrics)
          pw.Container(
            width: 128,
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: _ReportColors.white,
              border: pw.Border.all(color: _ReportColors.border),
              borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  metric.label,
                  style: const pw.TextStyle(
                    color: _ReportColors.muted,
                    fontSize: 9,
                  ),
                  textAlign: pw.TextAlign.right,
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  metric.value,
                  style: pw.TextStyle(
                    color: _ReportColors.ink,
                    fontSize: 15,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  textAlign: pw.TextAlign.right,
                ),
                if (metric.note != null) ...[
                  pw.SizedBox(height: 3),
                  pw.Text(
                    metric.note!,
                    style: const pw.TextStyle(
                      color: _ReportColors.muted,
                      fontSize: 8,
                    ),
                    textAlign: pw.TextAlign.right,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _FieldSection extends pw.StatelessWidget {
  _FieldSection({
    required this.title,
    required this.fields,
    this.compact = false,
  });

  final String title;
  final List<ReportPdfField> fields;
  final bool compact;

  @override
  pw.Widget build(pw.Context context) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        _SectionTitle(title),
        pw.SizedBox(height: 6),
        _FieldWrap(fields: fields, compact: compact),
      ],
    );
  }
}

class _FieldWrap extends pw.StatelessWidget {
  _FieldWrap({required this.fields, this.compact = false});

  final List<ReportPdfField> fields;
  final bool compact;

  @override
  pw.Widget build(pw.Context context) {
    return pw.Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        for (final field in fields)
          pw.SizedBox(
            width: compact ? 124 : 150,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  field.label,
                  style: pw.TextStyle(
                    color: _ReportColors.muted,
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                  ),
                  textAlign: pw.TextAlign.right,
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  field.value,
                  style: const pw.TextStyle(
                    color: _ReportColors.ink,
                    fontSize: 10,
                  ),
                  textAlign: pw.TextAlign.right,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionTitle extends pw.StatelessWidget {
  _SectionTitle(this.title, {this.fontSize = 12});

  final String title;
  final double fontSize;

  @override
  pw.Widget build(pw.Context context) {
    return pw.Text(
      title,
      style: pw.TextStyle(
        color: _ReportColors.ink,
        fontSize: fontSize,
        fontWeight: pw.FontWeight.bold,
      ),
      textAlign: pw.TextAlign.right,
    );
  }
}

List<ReportPdfField> _periodFields(
  ReportPdfPeriod period,
  ReportPdfLabels labels,
) {
  return [
    if (period.label != null)
      ReportPdfField(label: labels.period, value: period.label!),
    if (period.start != null)
      ReportPdfField(label: labels.fromDate, value: _formatDate(period.start!)),
    if (period.end != null)
      ReportPdfField(label: labels.toDate, value: _formatDate(period.end!)),
  ];
}

String _formatDate(DateTime dateTime) {
  return DateFormat('yyyy/MM/dd').format(dateTime.toLocal());
}

String _formatDateTime(DateTime dateTime) {
  return DateFormat('yyyy/MM/dd HH:mm').format(dateTime.toLocal());
}
