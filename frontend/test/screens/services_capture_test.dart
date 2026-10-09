// Renders «كروت دفتر»' direct services — the strip, the airtime pane, the bill
// cards and the bill flow — to PNG, headlessly, from the same surfaces as
// lib/dev/services_preview.dart, on a wide 1366×768 till, a compact 1024×768
// one and a phone, light and dark, so the screens can be looked at instead of
// described.
//
// Not a golden gate: an ordinary `flutter test` run skips every case here.
// Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/services_capture_test.dart
//
// The PNGs land in $POINTY_CAPTURE_DIR (default: the session scratchpad's
// services_ui folder), never in the repository.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_preview.dart';
import 'package:pointy_frontend/dev/voucher_menu_fixtures.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/order/sale_order_details_content.dart';

import '../support/services_testing.dart';

final bool _capture = Platform.environment['POINTY_CAPTURE_SCREENS'] == '1';
final String _outDir =
    Platform.environment['POINTY_CAPTURE_DIR'] ??
    '/private/tmp/claude-501/-Users-hatem-Develop-pointy/'
        '9d48eb8d-a142-48de-bcfa-af051c11dc17/scratchpad/services_ui';

ThemeData _withButtonFont(ThemeData theme) {
  ButtonStyle patch(ButtonStyle? style) {
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStateProperty.resolveWith((states) {
        final resolved = style?.textStyle?.resolve(states);
        return (resolved ?? const TextStyle()).copyWith(
          fontFamily: PointyTypography.fontFamily,
        );
      }),
    );
  }

  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: patch(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: patch(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: patch(theme.textButtonTheme.style),
    ),
  );
}

String _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return Directory(
    Platform.resolvedExecutable,
  ).parent.parent.parent.parent.parent.path;
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    PointyProductImageFrame.debugImageOverride = voucherPreviewArtResolver;
    for (final family in const ['IBMPlexSansArabic', 'Roboto']) {
      final loader = FontLoader(family);
      for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(
          rootBundle.load('assets/fonts/IBMPlexSansArabic-$weight.ttf'),
        );
      }
      await loader.load();
    }
    final iconFont = File(
      '${_flutterRoot()}/bin/cache/artifacts/material_fonts/'
      'MaterialIcons-Regular.otf',
    );
    if (iconFont.existsSync()) {
      final bytes = await iconFont.readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    }
    Directory(_outDir).createSync(recursive: true);
  });

  tearDownAll(() {
    PointyProductImageFrame.debugImageOverride = null;
  });

  Future<void> decodeImages(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate().toList()) {
        final image = element.widget as Image;
        await precacheImage(image.image, element);
      }
    });
  }

  /// Lets timers and fake relay answers play out.
  Future<void> play(WidgetTester tester, {int seconds = 4}) async {
    for (var i = 0; i < seconds * 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shoot(
    WidgetTester tester, {
    required String file,
    required String screen,
    required Size size,
    bool dark = false,
    double ratio = 1.0,
    double textScale = 1.0,
    int seconds = 4,
    Widget Function()? builder,
    Future<void> Function(WidgetTester tester)? act,
  }) async {
    debugDisableShadows = false;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = size * ratio;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: builder != null
            ? servicesApp(builder(), dark: dark, textScale: textScale)
            : ServicesPreviewApp(
                screen: screen,
                theme: _withButtonFont(
                  dark ? PointyTheme.dark() : PointyTheme.light(),
                ),
                textScale: textScale,
                instant: true,
              ),
      ),
    );
    await play(tester, seconds: seconds);
    await decodeImages(tester);
    await play(tester, seconds: 1);
    if (act != null) {
      await act(tester);
      await play(tester, seconds: 2);
      await decodeImages(tester);
      await play(tester, seconds: 1);
    }
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: ratio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    });
    File('$_outDir/$file.png').writeAsBytesSync(bytes!);
    debugDisableShadows = true;
  }

  const wide = Size(1366, 768);
  const till = Size(1024, 768);
  const phone = Size(390, 844);

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(
      find.byKey(const ValueKey('service_country_search')),
      text,
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  final shots = <_Shot>[
    // The strip and the tabs.
    _Shot('01_services_strip', 'strip', wide),
    _Shot('01_services_strip_1024', 'strip', till),
    _Shot('01_services_strip_dark', 'strip', wide, dark: true),
    _Shot('01_services_strip_phone', 'strip', phone, ratio: 2),
    // Airtime.
    _Shot('02_airtime_empty', 'airtime', wide),
    _Shot('02_airtime_first_use', 'airtime-first', wide),
    _Shot('02_airtime_first_use_phone', 'airtime-first', phone, ratio: 2),
    _Shot('02_airtime_country', 'airtime-country', wide),
    _Shot('03_airtime_ready', 'airtime-ready', wide),
    _Shot('03_airtime_ready_1024', 'airtime-ready', till),
    _Shot('03_airtime_ready_dark', 'airtime-ready', wide, dark: true),
    _Shot('03_airtime_ready_phone', 'airtime-ready', phone, ratio: 2),
    _Shot('03_airtime_ready_scale13', 'airtime-ready', wide, textScale: 1.3),
    _Shot(
      '03_airtime_ready_phone_scale13',
      'airtime-ready',
      phone,
      ratio: 2,
      textScale: 1.3,
    ),
    _Shot('03_airtime_empty_phone', 'airtime-first', phone, ratio: 2),
    _Shot('03_airtime_nigeria_custom', 'airtime-nigeria', wide),
    _Shot('03_airtime_egypt_fixed', 'airtime-egypt', wide),
    _Shot('03_airtime_ghana_approx', 'airtime-ghana', wide),
    _Shot('03_airtime_undetected', 'airtime-undetected', wide),
    _Shot('03_airtime_detect_failed', 'airtime-detect-failed', wide),
    _Shot('03_airtime_refused', 'airtime-refused', wide),
    // The country search.
    _Shot(
      '13_search_unsupported',
      'airtime-first',
      wide,
      act: (tester) => search(tester, 'السودان'),
    ),
    _Shot(
      '13_search_dial',
      'airtime-first',
      wide,
      act: (tester) => search(tester, '223'),
    ),
    _Shot(
      '13_search_shared_code',
      'airtime-first',
      wide,
      act: (tester) => search(tester, '1'),
    ),
    _Shot(
      '13_search_none',
      'airtime-first',
      wide,
      act: (tester) => search(tester, 'قطر زائفة'),
    ),
    // Bills.
    _Shot('04_bills_grid', 'bills', wide),
    _Shot('04_bills_grid_dark', 'bills', wide, dark: true),
    _Shot('04_bills_grid_phone', 'bills', phone, ratio: 2),
    _Shot('05_bill_country', 'bill:electricity', wide),
    _Shot('05_bill_country_phone', 'bill:electricity', phone, ratio: 2),
    _Shot('06_bill_providers', 'bill:electricity:ng', wide),
    _Shot('07_bill_account', 'bill:electricity:ng:account', wide),
    _Shot(
      '07_bill_account_dark',
      'bill:electricity:ng:account',
      wide,
      dark: true,
    ),
    _Shot(
      '07_bill_account_phone_scale13',
      'bill:electricity:ng:account',
      phone,
      ratio: 2,
      textScale: 1.3,
    ),
    _Shot('08_bill_amount', 'bill:electricity:ng:amount', wide),
    _Shot(
      '08_bill_amount_phone_scale13',
      'bill:electricity:ng:amount',
      phone,
      ratio: 2,
      textScale: 1.3,
    ),
    _Shot('09_bill_summary', 'bill:electricity:ng:summary', wide),
    _Shot(
      '09_bill_summary_dark',
      'bill:electricity:ng:summary',
      wide,
      dark: true,
    ),
    _Shot(
      '09_bill_summary_phone',
      'bill:electricity:ng:summary',
      phone,
      ratio: 2,
    ),
    _Shot(
      '09_bill_summary_scale13',
      'bill:electricity:ng:summary',
      wide,
      textScale: 1.3,
    ),
    // Television plans, water by invoice.
    _Shot('10_tv_mali_account', 'bill:tv:ml:account', wide),
    _Shot('10_tv_mali_plans', 'bill:tv:ml:amount', wide),
    _Shot(
      '10_tv_mali_plans_phone_scale13',
      'bill:tv:ml:amount',
      phone,
      ratio: 2,
      textScale: 1.3,
    ),
    _Shot('10_tv_mali_summary', 'bill:tv:ml:summary', wide),
    _Shot('11_water_senegal_invoice', 'bill:water', wide),
    _Shot('11_water_senegal_amount', 'bill:water:sn:amount', wide),
    _Shot('11_water_senegal_summary', 'bill:water:sn:summary', wide),
    _Shot(
      '11_water_senegal_summary_phone',
      'bill:water:sn:summary',
      phone,
      ratio: 2,
    ),
    // The services cannot be read, or are off.
    _Shot('12_unavailable', 'empty', wide),
    _Shot('12_unreadable', 'error', wide),
    _Shot('12_loading', 'loading', wide),
    // The number: what is wrong with it, said under the field.
    _Shot('14_airtime_dial_hint', 'airtime-dial-hint', wide),
    _Shot('14_airtime_shared_code', 'airtime-shared-code', wide),
    _Shot(
      '14_airtime_shared_code_phone',
      'airtime-shared-code',
      phone,
      ratio: 2,
    ),
    _Shot('14_airtime_too_long', 'airtime-too-long', wide),
    _Shot('14_airtime_invalid', 'airtime-invalid', wide),
    _Shot('14_airtime_mismatch', 'airtime-mismatch', wide),
    _Shot('14_airtime_mismatch_1024', 'airtime-mismatch', till),
    // The voucher balance, and the line in the cart.
    _Shot('15_airtime_balance', 'airtime-balance', wide),
    _Shot('15_airtime_balance_1024', 'airtime-balance', till),
    _Shot('15_airtime_balance_phone', 'airtime-balance', phone, ratio: 2),
    _Shot('15_airtime_cart', 'airtime-cart', wide),
    // What a sale ends in.
    _Shot('16_dialog_delivered', 'dialog-delivered', wide),
    _Shot(
      '16_dialog_delivered_phone_scale13',
      'dialog-delivered',
      const Size(360, 740),
      ratio: 2,
      textScale: 1.3,
    ),
    _Shot('16_dialog_refused', 'dialog-refused', wide),
    _Shot('16_dialog_unknown', 'dialog-unknown', wide),
    _Shot('16_dialog_unknown_phone', 'dialog-unknown', phone, ratio: 2),
    _Shot('16_dialog_requote', 'dialog-requote', wide),
    _Shot('16_dialog_charging', 'dialog-charging', wide),
    _Shot('16_dialog_charging_dark', 'dialog-charging', wide, dark: true),
    // The relay on its sandbox supplier: «وضع تجريبي» everywhere.
    _Shot('18_test_strip', 'strip-test', wide),
    _Shot('18_test_strip_phone', 'strip-test', phone, ratio: 2),
    _Shot('18_test_airtime_empty', 'airtime-test', wide),
    _Shot('18_test_airtime_ready', 'airtime-ready-test', wide),
    _Shot('18_test_airtime_ready_1024', 'airtime-ready-test', till),
    _Shot('18_test_airtime_ready_dark', 'airtime-ready-test-dark', wide),
    _Shot(
      '18_test_airtime_ready_phone_scale13',
      'airtime-ready-test',
      phone,
      ratio: 2,
      textScale: 1.3,
    ),
    _Shot('18_test_bills_grid', 'bills-test', wide),
    _Shot('18_test_bill_country', 'bill:electricity-test', wide),
    _Shot('18_test_bill_summary', 'bill:electricity:ng:summary-test', wide),
    _Shot(
      '18_test_bill_summary_phone',
      'bill:electricity:ng:summary-test',
      phone,
      ratio: 2,
    ),
    _Shot('18_test_cart_line', 'airtime-cart-test', wide),
    _Shot('18_test_cart_line_dark', 'airtime-cart-test-dark', wide),
    _Shot('18_test_dialog_delivered', 'dialog-delivered-test', wide),
    _Shot(
      '18_test_dialog_delivered_phone_scale13',
      'dialog-delivered-test',
      const Size(360, 740),
      ratio: 2,
      textScale: 1.3,
    ),
    // The invoice a customer comes back with, token and all.
    _Shot(
      '17_invoice_token_phone',
      '',
      const Size(360, 640),
      ratio: 2,
      builder: _invoiceWithToken,
    ),
    _Shot(
      '17_invoice_token_phone_scale13',
      '',
      const Size(360, 640),
      ratio: 2,
      textScale: 1.3,
      builder: _invoiceWithToken,
    ),
  ];
  for (final shot in shots) {
    testWidgets('capture ${shot.file}', (tester) async {
      await shoot(
        tester,
        file: shot.file,
        screen: shot.screen,
        size: shot.size,
        dark: shot.dark,
        ratio: shot.ratio,
        textScale: shot.textScale,
        builder: shot.builder,
        act: shot.act,
      );
    }, skip: !_capture);
  }
}

class _Shot {
  const _Shot(
    this.file,
    this.screen,
    this.size, {
    this.dark = false,
    this.ratio = 1.0,
    this.textScale = 1.0,
    this.builder,
    this.act,
  });

  final String file;
  final String screen;
  final Size size;
  final bool dark;
  final double ratio;
  final double textScale;

  /// Draws this instead of the services preview.
  final Widget Function()? builder;
  final Future<void> Function(WidgetTester tester)? act;
}

/// A sold bill on the invoice page, with the prepaid meter's token the
/// customer comes back for.
Widget _invoiceWithToken() => SingleChildScrollView(
  padding: const EdgeInsets.all(12),
  child: SaleOrderDetailsContent(
    order: SaleOrder(
      id: 11,
      receiptNumber: 'R20261008000011',
      status: 'completed',
      lines: [
        SaleOrderLine(
          id: 1,
          productId: 90,
          variantId: 90,
          productName: 'دفع فاتورة',
          quantity: 1,
          returnedQuantity: 0,
          returnableQuantity: 0,
          unitPrice: 30,
          total: 30,
          integration: const SaleLineIntegration(
            provider: 'pointy',
            kind: 'bill',
            subscriberRef: '04223568280',
            optionLabel: 'كهرباء إيكيجا (مسبقة الدفع)',
            status: 'confirmed',
            providerReference: '558032',
            receipt: {
              'pin': '2737-6032-5315-7183-0856-4410',
              'pin_label': 'رمز الشحن',
            },
          ),
        ),
      ],
      payments: const [],
      subtotal: 30,
      total: 30,
      paymentStatus: 'paid',
    ),
  ),
);
