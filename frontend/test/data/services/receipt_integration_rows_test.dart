import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/data/services/order_document_service.dart';
import 'package:pointy_frontend/src/data/services/receipt_integration_rows.dart';
import 'package:pointy_frontend/src/shared/branding_assets.dart';

/// One receipt carries everything a provider did for a sale: a card's PIN
/// beneath its line, a subscriber's new term beneath theirs. These pin that
/// the thermal slip and the PDF (A4 and roll) print it, and that a provider
/// that did not confirm is never printed as if it had.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the rows beneath a provider line', () {
    test('a card prints its PIN, emphasized, then how to use it', () {
      final rows = receiptIntegrationRows(
        kind: 'voucher',
        status: 'confirmed',
        printed: const {
          'code': '1111222233334',
          'serial': '123456789012345',
          'instructions': '# الرقم السري * 120 *',
        },
      );

      expect(rows.where((row) => row.emphasized).single.text, '1111222233334');
      expect(
        rows.map((row) => row.text),
        contains(contains('123456789012345')),
      );
      expect(rows.map((row) => row.text), contains(contains('* 120 *')));
    });

    test('a card nobody confirmed says so and prints no PIN', () {
      final rows = receiptIntegrationRows(
        kind: 'voucher',
        status: 'pending',
        printed: const {'code': 'SHOULD-NOT-PRINT'},
      );

      expect(rows, hasLength(1));
      expect(rows.single.emphasized, isFalse);
      expect(rows.single.text, isNot(contains('SHOULD-NOT-PRINT')));
    });

    test('an unknown outcome warns against trying again', () {
      final rows = receiptIntegrationRows(
        kind: 'recharge',
        status: 'submitted',
        printed: const {},
      );
      expect(rows.single.text, contains('لا تُعِد المحاولة'));
    });

    test('a top-up names the line, the term and the serial', () {
      final hdbox = receiptIntegrationRows(
        kind: 'recharge',
        status: 'confirmed',
        subscriberRef: '210906803499',
        printed: const {
          'card_no': '210906803499',
          'months': '1',
          'start_date': '2026-09-20',
          'end_date': '2026-10-20',
        },
      ).map((row) => row.text);
      expect(hdbox, contains(contains('210906803499')));
      expect(hdbox, contains(contains('2026-10-20')));

      final lnet = receiptIntegrationRows(
        kind: 'recharge',
        status: 'confirmed',
        printed: const {
          'username': 'basheir',
          'amount': '45',
          'serial': 'SN-9',
        },
      ).map((row) => row.text);
      expect(lnet, contains(contains('basheir')));
      expect(lnet, contains(contains('SN-9')));
    });

    test('an ordinary line has none', () {
      expect(receiptIntegrationRowsFromPayload(null), isEmpty);
    });
  });

  group('the thermal slip', () {
    const encoder = EscPosReceiptEncoder(brandLogoLoader: _NoBrandLogo());
    final payload = {
      'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
      'order': {
        'receipt_number': 'R-1',
        'total': '5.00',
        'payment_status': 'paid',
        'lines': [
          {
            'name': 'LIBYANA 5',
            'quantity': '1',
            'unit_price': '5.00',
            'line_total': '5.00',
            'integration': {
              'kind': 'voucher',
              'status': 'confirmed',
              'printed': {'code': '1111222233334', 'serial': '123456789012345'},
            },
          },
        ],
      },
    };

    for (final compact in [false, true]) {
      test('prints the PIN beneath its line (compact: $compact)', () async {
        final bytes = await encoder.encodePayload(
          payload: payload,
          endpoint: const PrinterEndpoint(
            kind: PrintTransportKind.fake,
            name: 'till',
            paperWidthMm: 58,
          ).copyWith(compactReceipt: compact),
        );
        final text = String.fromCharCodes(
          bytes.where((b) => b >= 0x20 && b < 0x7F),
        );
        expect(text, contains('1111222233334'));
        expect(text, contains('123456789012345'));
      });
    }
  });

  group('the PDF', () {
    test('a card line carries its PIN as its own emphasized note', () {
      final order = SaleOrder.fromJson({
        'id': 7,
        'receipt_number': 'R-7',
        'status': 'paid',
        'subtotal': '5.00',
        'discount_total': '0',
        'total': '5.00',
        'lines': [
          {
            'id': 1,
            'product': 2,
            'variant': 3,
            'product_name': 'ليبيانا',
            'variant_name': '5 دينار',
            'quantity': '1',
            'returned_quantity': '0',
            'returnable_quantity': '1',
            'unit_price': '5.00',
            'line_total': '5.00',
            'integration': {
              'provider': 'qareeb',
              'kind': 'voucher',
              'subscriber_ref': '',
              'status': 'confirmed',
              'receipt': {'code': '1111222233334', 'serial': '123456789012345'},
            },
          },
        ],
        'payments': [],
      });

      final template = const OrderDocumentService().saleInvoiceTemplate(
        order: order,
      );
      final table = template.itemsTable!;

      // The name stays a name; the PIN is a line of its own, never folded
      // into it where the table's clean-up would flatten or clip it.
      expect(table.rows.single.first, 'ليبيانا - 5 دينار');
      final notes = table.notesFor(0);
      expect(
        notes.where((note) => note.emphasized).single.text,
        '1111222233334',
      );
      expect(
        notes.map((note) => note.text),
        contains(contains('123456789012345')),
      );
    });
  });
}

class _NoBrandLogo extends PointyBrandLogoLoader {
  const _NoBrandLogo();

  @override
  Future<Uint8List?> load() async => null;
}
