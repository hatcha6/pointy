import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/data/services/order_document_service.dart';
import 'package:pointy_frontend/src/data/services/provider_slip_raster.dart';
import 'package:pointy_frontend/src/data/services/receipt_provider_slips.dart';
import 'package:pointy_frontend/src/shared/branding_assets.dart';
import 'package:pointy_frontend/src/shared/pdf/pdf.dart';
import 'package:pointy_frontend/src/shared/printing/print_qr_code.dart';

/// Everything a provider did for a sale prints once, at the top of its
/// receipt, a block per line: a card's PIN and QR code (and, for a card its
/// operator redeems by dialling, the string to dial), a top-up's line and
/// term, each under its logo. These pin that the thermal slip and the PDF
/// (A4 and roll) print it there and not beneath the line, that the QR code
/// follows the shop's setting, and that a provider that did not confirm is
/// never printed as if it had.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = '1111222233334';
  const libyanaDial = '120$pin';
  const almadarDial = '*112*$pin#';

  group('the slip for a provider line', () {
    test('a Libyana card: its PIN, the call to 120 and its QR code', () {
      final slip = receiptProviderSlip(
        title: 'ليبيانا - 5 دينار',
        kind: 'voucher',
        status: 'confirmed',
        printed: const {
          'code': pin,
          'serial': '123456789012345',
          'dial': libyanaDial,
          // Qareeb's own slip names *120*PIN#; Libyana publishes a call to
          // 120. The dial string replaces it rather than contradict it.
          'instructions': '# الرقم السري * 120 *',
          'help': 'لاي استفسارات الرجاء الاتصال',
        },
      );

      expect(slip.title, 'ليبيانا - 5 دينار');
      expect(slip.notice, isEmpty);
      expect(slip.pin, pin);
      expect(slip.dial, libyanaDial);
      expect(slip.qrData, 'tel:$libyanaDial');
      expect(slip.qrCaption, receiptScanToRedeem);
      expect(slip.rows, [
        'الرقم التسلسلي: 123456789012345',
        'لاي استفسارات الرجاء الاتصال',
      ]);
    });

    test('an Almadar card dials its USSD code, # escaped in the link', () {
      final slip = receiptProviderSlip(
        title: 'المدار - 10 دينار',
        kind: 'voucher',
        status: 'confirmed',
        printed: const {'code': pin, 'dial': almadarDial},
      );
      expect(slip.dial, almadarDial);
      expect(slip.qrData, 'tel:*112*$pin%23');
    });

    test('a shop that prints no QR codes still prints the dial string', () {
      final slip = receiptProviderSlip(
        title: 'ليبيانا - 5 دينار',
        kind: 'voucher',
        status: 'confirmed',
        printed: const {'code': pin, 'dial': libyanaDial},
        printQrCodes: false,
      );
      expect(slip.qrData, isNull);
      expect(slip.dial, libyanaDial);
      expect(slip.pin, pin);
    });

    test('a card nobody dials codes its PIN, to copy, and keeps the '
        'provider\'s own instructions', () {
      final slip = receiptProviderSlip(
        title: 'LTT - 10 دينار',
        kind: 'voucher',
        status: 'confirmed',
        printed: const {'code': pin, 'instructions': 'من موقع LTT'},
      );
      expect(slip.dial, isEmpty);
      expect(slip.qrData, pin);
      expect(slip.qrCaption, receiptScanToCopyPin);
      expect(slip.rows, ['طريقة الشحن: من موقع LTT']);
    });

    test('every card with a PIN a phone can read gets a code', () {
      for (final code in ['481246145737', 'X4K9-2LMQ-77ZP-QQ01', 'AB CD 12']) {
        final slip = receiptProviderSlip(
          title: 'X',
          kind: 'voucher',
          status: 'confirmed',
          printed: {'code': code},
        );
        expect(slip.qrData, code, reason: code);
      }
      // Arabic-Indic digits, and a code too long for a receipt: none.
      for (final code in ['١٢٣٤٥٦٧٨', 'A' * 65, '12']) {
        final slip = receiptProviderSlip(
          title: 'X',
          kind: 'voucher',
          status: 'confirmed',
          printed: {'code': code},
        );
        expect(slip.qrData, isNull, reason: code);
        expect(slip.pin, code);
      }
    });

    test('a dial string that is not one is not printed; the PIN is coded '
        'instead', () {
      for (final dial in ['tel:120', 'call 120', '*112* 1111#']) {
        final slip = receiptProviderSlip(
          title: 'X',
          kind: 'voucher',
          status: 'confirmed',
          printed: {'code': pin, 'dial': dial},
        );
        expect(slip.dial, isEmpty, reason: dial);
        expect(slip.qrData, pin, reason: dial);
      }
    });

    test('a card opens on its brand with its provider\'s mark beside it; '
        'a top-up on its provider, once', () {
      final card = receiptProviderSlip(
        title: 'ليبيانا - 5 دينار',
        kind: 'voucher',
        status: 'confirmed',
        logo: 'BRAND',
        providerLogo: 'QAREEB',
        printed: const {'code': pin},
      );
      expect(card.logo, 'BRAND');
      expect(card.providerLogo, 'QAREEB');

      final topUp = receiptProviderSlip(
        title: 'شحن HD Box',
        kind: 'recharge',
        status: 'confirmed',
        logo: 'HDBOX',
        providerLogo: 'HDBOX',
        printed: const {'card_no': '210906803499'},
      );
      expect(topUp.logo, 'HDBOX');
      expect(topUp.providerLogo, isEmpty);

      // Whatever became of the card, the slip keeps both.
      final failed = receiptProviderSlip(
        title: 'ليبيانا - 5 دينار',
        kind: 'voucher',
        status: 'failed',
        logo: 'BRAND',
        providerLogo: 'QAREEB',
        printed: const {},
      );
      expect((failed.logo, failed.providerLogo), ('BRAND', 'QAREEB'));
    });

    test('a card nobody confirmed says so and prints nothing usable', () {
      final slip = receiptProviderSlip(
        title: 'ليبيانا - 5 دينار',
        kind: 'voucher',
        status: 'pending',
        printed: const {'code': 'SHOULD-NOT-PRINT', 'dial': libyanaDial},
      );

      expect(slip.notice, 'لم يتم إصدار الكرت');
      expect(slip.pin, isEmpty);
      expect(slip.dial, isEmpty);
      expect(slip.qrData, isNull);
      expect(slip.rows, isEmpty);
    });

    test('an unknown outcome warns against trying again', () {
      final slip = receiptProviderSlip(
        title: 'شحن HD Box',
        kind: 'recharge',
        status: 'submitted',
        printed: const {},
      );
      expect(slip.notice, contains('لا تُعِد المحاولة'));
    });

    test('a top-up names the line, the term and the serial', () {
      final hdbox = receiptProviderSlip(
        title: 'شحن HD Box',
        kind: 'recharge',
        status: 'confirmed',
        subscriberRef: '210906803499',
        printed: const {
          'card_no': '210906803499',
          'months': '1',
          'start_date': '2026-09-20',
          'end_date': '2026-10-20',
        },
      );
      expect(hdbox.pin, isEmpty);
      expect(hdbox.qrData, isNull);
      expect(hdbox.rows, [
        'رقم الكرت: 210906803499',
        'المدة: 1 شهر',
        'يبدأ: 2026-09-20',
        'ينتهي: 2026-10-20',
      ]);

      final lnet = receiptProviderSlip(
        title: 'شحن LNET',
        kind: 'recharge',
        status: 'confirmed',
        printed: const {
          'username': 'basheir',
          'amount': '45',
          'serial': 'SN-9',
        },
      );
      expect(lnet.rows, contains('المشترك: basheir'));
      expect(lnet.rows, contains('الرقم التسلسلي: SN-9'));
    });

    test('lines no provider performed have no slip', () {
      expect(
        receiptProviderSlipsFromPayload(null, printQrCodes: true),
        isEmpty,
      );
      expect(
        receiptProviderSlipsFromPayload(const [
          {'name': 'WIDGET', 'integration': null},
        ], printQrCodes: true),
        isEmpty,
      );
    });
  });

  group('the thermal slip', () {
    // The slips drawn as pictures, as every till prints them...
    const encoder = EscPosReceiptEncoder(brandLogoLoader: _NoBrandLogo());
    // ...and as text, what a till prints when drawing fails.
    const textEncoder = EscPosReceiptEncoder(
      brandLogoLoader: _NoBrandLogo(),
      slipRasterizer: TextOnlySlipRasterizer(),
    );
    const endpoint = PrinterEndpoint(
      kind: PrintTransportKind.fake,
      name: 'till',
      paperWidthMm: 58,
    );

    Map<String, Object?> payload({
      bool? printQr,
      Map<String, Object?>? integration,
    }) => {
      'shop': {
        'name': 'SHOP',
        'currency_symbol': 'LYD',
        'print_voucher_qr_codes': ?printQr,
      },
      'order': {
        'receipt_number': 'R-1',
        'document_title': 'RECEIPT',
        'total_label': 'TOTAL',
        'total': '25.00',
        'payment_status': 'paid',
        'lines': [
          {
            'name': 'BREAD',
            'quantity': '4',
            'unit_price': '5.00',
            'line_total': '20.00',
          },
          {
            'name': 'LIBYANA 5',
            'quantity': '1',
            'unit_price': '5.00',
            'line_total': '5.00',
            'integration':
                integration ??
                {
                  'kind': 'voucher',
                  'status': 'confirmed',
                  'printed': {
                    'code': pin,
                    'serial': '123456789012345',
                    'dial': libyanaDial,
                  },
                },
          },
        ],
      },
    };

    for (final compact in [false, true]) {
      test('draws the card as a framed picture above the invoice '
          '(compact: $compact)', () async {
        final bytes = await encoder.encodePayload(
          payload: payload(),
          endpoint: endpoint.copyWith(compactReceipt: compact),
        );
        final slip = _SlipLines.parse(bytes);

        // One slip, 360 dots wide (the 58 mm head less 3 mm), before any
        // text of the invoice; its PIN is in the picture, never in the text.
        expect(slip.rasters, isNotEmpty);
        expect(slip.rasters.map((r) => r[4] | r[5] << 8).toSet(), {45});
        expect(slip.firstRasterLine, 1);
        expect(slip.text[slip.firstRasterLine], contains('RECEIPT: R-1'));
        expect(slip.text.where((l) => l.contains(pin)), isEmpty);
        expect(slip.text.last, isNot(contains(pin)));
      });

      test('as text, prints the card above the invoice, not beneath its '
          'line (compact: $compact)', () async {
        final bytes = await textEncoder.encodePayload(
          payload: payload(),
          endpoint: endpoint.copyWith(compactReceipt: compact),
        );
        final lines = _SlipLines.parse(bytes).text;

        final pinAt = lines.indexOf(pin);
        expect(pinAt, greaterThanOrEqualTo(0), reason: '$lines');
        expect(lines.indexOf(libyanaDial), greaterThan(pinAt));
        expect(lines, contains('الرقم التسلسلي: 123456789012345'));
        // Framed, and first: the invoice header and the card's own item line
        // are both below it, and the PIN prints once — never again beneath
        // the line that sold it.
        final invoiceAt = lines.indexWhere((l) => l.contains('RECEIPT: R-1'));
        // The slip is titled with the line's own name, so the item line is
        // the second time it appears.
        final itemAt = lines.lastIndexWhere((l) => l.startsWith('LIBYANA 5'));
        expect(
          lines.indexWhere((l) => l.startsWith('LIBYANA 5')),
          lessThan(pinAt),
        );
        expect(pinAt, lessThan(invoiceAt));
        expect(invoiceAt, lessThan(itemAt));
        expect(lines.where((l) => l == pin), hasLength(1));
        expect(lines.skip(invoiceAt).where((l) => l.contains(pin)), isEmpty);
        expect(lines.where((l) => RegExp(r'^=+$').hasMatch(l)), hasLength(2));
      });
    }

    test('as text, the QR code is the dial link at 8 dots a module', () async {
      final bytes = await textEncoder.encodePayload(
        payload: payload(),
        endpoint: endpoint,
      );
      final rasters = _SlipLines.parse(bytes).rasters;

      final expected = escPosQrRaster(
        PrintQrCode.tryEncode('tel:$libyanaDial')!,
        // A 25-module symbol + quiet zone = 33 modules: 10 dots would fit
        // 360, and 8 (a millimetre) is the most a slip gives a code.
        moduleDots: 8,
      );
      expect(rasters, [expected]);
    });

    test('as text, an 80 mm roll prints the same code at 8 dots', () async {
      final bytes = await textEncoder.encodePayload(
        payload: payload(
          integration: {
            'kind': 'voucher',
            'status': 'confirmed',
            'printed': {'code': pin, 'dial': almadarDial},
          },
        ),
        endpoint: endpoint.copyWith(paperWidthMm: 80),
      );
      expect(_SlipLines.parse(bytes).rasters, [
        escPosQrRaster(
          PrintQrCode.tryEncode('tel:*112*$pin%23')!,
          moduleDots: 8,
        ),
      ]);
    });

    test(
      'as text, a shop that turned QR codes off gets the dial string alone',
      () async {
        final bytes = await textEncoder.encodePayload(
          payload: payload(printQr: false),
          endpoint: endpoint,
        );
        final slip = _SlipLines.parse(bytes);
        expect(slip.rasters, isEmpty);
        expect(slip.text, contains(libyanaDial));
        expect(slip.text, contains(receiptDialToRedeem));
      },
    );

    test(
      'as text, a top-up prints its line and term in the same place',
      () async {
        final bytes = await textEncoder.encodePayload(
          payload: payload(
            integration: {
              'kind': 'recharge',
              'status': 'confirmed',
              'subscriber_ref': '210906803499',
              'printed': {'card_no': '210906803499', 'months': '1'},
            },
          ),
          endpoint: endpoint,
        );
        final slip = _SlipLines.parse(bytes);
        expect(slip.rasters, isEmpty);
        final cardAt = slip.text.indexOf('رقم الكرت: 210906803499');
        expect(cardAt, greaterThanOrEqualTo(0), reason: '${slip.text}');
        expect(
          cardAt,
          lessThan(slip.text.indexWhere((l) => l.contains('RECEIPT: R-1'))),
        );
      },
    );

    test('a receipt with no provider line is laid out as it was', () async {
      final ordinary = payload();
      final order = ordinary['order']! as Map<String, Object?>;
      order['lines'] = [(order['lines']! as List).first];
      for (final withEncoder in [encoder, textEncoder]) {
        final bytes = await withEncoder.encodePayload(
          payload: ordinary,
          endpoint: endpoint,
        );
        final slip = _SlipLines.parse(bytes);
        expect(slip.rasters, isEmpty);
        expect(slip.text.where((l) => l.startsWith('=')), isEmpty);
      }
    });

    test('as text, a card prints its logo with its provider\'s mark beside '
        'it, as one picture', () async {
      String png(int width, int height) {
        final picture = img.Image(width: width, height: height);
        img.fill(picture, color: img.ColorRgb8(0, 0, 0));
        return base64Encode(img.encodePng(picture));
      }

      final bytes = await textEncoder.encodePayload(
        payload: payload(
          integration: {
            'kind': 'voucher',
            'status': 'confirmed',
            'receipt_logo': png(118, 118),
            'provider_logo': png(80, 60),
            'printed': {'code': pin, 'dial': libyanaDial},
          },
        ),
        endpoint: endpoint,
      );
      final rasters = _SlipLines.parse(bytes).rasters;
      // The logos, then the QR code: two pictures, not three.
      expect(rasters, hasLength(2));
      final logos = rasters.first;
      final widthDots = (logos[4] | logos[5] << 8) * 8;
      final height = logos[6] | logos[7] << 8;
      // 72 dots tall: the brand's box; the mark beside it, not above it.
      expect(height, 72);
      expect(widthDots, greaterThan(72 + 24));
    });
  });

  group('the PDF', () {
    SaleOrder order({String dial = libyanaDial, String status = 'confirmed'}) {
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
              'receipt': {
                'code': pin,
                'serial': '123456789012345',
                'dial': dial,
              },
            },
          },
        ],
        'payments': [],
      });
    }

    test('the card is a slip of its own, not a note beneath its line', () {
      final template = const OrderDocumentService().saleInvoiceTemplate(
        order: order(),
      );

      expect(template.itemsTable!.rows.single.first, 'ليبيانا - 5 دينار');
      expect(template.itemsTable!.notesFor(0), isEmpty);
      final slip = template.providerSlips.single;
      expect(slip.title, 'ليبيانا - 5 دينار');
      expect(slip.pin, pin);
      expect(slip.qrData, 'tel:$libyanaDial');
    });

    test('the shop setting decides the QR code on the page too', () {
      final template = const OrderDocumentService().saleInvoiceTemplate(
        order: order(),
        shopSettings: _settings(printVoucherQrCodes: false),
      );
      final slip = template.providerSlips.single;
      expect(slip.qrData, isNull);
      expect(slip.dial, libyanaDial);
    });

    for (final pageSize in PdfPageSize.values) {
      test('renders the slip on $pageSize', () async {
        const service = OrderDocumentService(fontLoader: _TestFontLoader());
        final withQr = await service.buildSaleInvoiceRender(
          order: order(),
          pageSize: pageSize,
        );
        final withoutQr = await service.buildSaleInvoiceRender(
          order: order(),
          pageSize: pageSize,
          shopSettings: _settings(printVoucherQrCodes: false),
        );
        expect(withQr.bytes, isNotEmpty);
        // On a roll the page is as tall as its content, and the code sits
        // beside the PIN: it costs a little paper, not a code's height.
        if (withQr.mediaHeightMm != null) {
          expect(withQr.mediaHeightMm!, greaterThan(withoutQr.mediaHeightMm!));
          expect(
            withQr.mediaHeightMm!,
            lessThan(withoutQr.mediaHeightMm! + 25),
          );
        }
      });
    }

    // POINTY_SLIP_DUMP=<dir> writes the invoice of a sale with a card and a
    // top-up on every page size, in the real fonts, to rasterise and look at
    // (`pdftoppm -png -r 203`). POINTY_SLIP_LOGOS=<dir> supplies the logos.
    final dumpDir = Platform.environment['POINTY_SLIP_DUMP'];
    test('dumps the slips to look at', skip: dumpDir == null, () async {
      String logo(String name) {
        final file = File(
          '${Platform.environment['POINTY_SLIP_LOGOS']}/$name.png',
        );
        return file.existsSync() ? base64Encode(file.readAsBytesSync()) : '';
      }

      final sale = SaleOrder.fromJson({
        'id': 8,
        'receipt_number': 'R-8',
        'status': 'paid',
        'subtotal': '60.00',
        'discount_total': '0',
        'total': '60.00',
        'lines': [
          {
            'id': 1,
            'product': 2,
            'variant': 3,
            'product_name': 'المدار',
            'variant_name': '10 دينار',
            'quantity': '1',
            'returned_quantity': '0',
            'returnable_quantity': '1',
            'unit_price': '10.00',
            'line_total': '10.00',
            'integration': {
              'provider': 'qareeb',
              'kind': 'voucher',
              'subscriber_ref': '',
              'status': 'confirmed',
              'receipt_logo': logo('almadar'),
              'provider_logo': logo('qareeb'),
              'receipt': {
                'code': pin,
                'serial': '439882298872854',
                'dial': almadarDial,
                'help':
                    'لاي استفسارات الرجاء الاتصال على الرقم التالي 0946358319',
              },
            },
          },
          {
            'id': 2,
            'product': 4,
            'variant': 5,
            'product_name': 'شحن LNET',
            'variant_name': '',
            'quantity': '1',
            'returned_quantity': '0',
            'returnable_quantity': '1',
            'unit_price': '50.00',
            'line_total': '50.00',
            'integration': {
              'provider': 'lnet',
              'kind': 'recharge',
              'subscriber_ref': 'basheir.shop',
              'status': 'confirmed',
              'receipt_logo': logo('lnet'),
              'receipt': {
                'username': 'basheir.shop',
                'amount': '50',
                'serial': '26071138019',
                'package': 'Home 4G 20M',
              },
            },
          },
        ],
        'payments': [],
      });
      const service = OrderDocumentService(fontLoader: _FileFontLoader());
      Directory(dumpDir!).createSync(recursive: true);
      for (final pageSize in PdfPageSize.values) {
        final render = await service.buildSaleInvoiceRender(
          order: sale,
          pageSize: pageSize,
        );
        File(
          '$dumpDir/invoice-${pageSize.name}.pdf',
        ).writeAsBytesSync(render.bytes);
      }
    });

    // The same, for a sale of «كروت دفتر» cards: three brands' slips, each
    // with its own logo and the provider's mark (`pointy`), on every page size.
    test(
      'dumps a sale of «كروت دفتر» cards to look at',
      skip: dumpDir == null,
      () async {
        String logo(String name) {
          final file = File(
            '${Platform.environment['POINTY_SLIP_LOGOS']}/$name.png',
          );
          return file.existsSync() ? base64Encode(file.readAsBytesSync()) : '';
        }

        Map<String, Object?> card(
          int id,
          String brand,
          String key,
          String variant,
          String price,
          Map<String, String> receipt,
        ) => {
          'id': id,
          'product': id * 10,
          'variant': id * 10 + 1,
          'product_name': brand,
          'variant_name': variant,
          'quantity': '1',
          'returned_quantity': '0',
          'returnable_quantity': '1',
          'unit_price': price,
          'line_total': price,
          'integration': {
            'provider': 'pointy',
            'kind': 'voucher',
            'subscriber_ref': '',
            'status': 'confirmed',
            'receipt_logo': logo(key),
            'provider_logo': logo('pointy'),
            'receipt': receipt,
          },
        };

        final sale = SaleOrder.fromJson({
          'id': 9,
          'receipt_number': 'R-9',
          'status': 'paid',
          'subtotal': '238.00',
          'discount_total': '0',
          'total': '238.00',
          'lines': [
            card(
              1,
              'بلايستيشن',
              'playstation',
              'تركيا · 1000 ليرة تركية',
              '88.00',
              {
                'code': 'QW4P-7ZM2-KD93',
                'serial': '439882298872854',
                'instructions': 'PlayStation Store ← استرداد الرموز',
              },
            ),
            card(
              2,
              'آيتونز',
              'apple',
              'الولايات المتحدة · 50 دولار',
              '140.00',
              {
                'code': 'XK4M9QXD4HV6TF8R',
                'serial': '439882298872855',
                'instructions':
                    'App Store ← صورة الحساب ← استرداد بطاقة الهدايا أو الرمز',
              },
            ),
            card(3, 'ليبيانا', 'libyana', '10 دينار', '10.00', {
              'code': '4028551190372264',
              'serial': '439882298872856',
              'instructions': 'اتصل بالرقم 120 متبوعاً بالرقم السري',
            }),
          ],
          'payments': [],
        });
        const service = OrderDocumentService(fontLoader: _FileFontLoader());
        Directory(dumpDir!).createSync(recursive: true);
        for (final pageSize in PdfPageSize.values) {
          final render = await service.buildSaleInvoiceRender(
            order: sale,
            pageSize: pageSize,
          );
          File(
            '$dumpDir/daftar-invoice-${pageSize.name}.pdf',
          ).writeAsBytesSync(render.bytes);
        }
      },
    );
  });
}

/// A thermal slip read back: its text lines, and its raster images whole.
class _SlipLines {
  _SlipLines(this.text, this.rasters, this.firstRasterLine);

  factory _SlipLines.parse(List<int> bytes) {
    final lines = <String>[];
    final rasters = <List<int>>[];
    int? firstRasterLine;
    var current = <int>[];
    void endLine() {
      final line = _decode(current).trim();
      if (line.isNotEmpty) {
        lines.add(line);
      }
      current = <int>[];
    }

    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b == 0x1D && i + 2 < bytes.length && bytes[i + 1] == 0x76) {
        // GS v 0 m xL xH yL yH, then the image itself.
        final widthBytes = bytes[i + 4] | bytes[i + 5] << 8;
        final height = bytes[i + 6] | bytes[i + 7] << 8;
        final end = i + 8 + widthBytes * height;
        rasters.add(bytes.sublist(i, end));
        endLine();
        firstRasterLine ??= lines.length;
        i = end;
        continue;
      }
      if (b == 0x1B && i + 1 < bytes.length) {
        i += 2 + (_escParams[bytes[i + 1]] ?? 0);
        continue;
      }
      if (b == 0x1D && i + 1 < bytes.length) {
        i += 2 + (_gsParams[bytes[i + 1]] ?? 0);
        continue;
      }
      if (b == 0x1C) {
        i += 2;
        continue;
      }
      if (b == 0x0A) {
        endLine();
        i++;
        continue;
      }
      current.add(b);
      i++;
    }
    endLine();
    return _SlipLines(lines, rasters, firstRasterLine ?? -1);
  }

  final List<String> text;
  final List<List<int>> rasters;

  /// How many text lines print before the first picture.
  final int firstRasterLine;
}

/// A line is either Latin-1 (through the code page) or UTF-8 (Arabic).
String _decode(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

const _escParams = <int, int>{
  0x40: 0, // ESC @   initialise
  0x24: 2, // ESC $   absolute print position
  0x32: 0, // ESC 2   default line spacing
  0x21: 1, // ESC !   print mode
  0x61: 1, // ESC a   justification
  0x4D: 1, // ESC M   font select
  0x45: 1, // ESC E   emphasis
  0x47: 1, // ESC G   double strike
  0x74: 1, // ESC t   code page
  0x64: 1, // ESC d   feed n lines
  0x4A: 1, // ESC J   feed n dots
  0x33: 1, // ESC 3   line spacing
  0x2D: 1, // ESC -   underline
  0x7B: 1, // ESC {   upside down
};

const _gsParams = <int, int>{
  0x21: 1, // GS !  character size
  0x42: 1, // GS B  reverse
  0x56: 1, // GS V  cut
};

ShopSettings _settings({required bool printVoucherQrCodes}) => ShopSettings(
  shopName: 'متجر',
  receiptHeader: '',
  receiptFooter: '',
  enableOnlineInvoices: false,
  requireOpeningCash: true,
  autoPrintReceipts: false,
  allowOverselling: false,
  preventSellingAtLoss: true,
  lowStockThreshold: 5,
  cashierReturnWindowHours: 42,
  enableCashPayments: true,
  enableCardPayments: true,
  enableTransferPayments: true,
  requireCardPaymentReceipt: false,
  trustedCardTerminalIds: const [],
  cardCommissionPercent: 0,
  transferCommissionPercent: 0,
  printVoucherQrCodes: printVoucherQrCodes,
);

class _NoBrandLogo extends PointyBrandLogoLoader {
  const _NoBrandLogo();

  @override
  Future<Uint8List?> load() async => null;
}

class _FileFontLoader extends PointyPdfFontLoader {
  const _FileFontLoader();

  @override
  Future<PointyPdfFontData> loadData() async => TtfPointyPdfFontData(
    base: ByteData.sublistView(
      File('assets/fonts/IBMPlexSansArabic-Regular.ttf').readAsBytesSync(),
    ),
    bold: ByteData.sublistView(
      File('assets/fonts/IBMPlexSansArabic-Bold.ttf').readAsBytesSync(),
    ),
  );
}

class _TestFontLoader extends PointyPdfFontLoader {
  const _TestFontLoader();

  @override
  Future<PointyPdfFontData> loadData() async => const Type1PointyPdfFontData();
}
