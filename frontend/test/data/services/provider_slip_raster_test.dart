import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pointy_frontend/src/data/services/provider_slip_raster.dart';
import 'package:pointy_frontend/src/data/services/receipt_provider_slips.dart';
import 'package:pointy_frontend/src/shared/design/pointy_typography.dart';
import 'package:pointy_frontend/src/shared/printing/print_qr_code.dart';

import '../../shared/printing/phone_camera.dart';

/// The thermal receipt draws each provider slip as one picture, laid out like
/// a card: its logo beside its title, a card's QR code beside its PIN, short
/// facts two to a line. These pin the layout's promises — the code still
/// reads back through a phone's eyes, its modules are whole dots, nothing
/// prints outside the paper — and how much paper a slip takes.
///
/// `POINTY_SLIP_DUMP=<dir>` writes every slip drawn here as a PNG, to look
/// at; `POINTY_SLIP_LOGOS=<dir>` draws them with real logos from that
/// directory (`<name>.png`, as the server prepares them) instead of a stand-in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = '1111222233334';
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

  ReceiptProviderSlip card({
    String title = 'المدار - 10 دينار',
    String dial = '*112*$pin#',
    String logo = 'almadar',
    bool printQrCodes = true,
  }) => receiptProviderSlip(
    title: title,
    kind: 'voucher',
    status: 'confirmed',
    printQrCodes: printQrCodes,
    logo: _logo(logo),
    providerLogo: _logo('qareeb'),
    printed: {
      'code': pin,
      'serial': '439882298872854',
      'dial': dial,
      'help': 'لاي استفسارات الرجاء الاتصال على الرقم التالي 0946358319',
    },
  );

  final topUp = receiptProviderSlip(
    title: 'شحن HD Box',
    kind: 'recharge',
    status: 'confirmed',
    subscriberRef: '210906803499',
    logo: _logo('hdbox'),
    printed: const {
      'card_no': '210906803499',
      'months': '1',
      'start_date': '2026-09-20',
      'end_date': '2026-10-20',
      'serial': '558032',
    },
  );

  Future<ProviderSlipRaster> draw(
    ReceiptProviderSlip slip, {
    int paperDots = 576,
    bool dense = false,
    String name = '',
  }) async {
    final raster = await rasterizer.renderSlip(
      slip,
      widthDots: paperDots - 24,
      dense: dense,
    );
    _dump(raster, name);
    return raster;
  }

  group('a card', () {
    test('an Almadar card sits its code beside the PIN and dials it', () async {
      final raster = await draw(card(), name: 'almadar-80');

      expect(raster.width, 552);
      final qr = raster.qr!;
      // Beside, at the far edge from the reading side: the left half.
      expect(qr.left + qr.side, lessThanOrEqualTo(raster.width ~/ 2));
      expect(_readCode(raster), 'tel:*112*$pin%23');
      // Under 5 cm of paper for the whole card. Printed as text — logo,
      // title, PIN, a 10-dot code, dial string and facts, one under the
      // other — the same card took about 12.
      expect(raster.height, lessThan(400));
    });

    test('a card nobody dials carries its PIN, to copy', () async {
      final slip = card(title: 'LNET - 10 دينار', dial: '', logo: 'lnetcard');
      expect(slip.qrCaption, receiptScanToCopyPin);
      for (final (paper, width) in [(576, 'lnet-80'), (384, 'lnet-58')]) {
        final raster = await draw(slip, paperDots: paper, name: width);
        expect(_readCode(raster), pin, reason: width);
      }
    });

    test('the code is whole-dot modules on blank paper', () async {
      final raster = await draw(card(), name: '');
      final qr = raster.qr!;
      final code = qr.code;
      for (var y = 0; y < qr.side; y++) {
        for (var x = 0; x < qr.side; x++) {
          final row = y ~/ qr.moduleDots - PrintQrCode.quietZone;
          final column = x ~/ qr.moduleDots - PrintQrCode.quietZone;
          final dark =
              row >= 0 &&
              column >= 0 &&
              row < code.moduleCount &&
              column < code.moduleCount &&
              code.isDark(row, column);
          expect(
            raster.dot(qr.left + x, qr.top + y),
            dark,
            reason: 'dot ($x, $y) of the code',
          );
        }
      }
    });

    test('a 58 mm roll that cannot fit the code beside the PIN stacks '
        'them', () async {
      final raster = await draw(
        card(title: 'ليبيانا - 5 دينار', dial: '120$pin', logo: 'libyana'),
        paperDots: 384,
        name: 'libyana-58',
      );
      expect(raster.width, 360);
      expect(_readCode(raster), 'tel:120$pin');
    });

    test('a shop that prints no codes gets none', () async {
      final raster = await draw(card(printQrCodes: false), name: 'no-qr-80');
      expect(raster.qr, isNull);
    });

    test('a compact receipt draws a smaller slip', () async {
      final normal = await draw(card());
      final dense = await draw(card(), dense: true, name: 'almadar-80-dense');
      expect(dense.height, lessThan(normal.height));
      expect(_readCode(dense), 'tel:*112*$pin%23');
    });
  });

  test('a top-up opens on its provider and pairs its facts', () async {
    final raster = await draw(topUp, name: 'hdbox-80');
    expect(raster.qr, isNull);
    // Logo and title, a rule, four facts in three lines: under 3 cm of
    // paper, where the text slip took 3.3 cm with no logo at all.
    expect(raster.height, lessThan(240));
    await draw(topUp, paperDots: 384, name: 'hdbox-58');
  });

  test(
    'an LNET top-up names the line, the amount and LNET\'s serial',
    () async {
      final slip = receiptProviderSlip(
        title: 'شحن LNET',
        kind: 'recharge',
        status: 'confirmed',
        subscriberRef: 'basheir.shop',
        logo: _logo('lnet'),
        printed: const {
          'username': 'basheir.shop',
          'amount': '45',
          'serial': '26071138019',
          'package': 'Home 4G 20M',
        },
      );
      expect(slip.rows, [
        'المشترك: basheir.shop',
        'الباقة: Home 4G 20M',
        'قيمة الشحن: 45',
        'الرقم التسلسلي: 26071138019',
      ]);
      final raster = await draw(slip, name: 'lnet-topup-80');
      expect(raster.qr, isNull);
      await draw(slip, paperDots: 384, name: 'lnet-topup-58');
    },
  );

  test('a card nobody issued says so, and prints no code', () async {
    final slip = receiptProviderSlip(
      title: 'ليبيانا - 5 دينار',
      kind: 'voucher',
      status: 'submitted',
      logo: _logo('libyana'),
      printed: const {'code': pin},
    );
    final raster = await draw(slip, name: 'submitted-80');
    expect(raster.qr, isNull);
    expect(raster.height, lessThan(200));
  });

  test('nothing prints outside the paper', () async {
    for (final paper in [384, 512, 576]) {
      final raster = await draw(card(), paperDots: paper);
      expect(raster.width, paper - 24);
      expect(raster.bits, hasLength(raster.width ~/ 8 * raster.height));
      // The frame is inked on all four edges.
      expect(raster.dot(raster.width ~/ 2, 0), isTrue);
      expect(raster.dot(raster.width ~/ 2, raster.height - 1), isTrue);
      expect(raster.dot(0, raster.height ~/ 2), isTrue);
      expect(raster.dot(raster.width - 1, raster.height ~/ 2), isTrue);
    }
  });

  test('stacked bands reproduce the slip, row for row', () async {
    final raster = await draw(card());
    final bytes = escPosSlipRaster(raster, bandRows: 100);
    final rows = <int>[];
    final data = <int>[];
    var i = 0;
    while (i < bytes.length) {
      expect(bytes.sublist(i, i + 4), [0x1D, 0x76, 0x30, 0x00]);
      final widthBytes = bytes[i + 4] | bytes[i + 5] << 8;
      final height = bytes[i + 6] | bytes[i + 7] << 8;
      expect(widthBytes, raster.width ~/ 8);
      rows.add(height);
      data.addAll(bytes.sublist(i + 8, i + 8 + widthBytes * height));
      i += 8 + widthBytes * height;
    }
    expect(rows.every((height) => height <= 100), isTrue);
    expect(rows.fold<int>(0, (sum, height) => sum + height), raster.height);
    expect(data, raster.bits);
  });
}

/// What a phone reads off the slip's dots, the whole slip in view.
String? _readCode(ProviderSlipRaster raster) => readLikeAPhone(
  raster.width,
  raster.height,
  (x, y) =>
      x >= 0 &&
      y >= 0 &&
      x < raster.width &&
      y < raster.height &&
      raster.dot(x, y),
  scale: 2,
);

/// A logo as the server sends it (base64 PNG): a real one from
/// `POINTY_SLIP_LOGOS` when there is one, else a stand-in mark.
String _logo(String name) {
  final dir = Platform.environment['POINTY_SLIP_LOGOS'];
  if (dir != null) {
    final file = File('$dir/$name.png');
    if (file.existsSync()) {
      return base64Encode(file.readAsBytesSync());
    }
  }
  final mark = img.Image(width: 120, height: 120);
  img.fill(mark, color: img.ColorRgb8(255, 255, 255));
  img.drawCircle(mark, x: 60, y: 60, radius: 50, color: img.ColorRgb8(0, 0, 0));
  img.fillRect(
    mark,
    x1: 40,
    y1: 40,
    x2: 80,
    y2: 80,
    color: img.ColorRgb8(0, 0, 0),
  );
  return base64Encode(img.encodePng(mark));
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
  File('$dir/$name.png').writeAsBytesSync(img.encodePng(picture));
  // ignore: avoid_print
  print(
    '$name: ${raster.width}x${raster.height} dots = '
    '${(raster.height / 8).toStringAsFixed(1)} mm',
  );
}
