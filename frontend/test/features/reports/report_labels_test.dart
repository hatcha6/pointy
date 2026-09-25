import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/reports/report_labels.dart';

import 'balance_sheet_payload.dart';
import 'identified_payloads.dart';

/// Everything a report payload says has to reach the page in Arabic.
///
/// An unknown key prints بيان and an unknown note code prints nothing at all,
/// so neither failure is loud on screen. These walk real payloads and fail on
/// the first key or code the client cannot word.
void main() {
  final payloads = {
    for (final key in [
      'unit_aging',
      'unit_margin',
      'unit_ledger',
      'consignment_ledger',
    ])
      key: identifiedPayload(key),
    'balance_sheet': balanceSheetPayload(),
  };

  for (final MapEntry(key: report, value: payload) in payloads.entries) {
    test('$report has Arabic for every key, label cell and note it sends', () {
      final summary = payload['summary']! as Map;
      for (final metric in summary.keys) {
        expect(reportLabel('$metric'), isNot('بيان'), reason: '$metric');
      }

      for (final section in (payload['sections']! as List).cast<Map>()) {
        expect(reportLabel('${section['key']}'), isNot('بيان'));
        final types = section['column_types'] as Map? ?? const {};
        for (final column in section['columns'] as List) {
          expect(reportLabel('$column'), isNot('بيان'), reason: '$column');
        }
        for (final row in (section['rows'] as List).cast<Map>()) {
          row.forEach((column, value) {
            if (types[column] != 'label') {
              return;
            }
            expect(
              reportValue('$column', value, columnType: 'label'),
              isNot('بيان'),
              reason: '$column = $value',
            );
          });
        }
      }

      for (final note in (payload['notes']! as List).cast<Map>()) {
        expect(
          reportNote(
            '${note['code']}',
            args: (note['args'] as Map?)?.cast<String, Object?>() ?? const {},
          ),
          isNotNull,
          reason: '${note['code']}',
        );
      }
    });
  }

  test('a customer statement words every figure and line it sends', () {
    // One figure per kind of line: invoices, the goods that came back, the
    // money collected and the money handed back again.
    for (final figure in [
      'opening_balance',
      'account_entries_total',
      'invoiced_total',
      'returned_total',
      'received_total',
      'refunded_total',
      'closing_balance',
    ]) {
      expect(reportLabel(figure), isNot('بيان'), reason: figure);
      expect(reportValue(figure, '5.00'), contains('5.00'), reason: figure);
      expect(reportValue(figure, '5.00'), isNot('5.00'), reason: figure);
    }
    expect(reportLabel('returned_total'), 'المرتجعات');
    expect(reportLabel('refunded_total'), 'المبالغ المردودة');
    expect(reportLabel('account_entries_total'), 'الأرصدة والتسويات');
    expect(reportValue('kind', 'return', columnType: 'choice'), 'مرتجع');
    expect(reportValue('kind', 'refund', columnType: 'choice'), 'ردّ مبلغ');
  });

  test('an article ledger names each movement and its direction', () {
    expect(
      reportValue('voucher_type', 'purchase_receipt', columnType: 'label'),
      'استلام مشتريات',
    );
    expect(reportValue('direction', 'out', columnType: 'label'), 'صادر');
    // An article on the shelf before Pointy arrived came in as an opening
    // balance — not "أول المدة", which is a column's name.
    expect(
      reportValue('voucher_type', 'opening', columnType: 'label'),
      'رصيد افتتاحي',
    );
  });

  test('an article reads where it stands the way its own screen says it', () {
    expect(reportValue('status', 'sold'), 'مباعة');
    expect(reportValue('status', 'in_stock'), 'في المخزون');
  });

  test('the age bands say where they start and stop', () {
    expect(
      reportValue('bucket', '90-180', columnType: 'label'),
      '٩٠ – ١٧٩ يومًا',
    );
    expect(
      reportValue('bucket', '180+', columnType: 'label'),
      '١٨٠ يومًا فأكثر',
    );
  });

  test(
    'a label cell reads a treasury movement the way its choice column does',
    () {
      // The cash statement's movements used to print بيان: they were looked up
      // only among column names.
      expect(
        reportValue('component', 'drawer_in', columnType: 'label'),
        'إيداع بالدرج',
      );
      expect(
        reportValue('component', 'suppliers', columnType: 'label'),
        'موردون',
      );
    },
  );

  test('money figures in the summary block print as money', () {
    for (final metric in [
      'capital_on_shelf',
      'stale_capital',
      'consignor_payable',
      'shop_commission',
      'custody_declared_value',
    ]) {
      expect(reportValue(metric, '900.00'), '900.00 د.ل', reason: metric);
    }
    // And counts stay counts.
    expect(reportValue('custody_unit_count', 2), '2');
  });
}
