import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

class PointyPdfTable {
  const PointyPdfTable({
    required this.columns,
    required this.rows,
    this.columnFlex = const [],
    this.columnAlignments = const [],
    this.reverseColumns = true,
    this.emptyValue,
    this.valueFormatter = _identity,
    this.border,
    this.headerDecoration,
    this.rowDecoration,
    this.oddRowDecoration,
    this.headerStyle,
    this.cellStyle,
    this.cellPadding = const pw.EdgeInsets.all(5),
    this.headerPadding,
    this.cellAlignment = pw.Alignment.centerRight,
    this.headerAlignment = pw.Alignment.centerRight,
    this.tableDirection = pw.TextDirection.rtl,
    this.headerDirection = pw.TextDirection.rtl,
    this.tableWidth = pw.TableWidth.max,
  });

  factory PointyPdfTable.invoice({
    required List<String> columns,
    required List<List<String>> rows,
    List<double> columnFlex = const [],
    List<pw.Alignment>? columnAlignments,
    bool reverseColumns = true,
    String? emptyValue,
    String Function(String value) valueFormatter = _identity,
    pw.TextDirection tableDirection = pw.TextDirection.rtl,
    pw.TextDirection headerDirection = pw.TextDirection.rtl,
    pw.TableWidth tableWidth = pw.TableWidth.max,
  }) {
    return PointyPdfTable(
      columns: columns,
      rows: rows,
      columnFlex: columnFlex,
      columnAlignments:
          columnAlignments ?? invoiceColumnAlignments(columns.length),
      reverseColumns: reverseColumns,
      emptyValue: emptyValue,
      valueFormatter: valueFormatter,
      border: null,
      headerDecoration: const pw.BoxDecoration(
        color: _PointyPdfTableColors.tableHeader,
        borderRadius: pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      rowDecoration: const pw.BoxDecoration(color: _PointyPdfTableColors.white),
      oddRowDecoration: const pw.BoxDecoration(
        color: _PointyPdfTableColors.white,
      ),
      headerStyle: pw.TextStyle(
        color: _PointyPdfTableColors.white,
        fontSize: 11,
        fontWeight: pw.FontWeight.bold,
      ),
      cellStyle: const pw.TextStyle(
        color: _PointyPdfTableColors.ink,
        fontSize: 11,
      ),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      headerPadding: const pw.EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 10,
      ),
      tableDirection: tableDirection,
      headerDirection: headerDirection,
      tableWidth: tableWidth,
    );
  }

  final List<String> columns;
  final List<List<String>> rows;
  final List<double> columnFlex;
  final List<pw.Alignment> columnAlignments;
  final bool reverseColumns;
  final String? emptyValue;
  final String Function(String value) valueFormatter;
  final pw.TableBorder? border;
  final pw.BoxDecoration? headerDecoration;
  final pw.BoxDecoration? rowDecoration;
  final pw.BoxDecoration? oddRowDecoration;
  final pw.TextStyle? headerStyle;
  final pw.TextStyle? cellStyle;
  final pw.EdgeInsetsGeometry cellPadding;
  final pw.EdgeInsetsGeometry? headerPadding;
  final pw.Alignment cellAlignment;
  final pw.Alignment headerAlignment;
  final pw.TextDirection tableDirection;
  final pw.TextDirection headerDirection;
  final pw.TableWidth tableWidth;

  pw.Widget build() {
    final data = displayData;
    final widths = <int, pw.TableColumnWidth>{};
    final alignments = <int, pw.Alignment>{};

    for (var index = 0; index < data.columnFlex.length; index += 1) {
      widths[index] = pw.FlexColumnWidth(data.columnFlex[index]);
    }
    for (var index = 0; index < data.columnAlignments.length; index += 1) {
      alignments[index] = data.columnAlignments[index];
    }

    return pw.Directionality(
      textDirection: tableDirection,
      child: pw.TableHelper.fromTextArray(
        headers: data.columns.map(valueFormatter).toList(growable: false),
        data: [
          for (final row in data.rows)
            row.map(valueFormatter).toList(growable: false),
        ],
        border: border,
        headerDecoration: headerDecoration,
        rowDecoration: rowDecoration,
        oddRowDecoration: oddRowDecoration,
        headerStyle: headerStyle,
        cellStyle: cellStyle,
        cellPadding: cellPadding,
        headerPadding: headerPadding,
        cellAlignment: cellAlignment,
        headerAlignment: headerAlignment,
        tableDirection: tableDirection,
        headerDirection: headerDirection,
        cellAlignments: alignments.isEmpty ? null : alignments,
        headerAlignments: alignments.isEmpty ? null : alignments,
        columnWidths: widths.isEmpty ? null : widths,
        tableWidth: tableWidth,
      ),
    );
  }

  @visibleForTesting
  PointyPdfTableDisplayData get displayData {
    final sourceRows = rows.isEmpty && emptyValue != null
        ? [
            [emptyValue!, ...List.filled(columns.length - 1, '')],
          ]
        : rows;

    return PointyPdfTableDisplayData(
      columns: _renderOrder(columns),
      rows: [for (final row in sourceRows) _renderOrder(_normalizeRow(row))],
      columnFlex: _renderMetadataOrder(columnFlex, columns.length),
      columnAlignments: _renderMetadataOrder(columnAlignments, columns.length),
    );
  }

  List<T> _renderOrder<T>(List<T> values) {
    if (!reverseColumns) {
      return values;
    }
    return values.reversed.toList(growable: false);
  }

  List<String> _normalizeRow(List<String> row) {
    if (row.length == columns.length) {
      return row;
    }
    if (row.length > columns.length) {
      return row.take(columns.length).toList(growable: false);
    }
    return [...row, ...List.filled(columns.length - row.length, '')];
  }

  List<T> _renderMetadataOrder<T>(List<T> values, int columnCount) {
    if (!reverseColumns || values.length != columnCount) {
      return values;
    }
    return values.reversed.toList(growable: false);
  }

  static String _identity(String value) => value;

  static List<pw.Alignment> invoiceColumnAlignments(int columnCount) {
    return [
      for (var index = 0; index < columnCount; index += 1)
        if (index == 0)
          pw.Alignment.centerRight
        else if (index == columnCount - 1)
          pw.Alignment.centerLeft
        else
          pw.Alignment.center,
    ];
  }
}

@visibleForTesting
class PointyPdfTableDisplayData {
  const PointyPdfTableDisplayData({
    required this.columns,
    required this.rows,
    required this.columnFlex,
    required this.columnAlignments,
  });

  final List<String> columns;
  final List<List<String>> rows;
  final List<double> columnFlex;
  final List<pw.Alignment> columnAlignments;
}

class _PointyPdfTableColors {
  static const ink = PdfColor.fromInt(0xff172026);
  static const tableHeader = PdfColor.fromInt(0xff202124);
  static const white = PdfColor.fromInt(0xffffffff);
}
