import 'package:pdf/pdf.dart';

enum BusinessReportType {
  salesSummary,
  paymentSummary,
  registerSessionArchive,
  inventorySnapshot,
  stockMovementArchive,
  purchasingSummary,
  customerStatement,
  supplierStatement,
  discountAudit,
  auditTrail,
}

enum ReportPdfOrientation { portrait, landscape }

class ReportPdfPeriod {
  const ReportPdfPeriod({this.label, this.start, this.end});

  final String? label;
  final DateTime? start;
  final DateTime? end;
}

class ReportPdfMetric {
  const ReportPdfMetric({required this.label, required this.value, this.note});

  final String label;
  final String value;
  final String? note;
}

class ReportPdfField {
  const ReportPdfField({required this.label, required this.value});

  final String label;
  final String value;
}

class ReportPdfSection {
  const ReportPdfSection({
    required this.heading,
    this.paragraphs = const [],
    this.fields = const [],
    this.tables = const [],
  });

  final String heading;
  final List<String> paragraphs;
  final List<ReportPdfField> fields;
  final List<ReportPdfTable> tables;
}

class ReportPdfTable {
  const ReportPdfTable({
    required this.columns,
    required this.rows,
    this.title,
    this.columnFlex = const [],
  });

  final String? title;
  final List<String> columns;
  final List<List<String>> rows;
  final List<double> columnFlex;
}

class ReportPdfAuditEntry {
  const ReportPdfAuditEntry({
    required this.occurredAt,
    required this.action,
    required this.actor,
    this.note,
  });

  final DateTime occurredAt;
  final String action;
  final String actor;
  final String? note;
}

class BusinessReportPdfDocument {
  const BusinessReportPdfDocument({
    required this.type,
    required this.title,
    required this.businessName,
    required this.generatedAt,
    this.generatedBy,
    this.reference,
    this.period,
    this.metrics = const [],
    this.summaryFields = const [],
    this.sections = const [],
    this.tables = const [],
    this.auditTrail = const [],
  });

  final BusinessReportType type;
  final String title;
  final String businessName;
  final DateTime generatedAt;
  final String? generatedBy;
  final String? reference;
  final ReportPdfPeriod? period;
  final List<ReportPdfMetric> metrics;
  final List<ReportPdfField> summaryFields;
  final List<ReportPdfSection> sections;
  final List<ReportPdfTable> tables;
  final List<ReportPdfAuditEntry> auditTrail;

  String get suggestedFileName {
    final date = _compactDate(generatedAt);
    final safeTitle = _safeFileToken(title);
    return '${safeTitle.isEmpty ? 'report' : safeTitle}_$date.pdf';
  }
}

class ReportPdfOptions {
  const ReportPdfOptions({
    this.pageFormat = PdfPageFormat.a4,
    this.orientation = ReportPdfOrientation.portrait,
    this.includeAuditTrail = true,
    this.useRequestedPrinterFormat = false,
  });

  final PdfPageFormat pageFormat;
  final ReportPdfOrientation orientation;
  final bool includeAuditTrail;
  final bool useRequestedPrinterFormat;

  PdfPageFormat resolvedPageFormat([PdfPageFormat? requestedFormat]) {
    final format = useRequestedPrinterFormat && requestedFormat != null
        ? requestedFormat
        : pageFormat;
    return switch (orientation) {
      ReportPdfOrientation.portrait => format.portrait,
      ReportPdfOrientation.landscape => format.landscape,
    };
  }
}

String _compactDate(DateTime dateTime) {
  final local = dateTime.toLocal();
  final year = local.year.toString().padLeft(4, '0');
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$year$month$day';
}

String _safeFileToken(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    final isAsciiLetter =
        (rune >= 65 && rune <= 90) || (rune >= 97 && rune <= 122);
    final isDigit = rune >= 48 && rune <= 57;
    final isArabic = rune >= 0x0600 && rune <= 0x06ff;
    if (isAsciiLetter || isDigit || isArabic) {
      buffer.write(character);
    } else if (buffer.isNotEmpty && !buffer.toString().endsWith('_')) {
      buffer.write('_');
    }
  }
  return buffer
      .toString()
      .replaceAll(RegExp('_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}
