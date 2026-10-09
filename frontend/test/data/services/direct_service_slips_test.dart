import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/data/services/order_document_service.dart';
import 'package:pointy_frontend/src/data/services/provider_slip_raster.dart';
import 'package:pointy_frontend/src/data/services/receipt_provider_slips.dart';
import 'package:pointy_frontend/src/shared/branding_assets.dart';
import 'package:pointy_frontend/src/shared/design/pointy_typography.dart';
import 'package:pointy_frontend/src/shared/pdf/pdf.dart';

/// Airtime sent abroad and bills paid abroad print as slips the server writes:
/// its title, its `[label, value]` rows, a token and what to call it. The till
/// draws them generically — no wording of its own for any kind — on the
/// thermal receipt (drawn and as text) and on the A4 and roll invoices.
///
/// `POINTY_SLIP_DUMP=<dir>` writes every slip drawn here as a PNG and every
/// invoice as a PDF, to look at.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const token = '2737-6032-5315-7183-0856';
  const rasterizer = ProviderSlipRasterizer();

  setUpAll(() async {
    final loader = FontLoader(PointyTypography.fontFamily);
    for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(
        rootBundle.load('assets/fonts/IBMPlexSansArabic-$weight.ttf'),
      );
    }
    await loader.load();
  });

  /// What the shop backend prints for an airtime top-up, as JSON.
  const airtimePrinted = <String, Object?>{
    'title': 'شحن مباشر',
    'rows': [
      ['الشبكة', 'أورنج مالي'],
      ['الرقم', '+22370123456'],
      ['المبلغ المرسل', '5,000 XOF'],
      ['رقم العملية', '4602843'],
    ],
    'pin': '',
    'pin_label': 'رمز الشحن',
    'notice': '',
  };

  /// …and for a prepaid electricity bill, with its token.
  const billPrinted = <String, Object?>{
    'title': 'دفع فاتورة',
    'rows': [
      ['الجهة', 'كهرباء إيكيجا (مسبقة الدفع)'],
      ['رقم العدّاد', '04223568280'],
      ['المبلغ', '5,000 NGN'],
      ['الوحدات', '10.7 kWh'],
      ['رقم العملية', '36'],
    ],
    'pin': token,
    'pin_label': 'رمز الشحن',
    'notice': 'أدخل الرمز في العدّاد',
  };

  ReceiptProviderSlip slipFor(
    String kind,
    Map<String, Object?> printed, {
    String status = 'confirmed',
  }) {
    final slips = receiptProviderSlipsFromPayload([
      {
        'name': 'x',
        'integration': {'kind': kind, 'status': status, 'printed': printed},
      },
    ], printQrCodes: true);
    return slips.single;
  }

  group('the slip', () {
    test('of airtime is the server\'s own rows, in order', () {
      final slip = slipFor('airtime', airtimePrinted);

      expect(slip.title, 'شحن مباشر');
      expect(slip.rows, [
        'الشبكة: أورنج مالي',
        'الرقم: +22370123456',
        'المبلغ المرسل: 5,000 XOF',
        'رقم العملية: 4602843',
      ]);
      expect(slip.pin, isEmpty);
      expect(slip.qrData, isNull, reason: 'nothing to dial or copy');
      expect(slip.dial, isEmpty);
      expect(slip.notice, isEmpty);
    });

    test(
      'of a bill carries the token as its PIN, under the server\'s label',
      () {
        final slip = slipFor('bill', billPrinted);

        expect(slip.pin, token);
        expect(slip.pinLabel, 'رمز الشحن');
        expect(slip.notice, 'أدخل الرمز في العدّاد');
        expect(slip.rows.first, 'الجهة: كهرباء إيكيجا (مسبقة الدفع)');
        expect(slip.rows, contains('الوحدات: 10.7 kWh'));
        expect(slip.qrData, isNull);
      },
    );

    test('names its PIN as a card does when the server named none', () {
      final slip = slipFor('bill', {...billPrinted, 'pin_label': ''});

      expect(slip.pinLabel, receiptPinLabel);
    });

    test('falls back to the line\'s name without a title of its own', () {
      final slip = slipFor('airtime', {...airtimePrinted, 'title': ''});

      expect(slip.title, 'x');
    });

    test('that is not confirmed says so, in one line, and prints nothing '
        'usable', () {
      final refused = slipFor('bill', billPrinted, status: 'failed');
      expect(refused.notice, 'لم تتم العملية');
      expect(refused.pin, isEmpty);
      expect(refused.rows, isEmpty);

      final unknown = slipFor('airtime', airtimePrinted, status: 'submitted');
      expect(unknown.notice, contains('لا تُعِد المحاولة'));
      expect(unknown.rows, isEmpty);

      final cancelled = slipFor('airtime', airtimePrinted, status: 'cancelled');
      expect(cancelled.notice, 'أُلغيت العملية');
    });

    test('is tolerant: no rows, odd rows, rows that are not a list', () {
      expect(slipFor('airtime', const {'title': 'شحن'}).rows, isEmpty);
      expect(
        slipFor('airtime', const {
          'rows': [
            ['وحده'],
            [],
            ['a', ''],
            ['k', 'v', 'w'],
          ],
        }).rows,
        ['وحده', 'a', 'k: v w'],
      );
      expect(slipFor('airtime', const {'rows': 'oops'}).rows, isEmpty);
    });

    test('is the same on the document route, from the sale line', () {
      final line = SaleLineIntegration.fromJson({
        'provider': 'pointy',
        'kind': 'bill',
        'subscriber_ref': '04223568280',
        'status': 'confirmed',
        'receipt': billPrinted,
      });

      final slip = receiptProviderSlip(
        title: 'ignored',
        kind: line.kind,
        status: line.status,
        printed: line.receipt,
      );
      expect(slip, slipFor('bill', billPrinted).copyTitle('دفع فاتورة'));
      expect(line.isDirectService, isTrue);
    });
  });

  group('drawn for the thermal receipt', () {
    Future<ProviderSlipRaster> draw(
      ReceiptProviderSlip slip,
      String name, {
      int paperDots = 576,
    }) async {
      final raster = await rasterizer.renderSlip(
        slip,
        widthDots: paperDots - 24,
        dense: false,
      );
      _dump(raster, name);
      return raster;
    }

    test('airtime is a framed card of its rows, with no PIN block', () async {
      final raster = await draw(
        slipFor('airtime', airtimePrinted),
        'airtime-80',
      );

      expect(raster.width, 552);
      expect(raster.qr, isNull);
      expect(_inkOf(raster), greaterThan(2000));
      // Four short facts, a title: well under 5 cm of paper.
      expect(raster.height, lessThan(300));
    });

    test('a bill draws its token big, and its note', () async {
      final raster = await draw(slipFor('bill', billPrinted), 'bill-80');

      expect(raster.qr, isNull);
      expect(raster.height, lessThan(460));
      // The token is the largest thing on the slip: its dots outweigh the
      // slip without it.
      final without = await draw(
        slipFor('bill', {...billPrinted, 'pin': ''}),
        '',
      );
      expect(_inkOf(raster), greaterThan(_inkOf(without) + 1500));
    });

    test('on a 58 mm roll the same slips still fit', () async {
      for (final (name, slip) in [
        ('airtime-58', slipFor('airtime', airtimePrinted)),
        ('bill-58', slipFor('bill', billPrinted)),
      ]) {
        final raster = await draw(slip, name, paperDots: 384);
        expect(raster.width, 360);
        expect(_inkOf(raster), greaterThan(1500));
      }
    });
  });

  group('on the thermal receipt', () {
    const encoder = EscPosReceiptEncoder(brandLogoLoader: _NoBrandLogo());
    const textEncoder = EscPosReceiptEncoder(
      brandLogoLoader: _NoBrandLogo(),
      slipRasterizer: TextOnlySlipRasterizer(),
    );
    const endpoint = PrinterEndpoint(
      kind: PrintTransportKind.fake,
      name: 'till',
      paperWidthMm: 80,
    );

    Map<String, Object?> payload() => {
      'shop': {'name': 'SHOP', 'currency_symbol': 'LYD'},
      'order': {
        'receipt_number': 'R-1',
        'document_title': 'RECEIPT',
        'total_label': 'TOTAL',
        'total': '135.00',
        'payment_status': 'paid',
        'lines': [
          {
            'name': 'AIRTIME',
            'product_name': 'شحن مباشر',
            'quantity': '1',
            'unit_price': '96.50',
            'line_total': '96.50',
            'integration': {
              'kind': 'airtime',
              'status': 'confirmed',
              'subscriber_ref': '+22370123456',
              'reference': '4602843',
              'printed': airtimePrinted,
            },
          },
          {
            'name': 'BILL',
            'product_name': 'دفع فاتورة',
            'quantity': '1',
            'unit_price': '38.50',
            'line_total': '38.50',
            'integration': {
              'kind': 'bill',
              'status': 'confirmed',
              'subscriber_ref': '04223568280',
              'reference': '36',
              'printed': billPrinted,
            },
          },
        ],
      },
    };

    test(
      'is drawn as one picture a line, the token only in the picture',
      () async {
        final bytes = await encoder.encodePayload(
          payload: payload(),
          endpoint: endpoint,
        );

        expect(_rasterCount(bytes), greaterThanOrEqualTo(2));
        expect(
          latin1.decode(bytes, allowInvalid: true),
          isNot(contains(token)),
        );
      },
    );

    test('is printed as text, the token on a line of its own, when drawing '
        'cannot', () async {
      final bytes = await textEncoder.encodePayload(
        payload: payload(),
        endpoint: endpoint,
      );

      expect(latin1.decode(bytes, allowInvalid: true), contains(token));
      expect(latin1.decode(bytes, allowInvalid: true), contains('04223568280'));
      expect(
        latin1.decode(bytes, allowInvalid: true),
        contains('+22370123456'),
      );
    });
  });

  group('on the invoice', () {
    SaleOrder sale() => SaleOrder.fromJson({
      'id': 21,
      'receipt_number': 'R-21',
      'status': 'paid',
      'subtotal': '135.00',
      'discount_total': '0',
      'total': '135.00',
      'lines': [
        {
          'id': 1,
          'product': 2,
          'variant': 3,
          'product_name': 'شحن مباشر',
          'variant_name': '',
          'quantity': '1',
          'returned_quantity': '0',
          'returnable_quantity': '1',
          'unit_price': '96.50',
          'line_total': '96.50',
          'integration': {
            'provider': 'pointy',
            'kind': 'airtime',
            'subscriber_ref': '+22370123456',
            'option_label': 'أورنج مالي · 5,000 فرنك أفريقي',
            'status': 'confirmed',
            'provider_reference': '4602843',
            'receipt': airtimePrinted,
          },
        },
        {
          'id': 2,
          'product': 4,
          'variant': 5,
          'product_name': 'دفع فاتورة',
          'variant_name': '',
          'quantity': '1',
          'returned_quantity': '0',
          'returnable_quantity': '1',
          'unit_price': '38.50',
          'line_total': '38.50',
          'integration': {
            'provider': 'pointy',
            'kind': 'bill',
            'subscriber_ref': '04223568280',
            'status': 'confirmed',
            'receipt': billPrinted,
          },
        },
      ],
      'payments': [],
    });

    test('each direct service is a slip of its own, above the invoice', () {
      final template = const OrderDocumentService().saleInvoiceTemplate(
        order: sale(),
      );

      expect(template.providerSlips, hasLength(2));
      expect(template.providerSlips.first.title, 'شحن مباشر');
      expect(
        template.providerSlips.first.rows,
        contains('الرقم: +22370123456'),
      );
      expect(template.providerSlips.last.pin, token);
      expect(template.providerSlips.last.pinLabel, 'رمز الشحن');
    });

    for (final pageSize in PdfPageSize.values) {
      test('renders on $pageSize', () async {
        const service = OrderDocumentService(fontLoader: _TestFontLoader());
        final render = await service.buildSaleInvoiceRender(
          order: sale(),
          pageSize: pageSize,
        );
        expect(render.bytes, isNotEmpty);
      });
    }

    final dumpDir = Platform.environment['POINTY_SLIP_DUMP'];
    test('dumps the invoices to look at', skip: dumpDir == null, () async {
      const service = OrderDocumentService(fontLoader: _FileFontLoader());
      Directory(dumpDir!).createSync(recursive: true);
      for (final pageSize in PdfPageSize.values) {
        final render = await service.buildSaleInvoiceRender(
          order: sale(),
          pageSize: pageSize,
        );
        File(
          '$dumpDir/direct-services-invoice-${pageSize.name}.pdf',
        ).writeAsBytesSync(render.bytes);
      }
    });
  });
}

extension on ReceiptProviderSlip {
  /// The same slip under another title.
  ReceiptProviderSlip copyTitle(String title) => ReceiptProviderSlip(
    title: title,
    notice: notice,
    pin: pin,
    pinLabel: pinLabel,
    dial: dial,
    qrData: qrData,
    qrCaption: qrCaption,
    rows: rows,
    logo: logo,
    providerLogo: providerLogo,
  );
}

int _inkOf(ProviderSlipRaster raster) {
  var ink = 0;
  for (var y = 0; y < raster.height; y++) {
    for (var x = 0; x < raster.width; x++) {
      if (raster.dot(x, y)) {
        ink++;
      }
    }
  }
  return ink;
}

/// How many `GS v 0` pictures a receipt's bytes hold.
int _rasterCount(List<int> bytes) {
  var count = 0;
  for (var i = 0; i + 2 < bytes.length; i++) {
    if (bytes[i] == 0x1D && bytes[i + 1] == 0x76 && bytes[i + 2] == 0x30) {
      count++;
    }
  }
  return count;
}

void _dump(ProviderSlipRaster raster, String name) {
  final dir = Platform.environment['POINTY_SLIP_DUMP'];
  if (dir == null || name.isEmpty) {
    return;
  }
  final picture = img.Image(width: raster.width, height: raster.height);
  for (var y = 0; y < raster.height; y++) {
    for (var x = 0; x < raster.width; x++) {
      final level = raster.dot(x, y) ? 0 : 255;
      picture.setPixelRgb(x, y, level, level, level);
    }
  }
  Directory(dir).createSync(recursive: true);
  File('$dir/direct-$name.png').writeAsBytesSync(img.encodePng(picture));
}

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
