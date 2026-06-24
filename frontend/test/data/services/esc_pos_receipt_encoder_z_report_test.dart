import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const encoder = EscPosReceiptEncoder();
  const endpoint = PrinterEndpoint(
    kind: PrintTransportKind.fake,
    name: 'z-report',
    paperWidthMm: 80,
  );

  // ASCII-only view of the bytes — the real report labels are Arabic (stripped
  // here), but the title/meta/values we assert on are passed as ASCII below.
  String asciiOf(List<int> bytes) =>
      String.fromCharCodes(bytes.where((b) => b >= 32 && b < 127));

  test(
    'z_report payload prints title, meta, section rows and totals',
    () async {
      final bytes = await encoder.encodePayload(
        endpoint: endpoint,
        payload: {
          'kind': 'z_report',
          'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
          'report': {
            'title': 'Z-REPORT',
            'meta': ['RS-1', 'CASHIER: ALICE'],
            'sections': [
              {
                'title': 'SALES',
                'rows': [
                  {'label': 'NET', 'value': '110.00 LYD', 'emphasize': true},
                ],
              },
              {
                'title': 'PAYMENTS',
                'rows': [
                  {'label': 'CASH (5)', 'value': '55.00 LYD'},
                  {'label': 'CARD (2)', 'value': '40.00 LYD'},
                ],
                'total': {'label': 'TOTAL', 'value': '95.00 LYD'},
              },
              {
                'title': 'CATEGORIES',
                'rows': [
                  {'label': 'DRINKS x3', 'value': '30.00 LYD'},
                ],
              },
            ],
          },
        },
      );

      final text = asciiOf(bytes);
      expect(bytes, isNotEmpty);
      expect(text, contains('SHOP'));
      expect(text, contains('Z-REPORT'));
      expect(text, contains('RS-1'));
      expect(text, contains('NET'));
      expect(text, contains('110.00'));
      expect(text, contains('CASH (5)'));
      expect(text, contains('CARD (2)'));
      expect(text, contains('TOTAL'));
      expect(text, contains('95.00'));
      expect(text, contains('DRINKS x3'));
    },
  );

  test('z_report skips sections that have no rows and no total', () async {
    final bytes = await encoder.encodePayload(
      endpoint: endpoint,
      payload: {
        'kind': 'z_report',
        'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
        'report': {
          'title': 'Z-REPORT',
          'meta': const <String>[],
          'sections': [
            {'title': 'EMPTY', 'rows': const <Object?>[]},
            {
              'title': 'CASH',
              'rows': [
                {'label': 'OPENING', 'value': '50.00 LYD'},
              ],
            },
          ],
        },
      },
    );

    final text = asciiOf(bytes);
    expect(text, isNot(contains('EMPTY')));
    expect(text, contains('OPENING'));
  });
}
