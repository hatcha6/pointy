import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const encoder = EscPosReceiptEncoder();
  const endpoint = PrinterEndpoint(
    kind: PrintTransportKind.fake,
    name: 'kitchen',
    paperWidthMm: 80,
  );

  String asciiOf(List<int> bytes) =>
      String.fromCharCodes(bytes.where((b) => b >= 32 && b < 127));

  test(
    'kitchen payload prints station, item and note but never money',
    () async {
      final bytes = await encoder.encodePayload(
        endpoint: endpoint,
        payload: {
          'kind': 'kitchen',
          'station': {'id': 1, 'name': 'GRILL'},
          'order': {
            'receipt_number': 'R-100',
            'created_at': '2026-06-13T10:00:00',
            'document_title': 'KITCHEN',
            // Money fields are deliberately present to prove the kitchen layout
            // ignores them.
            'total': '99.99',
            'lines': [
              {
                'name': 'Burger',
                'quantity': 2,
                'notes': 'no onions',
                'unit_price': '88.88',
                'line_total': '99.99',
                'option_values': [
                  {'option_name': 'Size', 'value_name': 'Large'},
                ],
              },
            ],
          },
        },
      );

      final text = asciiOf(bytes);
      expect(text, contains('GRILL'));
      expect(text, contains('Burger'));
      expect(text, contains('no onions'));
      expect(text, contains('Large'));
      expect(text, isNot(contains('88.88')));
      expect(text, isNot(contains('99.99')));
    },
  );

  test('receipt payload (no kind) still prints prices', () async {
    final bytes = await encoder.encodePayload(
      endpoint: endpoint,
      payload: {
        'shop': {'name': 'SHOP'},
        'order': {
          'receipt_number': 'R-200',
          'total': '99.99',
          'lines': [
            {
              'name': 'Burger',
              'quantity': 2,
              'unit_price': '88.88',
              'line_total': '99.99',
            },
          ],
        },
      },
    );

    expect(asciiOf(bytes), contains('99.99'));
  });
}
