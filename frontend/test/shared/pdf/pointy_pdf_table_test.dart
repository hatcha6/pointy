import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pointy_frontend/src/shared/pdf/pointy_pdf_table.dart';

void main() {
  test('reverses columns, rows, widths, and alignments together', () {
    const table = PointyPdfTable(
      columns: ['الصنف', 'الكمية', 'السعر', 'الإجمالي'],
      rows: [
        ['دفتر', '2', '5.00', '10.00'],
      ],
      columnFlex: [2.8, 0.8, 1.1, 1.1],
      columnAlignments: [
        pw.Alignment.centerRight,
        pw.Alignment.center,
        pw.Alignment.center,
        pw.Alignment.centerLeft,
      ],
    );

    final data = table.displayData;

    expect(data.columns, ['الإجمالي', 'السعر', 'الكمية', 'الصنف']);
    expect(data.rows.single, ['10.00', '5.00', '2', 'دفتر']);
    expect(data.columnFlex, [1.1, 1.1, 0.8, 2.8]);
    expect(data.columnAlignments, [
      pw.Alignment.centerLeft,
      pw.Alignment.center,
      pw.Alignment.center,
      pw.Alignment.centerRight,
    ]);
  });

  test('normalizes ragged rows before reversing display order', () {
    const table = PointyPdfTable(
      columns: ['الصنف', 'الكمية', 'السعر'],
      rows: [
        ['قلم', '3'],
        ['دفتر', '2', '5.00', 'زائد'],
      ],
    );

    final data = table.displayData;

    expect(data.rows, [
      ['', '3', 'قلم'],
      ['5.00', '2', 'دفتر'],
    ]);
  });

  test(
    'keeps partial metadata in source order because mapping is ambiguous',
    () {
      const table = PointyPdfTable(
        columns: ['الصنف', 'الكمية', 'السعر', 'الإجمالي'],
        rows: [
          ['دفتر', '2', '5.00', '10.00'],
        ],
        columnFlex: [2.8, 0.8],
      );

      expect(table.displayData.columnFlex, [2.8, 0.8]);
    },
  );

  test('builds tables at full available PDF width by default', () {
    const table = PointyPdfTable(
      columns: ['الصنف', 'الكمية'],
      rows: [
        ['دفتر', '2'],
      ],
    );

    final widget = table.build() as pw.Directionality;
    final pdfTable = widget.child as pw.Table;

    expect(pdfTable.tableWidth, pw.TableWidth.max);
  });

  test('invoice style is full width, borderless, and edge aligned', () {
    final table = PointyPdfTable.invoice(
      columns: ['الصنف', 'الكمية', 'الإجمالي'],
      rows: [
        ['دفتر', '2', '10.00'],
      ],
    );

    final data = table.displayData;
    final widget = table.build() as pw.Directionality;
    final pdfTable = widget.child as pw.Table;

    expect(data.columnAlignments, [
      pw.Alignment.centerLeft,
      pw.Alignment.center,
      pw.Alignment.centerRight,
    ]);
    expect(pdfTable.border, isNull);
    expect(pdfTable.tableWidth, pw.TableWidth.max);
    expect(pdfTable.children.first.decoration, isNotNull);
  });
}
