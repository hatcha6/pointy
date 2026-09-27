import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/data/services/order_document_service.dart';
import 'package:pointy_frontend/src/data/services/performed_recharges.dart';
import 'package:pointy_frontend/src/data/services/receipt_provider_slips.dart';
import 'package:pointy_frontend/src/shared/branding_assets.dart';
import 'package:pointy_frontend/src/shared/pdf/pdf.dart';

/// A card's slip opens on its brand's logo: the receipt version the provider
/// draws for it, which the server keeps ready to print and sends inline with
/// the sale (`receipt_logo`). These pin that the thermal slip and both PDFs
/// print it at the head of the card's slip, sized to the slip, and that a
/// logo which cannot be drawn costs the slip its logo, never the receipt.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = '1111222233334';
  const dial = '120$pin';
  // A 120 x 90 receipt mark: a black frame on white, as Qareeb draws them.
  final logo = base64Encode(img.encodePng(_frame(120, 90)));
  // Valid base64, but not a picture.
  final broken = base64Encode(utf8.encode('<html>404</html>'));

  group('the slip', () {
    test('a card carries its brand logo, whatever became of it', () {
      for (final status in ['confirmed', 'failed', 'submitted']) {
        final slip = receiptProviderSlip(
          title: 'ليبيانا - 5 دينار',
          kind: 'voucher',
          status: status,
          printed: const {'code': pin},
          logo: logo,
        );
        expect(slip.logo, logo, reason: status);
        expect(receiptSlipLogoBytes(slip), isNotNull);
      }
    });

    test('a top-up has no brand logo to print', () {
      final slip = receiptProviderSlip(
        title: 'HD Box',
        kind: 'recharge',
        status: 'confirmed',
        printed: const {'card_no': '1234'},
        logo: logo,
      );
      expect(slip.logo, isEmpty);
    });

    test('the thermal payload names the logo beside the PIN', () {
      final slips = receiptProviderSlipsFromPayload([
        {
          'product_name': 'ليبيانا - 5 دينار',
          'integration': {
            'kind': 'voucher',
            'status': 'confirmed',
            'printed': {'code': pin},
            'receipt_logo': logo,
          },
        },
      ], printQrCodes: true);
      expect(slips.single.logo, logo);
    });

    test('a logo that is not base64 is no logo', () {
      final slip = ReceiptProviderSlip(title: 'x', logo: '%%%');
      expect(receiptSlipLogoBytes(slip), isNull);
    });
  });

  group('the sale', () {
    test('an invoice line reads the logo, and the charge overlay keeps it', () {
      final order = _order(logo: logo, status: 'pending');
      expect(order.lines.single.integration!.receiptLogo, logo);

      final charged = orderWithPerformedRecharges(order, [
        const IntegrationChargeResult(
          fulfillment: 99,
          outcome: 'charged',
          orderLine: 1,
          kind: 'voucher',
          providerReference: 'ref-1',
          receipt: {'code': pin, 'dial': dial},
        ),
      ]);
      final integration = charged.lines.single.integration!;
      expect(integration.isConfirmed, isTrue);
      expect(integration.receiptLogo, logo);

      final slip = const OrderDocumentService()
          .saleInvoiceTemplate(order: charged)
          .providerSlips
          .single;
      expect(slip.logo, logo);
      expect(slip.pin, pin);
    });
  });

  group('the thermal slip', () {
    const encoder = EscPosReceiptEncoder(brandLogoLoader: _NoBrandLogo());
    const endpoint = PrinterEndpoint(
      kind: PrintTransportKind.fake,
      name: 'till',
      paperWidthMm: 58,
    );

    Map<String, Object?> payload(String cardLogo) => {
      'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
      'order': {
        'receipt_number': 'R-1',
        'document_title': 'RECEIPT',
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
              'printed': {'code': pin, 'dial': dial},
              'receipt_logo': cardLogo,
            },
          },
        ],
      },
    };

    for (final compact in [false, true]) {
      test(
        'the logo heads the slip, above its title (compact: $compact)',
        () async {
          final bytes = await encoder.encodePayload(
            payload: payload(logo),
            endpoint: endpoint.copyWith(compactReceipt: compact),
          );
          final rasters = _rasters(bytes);
          // The logo, then the card's QR code.
          expect(rasters, hasLength(2));
          final mark = rasters.first;
          expect(mark.offset, lessThan(_indexOf(bytes, 'LIBYANA 5')));
          expect(_indexOf(bytes, 'LIBYANA 5'), lessThan(rasters.last.offset));
          // Fitted into the slip's box: 12 mm tall (9 mm compact), at most half
          // the 384-dot head across, proportions kept (120 x 90 -> 128 x 96).
          expect(mark.height, compact ? 72 : 96);
          expect(mark.widthBytes * 8, compact ? 96 : 128);
          expect(mark.widthBytes * 8, lessThanOrEqualTo(192));
        },
      );
    }

    test('no logo, no picture: the slip prints as it did', () async {
      final bytes = await encoder.encodePayload(
        payload: payload(''),
        endpoint: endpoint,
      );
      expect(_rasters(bytes), hasLength(1));
    });

    test(
      'a logo that cannot be drawn costs the logo, not the receipt',
      () async {
        final bytes = await encoder.encodePayload(
          payload: payload(broken),
          endpoint: endpoint,
        );
        expect(_rasters(bytes), hasLength(1));
        expect(_indexOf(bytes, pin), greaterThan(0));
      },
    );
  });

  group('the PDF', () {
    const service = OrderDocumentService(
      fontLoader: _TestFontLoader(),
      brandLogoLoader: _NoBrandLogo(),
    );

    for (final pageSize in PdfPageSize.values) {
      test('the logo is drawn on the $pageSize slip', () async {
        final withLogo = await service.buildSaleInvoiceRender(
          order: _order(logo: logo),
          pageSize: pageSize,
        );
        final without = await service.buildSaleInvoiceRender(
          order: _order(logo: ''),
          pageSize: pageSize,
        );
        final undrawable = await service.buildSaleInvoiceRender(
          order: _order(logo: broken),
          pageSize: pageSize,
        );
        // The picture, and the alpha mask the pdf package writes beside it.
        expect(_images(withLogo.bytes), greaterThan(0));
        expect(_images(without.bytes), 0);
        expect(_images(undrawable.bytes), 0);
        expect(undrawable.bytes, isNotEmpty);
        // On a roll the page is as tall as its content: the logo takes paper.
        if (withLogo.mediaHeightMm != null) {
          expect(withLogo.mediaHeightMm!, greaterThan(without.mediaHeightMm!));
        }
      });
    }
  });
}

SaleOrder _order({required String logo, String status = 'confirmed'}) {
  return SaleOrder.fromJson({
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
          'status': status,
          'receipt': {'code': '1111222233334'},
          'receipt_logo': logo,
        },
      },
    ],
    'payments': [],
  });
}

/// A black frame four pixels thick on white: ink at every edge, so nothing
/// trims away.
img.Image _frame(int width, int height) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  img.drawRect(
    image,
    x1: 0,
    y1: 0,
    x2: width - 1,
    y2: height - 1,
    color: img.ColorRgb8(0, 0, 0),
    thickness: 4,
  );
  return img.grayscale(image);
}

/// Every `GS v 0` raster in an ESC/POS stream: where it starts, and its size.
List<({int offset, int widthBytes, int height})> _rasters(List<int> bytes) {
  final found = <({int offset, int widthBytes, int height})>[];
  var i = 0;
  while (i + 7 < bytes.length) {
    if (bytes[i] == 0x1D && bytes[i + 1] == 0x76 && bytes[i + 2] == 0x30) {
      final widthBytes = bytes[i + 4] | bytes[i + 5] << 8;
      final height = bytes[i + 6] | bytes[i + 7] << 8;
      found.add((offset: i, widthBytes: widthBytes, height: height));
      i += 8 + widthBytes * height;
      continue;
    }
    i++;
  }
  return found;
}

int _indexOf(List<int> bytes, String ascii) {
  final needle = latin1.encode(ascii);
  for (var i = 0; i + needle.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

/// Image XObjects in a PDF: their dictionaries stay readable when the
/// streams are compressed.
int _images(Uint8List pdf) =>
    RegExp('/Subtype\\s*/Image').allMatches(latin1.decode(pdf)).length;

class _NoBrandLogo extends PointyBrandLogoLoader {
  const _NoBrandLogo();

  @override
  Future<Uint8List?> load() async => null;
}

class _TestFontLoader extends PointyPdfFontLoader {
  const _TestFontLoader();

  @override
  Future<PointyPdfFontData> loadData() async => const Type1PointyPdfFontData();
}
