import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/print_job.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/register_cash_movement.dart';
import 'package:pointy_frontend/src/app.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/inventory_repository.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_details_screen.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_stock_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/register_cash_movement_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/register_session_close_sheet.dart';
import 'package:pointy_frontend/src/features/users/view_models/user_management_view_model.dart';
import 'package:pointy_frontend/src/features/users/views/user_management_screen.dart';
import 'package:pointy_frontend/src/shared/infinite_scroll_grid.dart';
import 'package:pointy_frontend/src/shared/product_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'printer endpoint parses serial, bluetooth, wifi, and ESC/POS options',
    () {
      final endpoint = PrinterEndpoint.fromJson({
        'kind': 'wifi',
        'name': 'Counter',
        'address': '192.168.1.50',
        'port': 9100,
        'paper_width_mm': 58,
        'code_table': 'CP1256',
        'timeout_ms': 3000,
      });

      expect(endpoint.kind, PrintTransportKind.wifi);
      expect(endpoint.address, '192.168.1.50');
      expect(endpoint.port, 9100);
      expect(endpoint.paperWidthMm, 58);
      expect(endpoint.codeTable, 'CP1256');
      expect(endpoint.timeoutMs, 3000);
      expect(
        PrinterEndpoint.fromJson({'kind': 'bluetooth'}).kind,
        PrintTransportKind.bluetooth,
      );
    },
  );

  test('ESC/POS encoder generates non-empty receipt bytes', () async {
    final job = PrintJob.fromJson({
      'id': 1,
      'status': 'queued',
      'job_type': 'receipt',
      'payload': {
        'shop': {
          'name': 'متجر نقطة البيع',
          'receipt_header': 'أهلا بكم',
          'receipt_footer': 'شكرا لزيارتكم',
        },
        'order': {
          'receipt_number': 'R-1',
          'created_at': '2026-05-16T12:00:00Z',
          'total': '3.50',
          'lines': [
            {
              'name': 'قهوة البيت',
              'quantity': 1,
              'unit_price': '3.50',
              'line_total': '3.50',
            },
          ],
        },
      },
    });
    const endpoint = PrinterEndpoint(
      kind: PrintTransportKind.serial,
      name: 'Counter',
      address: '/dev/tty.test',
    );

    final bytes = await const EscPosReceiptEncoder().encodeJob(
      job: job,
      endpoint: endpoint,
    );

    expect(bytes, isNotEmpty);
    expect(bytes.first, 27);
  });

  test('printing repository discovers printers across transports', () async {
    final repository = PrintingRepository(
      _mockApiService(),
      serialTransport: const _StaticDiscoveryTransport([
        PrinterEndpoint(
          kind: PrintTransportKind.serial,
          name: 'USB',
          address: '/dev/tty.usbserial',
        ),
      ]),
      bluetoothTransport: const _StaticDiscoveryTransport([
        PrinterEndpoint(
          kind: PrintTransportKind.bluetooth,
          name: 'BT',
          address: '00:11:22:33:44:55',
        ),
      ]),
      wifiTransport: const _StaticDiscoveryTransport([
        PrinterEndpoint(
          kind: PrintTransportKind.wifi,
          name: 'Network',
          address: '192.168.1.20',
          port: 9100,
        ),
      ]),
    );

    final result = await repository.discoverPrinters();

    final printers = switch (result) {
      Ok<List<PrinterEndpoint>>() => result.value,
      Error<List<PrinterEndpoint>>() => fail('Discovery should not fail'),
    };
    expect(printers.map((printer) => printer.kind), [
      PrintTransportKind.serial,
      PrintTransportKind.bluetooth,
      PrintTransportKind.wifi,
    ]);
  });

  test(
    'printing repository saves the default printer as a printable device',
    () async {
      final repository = PrintingRepository(_mockApiService());
      const endpoint = PrinterEndpoint(
        kind: PrintTransportKind.wifi,
        name: 'Counter',
        address: '192.168.1.55',
        port: 9100,
      );

      final saveResult = await repository.saveDefaultPrinterConfig(
        const PrinterConfig(
          endpoint: endpoint,
          isEnabled: false,
          autoClaimJobs: false,
        ),
      );
      expect(saveResult, isA<Ok<void>>());

      final loadResult = await repository.loadDefaultPrinterConfig();
      final config = switch (loadResult) {
        Ok<PrinterConfig>() => loadResult.value,
        Error<PrinterConfig>() => fail('Default printer should load'),
      };

      expect(config.endpoint.address, '192.168.1.55');
      expect(config.isEnabled, isTrue);
      expect(config.autoClaimJobs, isTrue);
    },
  );

  testWidgets('checkout posts cart lines and clears cart on success', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, Object?>? checkoutBody;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onCheckout: (request) {
            checkoutBody = jsonDecode(request.body) as Map<String, Object?>;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _startRegisterSession(tester);

    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();
    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    await tester.tap(find.text('ادفع 7.00 د.ل'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(checkoutBody, isNotNull);
    expect(checkoutBody?['payment_method'], 'cash');
    expect(checkoutBody?['amount_received'], '7.00');
    expect(checkoutBody?['lines'], [
      {'product': 1, 'quantity': 2},
    ]);
    expect(find.text('لا توجد عناصر في السلة'), findsOneWidget);
    expect(find.text('تم تسجيل البيع. رقم الإيصال: R-100'), findsOneWidget);
  });

  testWidgets(
    'checkout auto-prints paid invoice when shop setting is enabled',
    (WidgetTester tester) async {
      _setFakePrinterConfig();
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Map<String, Object?>? checkoutBody;
      var reportCalls = 0;

      await tester.pumpWidget(
        PointyApp(
          apiService: _mockApiService(
            shopSettingsAutoPrint: true,
            onCheckout: (request) {
              checkoutBody = jsonDecode(request.body) as Map<String, Object?>;
            },
            onPrintJobReport: (_) => reportCalls += 1,
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _startRegisterSession(tester);
      await tester.tap(find.byType(ProductTile).first);
      await tester.pump();

      expect(find.text('طباعة الفاتورة بعد الدفع'), findsNothing);

      await tester.tap(find.text('ادفع 3.50 د.ل'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(checkoutBody?['print_invoice'], isA<Map<String, Object?>>());
      expect(reportCalls, 1);
      expect(
        find.text(
          'تم تسجيل البيع. رقم الإيصال: R-100 تم إرسال الفاتورة للطابعة.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('checkout prints invoice when cashier selects the checkbox', (
    WidgetTester tester,
  ) async {
    _setFakePrinterConfig();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, Object?>? checkoutBody;
    var reportCalls = 0;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onCheckout: (request) {
            checkoutBody = jsonDecode(request.body) as Map<String, Object?>;
          },
          onPrintJobReport: (_) => reportCalls += 1,
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _startRegisterSession(tester);
    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    expect(find.text('طباعة الفاتورة بعد الدفع'), findsOneWidget);
    await tester.tap(find.text('طباعة الفاتورة بعد الدفع'));
    await tester.pump();

    await tester.tap(find.text('ادفع 3.50 د.ل'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(checkoutBody?['print_invoice'], isA<Map<String, Object?>>());
    expect(reportCalls, 1);
    expect(
      find.text(
        'تم تسجيل البيع. رقم الإيصال: R-100 تم إرسال الفاتورة للطابعة.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('checkout keeps cart and shows error on failure', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(checkoutStatusCode: 400)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _startRegisterSession(tester);

    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    await tester.tap(find.text('ادفع 3.50 د.ل'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('ادفع 3.50 د.ل'), findsOneWidget);
    expect(
      find.text('تعذر تسجيل البيع. تحقق من جلسة الدرج وحاول مرة أخرى.'),
      findsOneWidget,
    );
    expect(find.text('لا توجد عناصر في السلة'), findsNothing);
  });

  testWidgets('checkout warns before allowed oversell', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, Object?>? checkoutBody;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          productQuantityOnHand: 1,
          shopSettingsAllowOverselling: true,
          onCheckout: (request) {
            checkoutBody = jsonDecode(request.body) as Map<String, Object?>;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _startRegisterSession(tester);
    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();
    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    await tester.tap(find.text('ادفع 7.00 د.ل'));
    await tester.pumpAndSettle();

    expect(find.text('تنبيه المخزون'), findsOneWidget);
    expect(find.text('قهوة البيت: المطلوب 2، المتاح 1'), findsOneWidget);
    expect(checkoutBody, isNull);

    await tester.tap(find.text('إتمام البيع'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(checkoutBody, isNotNull);
    expect(find.text('تم تسجيل البيع. رقم الإيصال: R-100'), findsOneWidget);
  });

  testWidgets('register gate starts a session before showing POS', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('نقطة البيع'), findsOneWidget);
    expect(find.text('جلسة الدرج'), findsOneWidget);
    expect(find.text('نقدية الافتتاح'), findsOneWidget);

    await tester.tap(find.text('بدء الجلسة'));
    await tester.pump();

    expect(find.text('أدخل نقدية الافتتاح قبل بدء الجلسة.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '12.00');
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('بدء الجلسة'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('البيع الحالي'), findsOneWidget);
    expect(find.text('جلسة RS-1'), findsOneWidget);

    expect(find.byType(ProductTile), findsWidgets);

    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    expect(find.text('ادفع 3.50 د.ل'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('cash movement sheet requires a reason and submits amount', (
    WidgetTester tester,
  ) async {
    RegisterCashMovementInput? submittedInput;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: RegisterCashMovementSheet(
            movementType: RegisterCashMovementType.payOut,
            onSubmit: (input) async {
              submittedInput = input;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField).first, '9.75');
    await tester.tap(find.text('سحب نقدية'));
    await tester.pump();

    expect(find.text('أدخل سبب الحركة قبل الحفظ.'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).last, 'شراء مستلزمات');
    await tester.tap(find.text('سحب نقدية'));
    await tester.pump();

    expect(submittedInput?.movementType, RegisterCashMovementType.payOut);
    expect(submittedInput?.amount, 9.75);
    expect(submittedInput?.reason, 'شراء مستلزمات');
  });

  testWidgets('register gate allows blank opening cash when setting is off', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(shopSettingsRequireOpeningCash: false),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('بدء الجلسة'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('أدخل نقدية الافتتاح قبل بدء الجلسة.'), findsNothing);
    expect(find.text('البيع الحالي'), findsOneWidget);
  });

  testWidgets('catalog screen exposes the product creation form', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المنتجات').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إدارة المنتجات'), findsOneWidget);
    expect(find.text('إضافة منتج'), findsOneWidget);
    expect(find.text('منتج جديد'), findsNothing);

    await tester.tap(find.text('إضافة منتج'));
    await tester.pumpAndSettle();

    expect(find.text('منتج جديد'), findsOneWidget);
    expect(find.text('اسم المنتج'), findsOneWidget);
    expect(find.text('رمز المنتج'), findsOneWidget);
    expect(find.text('إنشاء المنتج'), findsOneWidget);
  });

  testWidgets('POS screen exposes reusable search and ordering controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _startRegisterSession(tester);

    expect(find.text('ابحث باسم المنتج أو الرمز'), findsOneWidget);
    expect(find.byTooltip('الفلاتر والترتيب'), findsOneWidget);

    await tester.tap(find.byTooltip('الفلاتر والترتيب'));
    await tester.pumpAndSettle();

    expect(find.text('الفلاتر والترتيب'), findsOneWidget);
    expect(find.text('ترتيب النتائج'), findsOneWidget);
    expect(find.text('حالة المنتج'), findsNothing);
  });

  testWidgets(
    'catalog screen exposes reusable search, filtering, and ordering controls',
    (WidgetTester tester) async {
      await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('المنتجات').last);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('ابحث باسم المنتج أو الرمز'), findsOneWidget);
      expect(find.byTooltip('الفلاتر والترتيب'), findsOneWidget);

      await tester.tap(find.byTooltip('الفلاتر والترتيب'));
      await tester.pumpAndSettle();

      expect(find.text('الفلاتر والترتيب'), findsOneWidget);
      expect(find.text('حالة المنتج'), findsOneWidget);
      expect(find.text('ترتيب النتائج'), findsOneWidget);
      expect(find.text('السعر: من الأعلى إلى الأقل'), findsOneWidget);
    },
  );

  testWidgets('navigation drawer exposes primary destinations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('مدير النظام'), findsOneWidget);
    expect(find.text('شاشة البيع'), findsOneWidget);
    expect(find.text('المنتجات'), findsWidgets);
    expect(find.text('جلسات الدرج'), findsOneWidget);
    expect(find.text('المستخدمون'), findsOneWidget);
    expect(find.text('إعدادات الجهاز'), findsOneWidget);
    expect(find.text('إعدادات المتجر'), findsOneWidget);
    expect(find.text('تسجيل الخروج'), findsOneWidget);
  });

  testWidgets('login screen authenticates before showing POS', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(isAuthenticated: false)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('تسجيل الدخول'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(0), 'manager');
    await tester.enterText(find.byType(TextFormField).at(1), 'secret');
    await tester.tap(find.text('دخول'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('جلسة الدرج'), findsOneWidget);
    expect(find.text('نقدية الافتتاح'), findsOneWidget);
  });

  testWidgets('manager can open user management', (WidgetTester tester) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المستخدمون'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إدارة المستخدمين'), findsOneWidget);
    expect(find.text('كاشير الوردية'), findsOneWidget);
    expect(find.text('إضافة مستخدم'), findsOneWidget);
  });

  testWidgets('manager can open and save shop settings', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, Object?>? settingsBody;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onShopSettingsUpdate: (request) {
            settingsBody = jsonDecode(request.body) as Map<String, Object?>;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إعدادات المتجر'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إعدادات المتجر'), findsWidgets);
    expect(find.text('هوية المتجر'), findsOneWidget);
    expect(find.text('الإيصالات'), findsOneWidget);
    expect(find.text('الطابعة المحلية'), findsNothing);
    expect(find.text('جلسة الدرج'), findsOneWidget);
    expect(find.text('تنبيهات المخزون'), findsOneWidget);

    await tester.tap(find.text('جلسة الدرج'));
    await tester.pumpAndSettle();
    expect(find.text('مدة صلاحية الإرجاع للكاشير'), findsOneWidget);
    expect(find.text('1 يوم و18 ساعة'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('cashier_return_window_picker')),
    );
    await tester.pumpAndSettle();
    expect(find.text('الأيام'), findsOneWidget);
    expect(find.text('الساعات'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('هوية المتجر'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'متجر الاختبار');
    await tester.tap(find.text('حفظ الإعدادات'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(settingsBody?['shop_name'], 'متجر الاختبار');
    expect(settingsBody?['cashier_return_window_hours'], 42);
    expect(find.text('تم حفظ إعدادات المتجر.'), findsOneWidget);
  });

  testWidgets('manager can configure and fake-test local printing', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إعدادات الجهاز'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إعدادات الجهاز'), findsWidgets);
    expect(find.text('الطابعة الافتراضية'), findsOneWidget);
    expect(find.text('طريقة الاتصال'), findsOneWidget);
    expect(find.text('تسلسلي'), findsOneWidget);
    expect(find.text('محاكاة'), findsOneWidget);
    expect(find.text('تفعيل وكيل الطباعة المحلي'), findsNothing);
    expect(find.text('استلام مهام الطباعة تلقائيًا'), findsNothing);

    await tester.tap(find.text('محاكاة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('اختبار الطابعة'));
    await tester.pumpAndSettle();

    expect(find.text('تم إرسال اختبار الطباعة.'), findsOneWidget);
  });

  testWidgets('cashier navigation hides management destinations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          currentUserRole: 'cashier',
          currentUserDisplayName: 'كاشير الوردية',
          currentUserPermissions: const [
            'catalog.view_product',
            'sales.add_order',
            'sales.view_order',
            'sales.add_registersession',
            'sales.change_registersession',
            'sales.view_registersession',
          ],
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('كاشير الوردية'), findsOneWidget);
    expect(find.text('شاشة البيع'), findsOneWidget);
    expect(find.text('جلسات الدرج'), findsOneWidget);
    expect(find.text('إعدادات الجهاز'), findsOneWidget);
    expect(find.text('المنتجات'), findsNothing);
    expect(find.text('المستخدمون'), findsNothing);
    expect(find.text('إعدادات المتجر'), findsNothing);
  });

  testWidgets(
    'user management shows forbidden state for direct cashier entry',
    (WidgetTester tester) async {
      final cashier = PosUser.fromJson(
        _userJson(
          username: 'cashier',
          displayName: 'كاشير الوردية',
          role: 'cashier',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: UserManagementScreen(
            viewModel: UserManagementViewModel(
              UserRepository(_mockApiService(currentUserRole: 'cashier')),
            ),
            currentUser: cashier,
            capabilities: AuthorizationCapabilities.forUser(cashier),
            onOpenPos: () {},
            onOpenCatalog: () {},
            onOpenRegisterSessions: () {},
            onOpenDeviceSettings: () {},
            onLogout: () {},
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('غير مصرح'), findsOneWidget);
      expect(
        find.text('لا يملك هذا المستخدم صلاحية الوصول إلى هذه الشاشة.'),
        findsOneWidget,
      );
      expect(find.text('إضافة مستخدم'), findsNothing);
    },
  );

  testWidgets('register session history shows sessions and linked sales', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('جلسات الدرج'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('سجل جلسات الدرج'), findsOneWidget);
    expect(find.text('جلسة RS-1'), findsOneWidget);
    expect(find.text('جلسة RS-2'), findsOneWidget);
    expect(find.text('اختر جلسة درج لعرض مبيعاتها.'), findsOneWidget);

    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('مبيعات جلسة RS-1'), findsOneWidget);
    expect(find.text('الملخص'), findsOneWidget);
    expect(find.text('المبيعات'), findsOneWidget);
    expect(find.text('حركات النقد'), findsOneWidget);
    await tester.tap(find.text('الملخص'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('ملخص النقد'), findsOneWidget);
    expect(find.text('فرق -0.25 د.ل'), findsWidgets);

    await tester.tap(find.text('المبيعات'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إيصال R-100'), findsOneWidget);
    expect(find.text('7.00 د.ل'), findsWidgets);

    await tester.tap(find.text('حركات النقد'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إضافة نقدية'), findsOneWidget);
    expect(find.textContaining('تسوية الصندوق'), findsOneWidget);
  });

  testWidgets('sale details can request a receipt reprint', (
    WidgetTester tester,
  ) async {
    String? reprintPath;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onReprint: (request) {
            reprintPath = request.url.path;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('جلسات الدرج'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('المبيعات'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('إيصال R-100'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('إعادة طباعة الإيصال'));
    await tester.pumpAndSettle();

    expect(reprintPath, '/api/orders/100/reprint/');
    expect(find.text('تم إرسال طلب إعادة الطباعة.'), findsOneWidget);
  });

  testWidgets(
    'sale details can return selected products from session history',
    (WidgetTester tester) async {
      Map<String, Object?>? returnBody;

      await tester.pumpWidget(
        PointyApp(
          apiService: _mockApiService(
            onReturn: (request) {
              returnBody = jsonDecode(request.body) as Map<String, Object?>;
            },
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('جلسات الدرج'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.text('جلسة RS-1'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.text('المبيعات'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.text('إيصال R-100'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('إرجاع منتجات'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'طلب العميل');
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(returnBody?['reason'], 'طلب العميل');
      expect(returnBody?['lines'], [
        {'line': 1000, 'quantity': 1},
      ]);
      expect(find.text('تم تسجيل الإرجاع.'), findsOneWidget);
    },
  );

  testWidgets('sale details can void an invoice from session history', (
    WidgetTester tester,
  ) async {
    Map<String, Object?>? voidBody;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onVoid: (request) {
            voidBody = jsonDecode(request.body) as Map<String, Object?>;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('جلسات الدرج'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('المبيعات'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('إيصال R-100'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('إلغاء الفاتورة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'فاتورة خاطئة');
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(voidBody?['reason'], 'فاتورة خاطئة');
    expect(find.text('تم إلغاء الفاتورة.'), findsOneWidget);
  });

  testWidgets('cashier does not see late return actions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          currentUserRole: 'cashier',
          currentUserDisplayName: 'كاشير الوردية',
          currentUserPermissions: const [
            'sales.view_registersession',
            'sales.view_order',
            'sales.add_order',
          ],
          orderCanVoid: false,
          orderCanReturn: false,
          orderRequiresManagerAdjustment: true,
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('جلسات الدرج'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('المبيعات'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('إيصال R-100'));
    await tester.pumpAndSettle();

    expect(find.text('إرجاع منتجات'), findsNothing);
    expect(find.text('إلغاء الفاتورة'), findsNothing);
    expect(find.text('إعادة طباعة الإيصال'), findsOneWidget);
  });

  testWidgets('session orders load more when the list underfills', (
    WidgetTester tester,
  ) async {
    final requestedOrderPages = <int>[];

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(onOrderPage: requestedOrderPages.add),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('جلسات الدرج'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('المبيعات'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(requestedOrderPages, containsAllInOrder([1, 2]));
    expect(find.text('إيصال R-100'), findsOneWidget);
    expect(find.text('إيصال R-101'), findsOneWidget);
  });

  testWidgets('register gate resumes an existing open session', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(hasOpenSession: true)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('جلسة RS-1'), findsOneWidget);
    expect(find.text('نقدية الافتتاح: 12.00 د.ل'), findsOneWidget);

    await tester.tap(find.text('متابعة البيع'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('البيع الحالي'), findsOneWidget);
    expect(find.byTooltip('إغلاق جلسة الدرج'), findsOneWidget);
  });

  testWidgets('close register sheet submits cash and denomination counts', (
    WidgetTester tester,
  ) async {
    RegisterSessionCloseInput? submittedInput;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: RegisterSessionCloseSheet(
            onClose: (input) async {
              submittedInput = input;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField).at(0), '25.50');
    await tester.enterText(find.byType(TextFormField).at(1), '1');
    await tester.enterText(find.byType(TextFormField).at(2), '2');
    await tester.enterText(find.byType(TextFormField).at(3), '3');
    await tester.enterText(find.byType(TextFormField).at(4), '4');

    await tester.tap(find.text('إغلاق الجلسة'));
    await tester.pump();

    expect(submittedInput?.closingCash, 25.50);
    expect(submittedInput?.count025, 1);
    expect(submittedInput?.count050, 2);
    expect(submittedInput?.count075, 3);
    expect(submittedInput?.count100, 4);
  });

  testWidgets('product details screen presents product information', (
    WidgetTester tester,
  ) async {
    final product = const Product(
      id: 42,
      sku: 'COF-100',
      name: 'قهوة عربية',
      unitPrice: 5.50,
      quantityOnHand: 8,
      barcode: '123456',
      description: 'حبوب مطحونة بعناية',
    );
    final apiService = _mockApiService();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ProductDetailsScreen(
          viewModel: ProductStockViewModel(
            InventoryRepository(apiService),
            product,
          ),
          capabilities: AuthorizationCapabilities.forUser(
            PosUser.fromJson(_userJson()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('تفاصيل المنتج'), findsOneWidget);
    expect(find.text('قهوة عربية'), findsOneWidget);
    expect(find.text('5.50 د.ل'), findsOneWidget);
    expect(find.text('المتاح'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('المحجوز'), findsNothing);
    expect(find.text('المتوقع'), findsNothing);

    await tester.tap(find.text('حركات المخزون'));
    await tester.pumpAndSettle();

    expect(find.text('زيادة المخزون'), findsOneWidget);
    expect(find.text('4 قطعة'), findsOneWidget);
    expect(find.text('وردت من المورد'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();

    expect(find.text('123456'), findsOneWidget);
    expect(find.text('حبوب مطحونة بعناية'), findsOneWidget);
  });

  testWidgets('catalog product details can create a stock movement', (
    WidgetTester tester,
  ) async {
    Map<String, Object?>? movementBody;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onStockMovement: (request) {
            movementBody = jsonDecode(request.body) as Map<String, Object?>;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المنتجات').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byType(ProductTile).first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('المتاح'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);

    await tester.tap(find.text('حركة مخزون جديدة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '5');
    await tester.enterText(find.byType(TextFormField).last, 'جرد الرف');
    await tester.tap(find.text('حفظ الحركة'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(movementBody?['product'], 1);
    expect(movementBody?['movement_type'], 'increase');
    expect(movementBody?['quantity'], 5);
    expect(movementBody?['note'], 'جرد الرف');
  });

  testWidgets('infinite grid requests more data when content underfills', (
    WidgetTester tester,
  ) async {
    var loadMoreCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 320,
          width: 320,
          child: InfiniteScrollGrid<int>(
            items: const [1],
            hasMore: true,
            isLoadingInitial: false,
            isLoadingMore: false,
            onLoadMore: () async {
              loadMoreCalls += 1;
            },
            emptyBuilder: (_) => const Text('empty'),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 120,
            ),
            itemBuilder: (_, item) => Text('$item'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(loadMoreCalls, 1);
  });

  testWidgets('infinite list requests more data when content underfills', (
    WidgetTester tester,
  ) async {
    var loadMoreCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 320,
          width: 320,
          child: InfiniteScrollList<int>(
            items: const [1],
            hasMore: true,
            isLoadingInitial: false,
            isLoadingMore: false,
            onLoadMore: () async {
              loadMoreCalls += 1;
            },
            emptyBuilder: (_) => const Text('empty'),
            itemBuilder: (_, item) =>
                SizedBox(height: 56, child: Text('$item')),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(loadMoreCalls, 1);
  });
}

Future<void> _startRegisterSession(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), '12.00');
  await tester.tap(find.text('بدء الجلسة'));
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

class _StaticDiscoveryTransport extends PrintTransport {
  const _StaticDiscoveryTransport(this.endpoints);

  final List<PrinterEndpoint> endpoints;

  @override
  Future<List<PrinterEndpoint>> discover() async => endpoints;

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    return const PrintTransportStatus(isAvailable: true, message: 'ready');
  }

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async {
    return const PrintTransportResult.success('printed');
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    return const PrintTransportResult.success('printed');
  }
}

PosApiService _mockApiService({
  bool isAuthenticated = true,
  bool hasOpenSession = false,
  int checkoutStatusCode = 200,
  String currentUserRole = 'manager',
  String currentUserDisplayName = 'مدير النظام',
  List<String> currentUserPermissions = const [],
  void Function(http.Request request)? onCheckout,
  void Function(http.Request request)? onCashMovement,
  void Function(http.Request request)? onReprint,
  void Function(http.Request request)? onReturn,
  void Function(http.Request request)? onVoid,
  void Function(http.Request request)? onPrintJobReport,
  void Function(http.Request request)? onStockMovement,
  void Function(int page)? onOrderPage,
  void Function(http.Request request)? onShopSettingsUpdate,
  bool shopSettingsAutoPrint = false,
  bool shopSettingsRequireOpeningCash = true,
  bool shopSettingsAllowOverselling = false,
  int shopSettingsCashierReturnWindowHours = 42,
  int productQuantityOnHand = 12,
  String registerHistorySessionStatus = 'closed',
  bool orderCanVoid = true,
  bool orderCanReturn = true,
  bool orderRequiresManagerAdjustment = false,
}) {
  var authenticated = isAuthenticated;
  var currentSessionIsOpen = hasOpenSession;

  return PosApiService(
    client: MockClient((request) async {
      final path = request.url.path;

      if (path.endsWith('/auth/me/')) {
        if (!authenticated) {
          return http.Response('', 401);
        }
        return _jsonResponse(
          _userJson(
            displayName: currentUserDisplayName,
            role: currentUserRole,
            permissions: currentUserPermissions,
          ),
        );
      }

      if (path.endsWith('/auth/login/')) {
        authenticated = true;
        return _jsonResponse(
          _userJson(
            displayName: currentUserDisplayName,
            role: currentUserRole,
            permissions: currentUserPermissions,
          ),
        );
      }

      if (path.endsWith('/auth/logout/')) {
        authenticated = false;
        return http.Response('', 204);
      }

      if (path.endsWith('/users/')) {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({
            'id': 3,
            ...body,
            'is_active': body['is_active'] ?? true,
          });
        }
        return _jsonResponseList([
          _userJson(),
          _userJson(
            id: 2,
            username: 'cashier',
            displayName: 'كاشير الوردية',
            role: 'cashier',
          ),
        ]);
      }

      if (path.endsWith('/users/2/')) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return _jsonResponse({
          ..._userJson(
            id: 2,
            username: 'cashier',
            displayName: 'كاشير الوردية',
            role: 'cashier',
          ),
          ...body,
        });
      }

      if (path.endsWith('/shop-settings/')) {
        if (request.method == 'PATCH') {
          onShopSettingsUpdate?.call(request);
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({
            ..._shopSettingsJson(
              autoPrintReceipts: shopSettingsAutoPrint,
              requireOpeningCash: shopSettingsRequireOpeningCash,
              allowOverselling: shopSettingsAllowOverselling,
              cashierReturnWindowHours: shopSettingsCashierReturnWindowHours,
            ),
            ...body,
          });
        }
        return _jsonResponse(
          _shopSettingsJson(
            autoPrintReceipts: shopSettingsAutoPrint,
            requireOpeningCash: shopSettingsRequireOpeningCash,
            allowOverselling: shopSettingsAllowOverselling,
            cashierReturnWindowHours: shopSettingsCashierReturnWindowHours,
          ),
        );
      }

      if (path.endsWith('/register-sessions/current/')) {
        if (!currentSessionIsOpen) {
          return http.Response('', 204);
        }
        return _jsonResponse(_sessionJson(openingCash: '12.00'));
      }

      if (path.endsWith('/register-sessions/start/')) {
        currentSessionIsOpen = true;
        return _jsonResponse(_sessionJson());
      }

      if (path.endsWith('/register-sessions/1/close/')) {
        currentSessionIsOpen = false;
        return _jsonResponse({
          ..._sessionJson(),
          'status': 'closed',
          'closing_cash': '25.50',
        });
      }

      if (path.endsWith('/register-sessions/1/pay-in/') ||
          path.endsWith('/register-sessions/1/pay-out/')) {
        onCashMovement?.call(request);
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return _jsonResponse({
          ..._cashMovementJson(
            movementType: path.endsWith('/pay-out/') ? 'pay_out' : 'pay_in',
          ),
          ...body,
        });
      }

      if (path.endsWith('/register-sessions/1/cash-movements/')) {
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [_cashMovementJson()],
        });
      }

      if (path.endsWith('/register-sessions/1/orders/')) {
        final page =
            int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
        onOrderPage?.call(page);
        if (page == 2) {
          return _jsonResponse({
            'count': 2,
            'next': null,
            'previous':
                'http://localhost/api/register-sessions/1/orders/?page=1',
            'results': [
              _orderJson(
                id: 101,
                receiptNumber: 'R-101',
                total: '3.50',
                quantity: 1,
                createdAt: '2026-05-15T09:15:00Z',
              ),
            ],
          });
        }
        return _jsonResponse({
          'count': 2,
          'next': 'http://localhost/api/register-sessions/1/orders/?page=2',
          'previous': null,
          'results': [
            _orderJson(
              canVoid: orderCanVoid,
              canReturn: orderCanReturn,
              requiresManagerAdjustment: orderRequiresManagerAdjustment,
            ),
          ],
        });
      }

      if (path.endsWith('/register-sessions/')) {
        final page = int.tryParse(request.url.queryParameters['page'] ?? '1');
        if (page == 2) {
          return _jsonResponse({
            'count': 2,
            'next': null,
            'previous': 'http://localhost/api/register-sessions/?page=1',
            'results': [
              _sessionJson(
                id: 2,
                sessionNumber: 'RS-2',
                openingCash: '8.00',
                status: 'closed',
                closingCash: '15.00',
                cashSalesTotal: '7.00',
                expectedCash: '15.00',
              ),
            ],
          });
        }

        return _jsonResponse({
          'count': 2,
          'next': 'http://localhost/api/register-sessions/?page=2',
          'previous': null,
          'results': [
            _sessionJson(
              openingCash: '12.00',
              status: registerHistorySessionStatus,
              closingCash: registerHistorySessionStatus == 'closed'
                  ? '18.75'
                  : null,
              cashSalesTotal: '6.00',
              payInTotal: '5.00',
              payOutTotal: '2.00',
              expectedCash: '19.00',
              denominationTotal: '18.75',
              cashVariance: '-0.25',
              hasCashVariance: true,
              count025: 3,
              count050: 4,
              count075: 5,
              count100: 6,
            ),
          ],
        });
      }

      if (path.endsWith('/products/')) {
        return _jsonResponse(
          _productPageJson(quantityOnHand: productQuantityOnHand),
        );
      }

      if (path.endsWith('/stock/')) {
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [_stockItemJson()],
        });
      }

      if (path.endsWith('/stock-movements/')) {
        if (request.method == 'POST') {
          onStockMovement?.call(request);
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({..._stockMovementJson(), ...body});
        }
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [_stockMovementJson()],
        });
      }

      if (path.endsWith('/orders/checkout/')) {
        onCheckout?.call(request);
        if (checkoutStatusCode < 200 || checkoutStatusCode >= 300) {
          return http.Response('bad request', checkoutStatusCode);
        }
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return _jsonResponse({
          ..._orderJson(),
          if (body['print_invoice'] is Map<String, Object?>)
            'print_job': _printJobJson(status: 'claimed'),
        });
      }

      if (path.endsWith('/orders/100/reprint/')) {
        onReprint?.call(request);
        return _jsonResponse(_printJobJson());
      }

      if (path.endsWith('/orders/100/return-items/')) {
        onReturn?.call(request);
        return _jsonResponse(
          _orderJson(returnedQuantity: 1, returnableQuantity: 1),
        );
      }

      if (path.endsWith('/orders/100/void/')) {
        onVoid?.call(request);
        return _jsonResponse(
          _orderJson(
            status: 'void',
            returnedQuantity: 2,
            returnableQuantity: 0,
          ),
        );
      }

      if (path.endsWith('/print-jobs/501/report/')) {
        onPrintJobReport?.call(request);
        return _jsonResponse(_printJobJson(status: 'printed'));
      }

      return http.Response('not found', 404);
    }),
  );
}

http.Response _jsonResponse(Map<String, Object?> body) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: const {'Content-Type': 'application/json; charset=utf-8'},
  );
}

http.Response _jsonResponseList(List<Object?> body) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: const {'Content-Type': 'application/json; charset=utf-8'},
  );
}

Map<String, Object?> _userJson({
  int id = 1,
  String username = 'manager',
  String displayName = 'مدير النظام',
  String role = 'manager',
  List<String> permissions = const [],
}) {
  return {
    'id': id,
    'username': username,
    'display_name': displayName,
    'email': '',
    'role': role,
    'permissions': permissions,
    'is_active': true,
  };
}

Map<String, Object?> _sessionJson({
  int id = 1,
  String sessionNumber = 'RS-1',
  String status = 'open',
  String openingCash = '0.00',
  String? closingCash,
  int count025 = 0,
  int count050 = 0,
  int count075 = 0,
  int count100 = 0,
  String cashSalesTotal = '0.00',
  String payInTotal = '0.00',
  String payOutTotal = '0.00',
  String cashRefundTotal = '0.00',
  String expectedCash = '0.00',
  String denominationTotal = '0.00',
  String? cashVariance,
  bool hasCashVariance = false,
}) {
  return {
    'id': id,
    'session_number': sessionNumber,
    'status': status,
    'opening_cash': openingCash,
    'closing_cash': closingCash,
    'count_025': count025,
    'count_050': count050,
    'count_075': count075,
    'count_100': count100,
    'cash_sales_total': cashSalesTotal,
    'pay_in_total': payInTotal,
    'pay_out_total': payOutTotal,
    'cash_refund_total': cashRefundTotal,
    'expected_cash': expectedCash,
    'denomination_total': denominationTotal,
    'cash_variance': cashVariance,
    'has_cash_variance': hasCashVariance,
    'opened_at': '2026-05-15T09:00:00Z',
    'closed_at': status == 'closed' ? '2026-05-15T17:00:00Z' : null,
    'created_at': '2026-05-15T09:00:00Z',
    'updated_at': '2026-05-15T09:00:00Z',
  };
}

Map<String, Object?> _shopSettingsJson({
  bool autoPrintReceipts = false,
  bool requireOpeningCash = true,
  bool allowOverselling = false,
  int cashierReturnWindowHours = 42,
}) {
  return {
    'shop_name': 'متجر نقطة البيع',
    'receipt_header': 'أهلا بكم',
    'receipt_footer': 'شكرا لزيارتكم',
    'require_opening_cash': requireOpeningCash,
    'auto_print_receipts': autoPrintReceipts,
    'allow_overselling': allowOverselling,
    'low_stock_threshold': 5,
    'cashier_return_window_hours': cashierReturnWindowHours,
  };
}

Map<String, Object?> _productPageJson({int quantityOnHand = 12}) {
  return {
    'next': null,
    'results': [
      {
        'id': 1,
        'sku': 'COF-001',
        'name': 'قهوة البيت',
        'unit_price': '3.50',
        'barcode': '',
        'description': '',
        'is_active': true,
        'quantity_on_hand': quantityOnHand,
      },
    ],
  };
}

Map<String, Object?> _stockItemJson() {
  return {
    'id': 1,
    'product': 1,
    'quantity_on_hand': 12,
    'quantity_committed': 2,
    'quantity_expected': 7,
    'reorder_level': 5,
    'created_at': '2026-05-15T09:00:00Z',
    'updated_at': '2026-05-15T09:00:00Z',
  };
}

Map<String, Object?> _stockMovementJson() {
  return {
    'id': 1,
    'product': 1,
    'stock_item': 1,
    'movement_type': 'increase',
    'quantity': 4,
    'note': 'وردت من المورد',
    'created_by': 1,
    'created_by_name': 'manager',
    'on_hand_before': 8,
    'on_hand_after': 12,
    'committed_before': 2,
    'committed_after': 2,
    'expected_before': 7,
    'expected_after': 7,
    'created_at': '2026-05-15T09:30:00Z',
    'updated_at': '2026-05-15T09:30:00Z',
  };
}

Map<String, Object?> _cashMovementJson({
  int id = 1,
  String movementType = 'pay_in',
  String amount = '12.00',
  String reason = 'تسوية الصندوق',
}) {
  return {
    'id': id,
    'register_session': 1,
    'session_number': 'RS-1',
    'movement_type': movementType,
    'amount': amount,
    'reason': reason,
    'created_by': 1,
    'created_by_username': 'manager',
    'created_at': '2026-05-15T09:20:00Z',
    'updated_at': '2026-05-15T09:20:00Z',
  };
}

Map<String, Object?> _orderJson({
  int id = 100,
  String receiptNumber = 'R-100',
  String status = 'paid',
  String total = '7.00',
  int quantity = 2,
  int returnedQuantity = 0,
  int? returnableQuantity,
  bool canVoid = true,
  bool canReturn = true,
  bool requiresManagerAdjustment = false,
  String createdAt = '2026-05-15T09:10:00Z',
}) {
  return {
    'id': id,
    'receipt_number': receiptNumber,
    'status': status,
    'register_session': 1,
    'register_session_number': 'RS-1',
    'lines': [
      {
        'id': 1000,
        'product': 1,
        'product_name': 'قهوة البيت',
        'quantity': quantity,
        'returned_quantity': returnedQuantity,
        'returnable_quantity':
            returnableQuantity ?? quantity - returnedQuantity,
        'unit_price': '3.50',
        'line_total': total,
      },
    ],
    'subtotal': total,
    'total': total,
    'can_void': canVoid,
    'can_return': canReturn,
    'requires_manager_adjustment': requiresManagerAdjustment,
    'created_at': createdAt,
    'updated_at': createdAt,
  };
}

Map<String, Object?> _printJobJson({String status = 'queued'}) {
  return {
    'id': 501,
    'status': status,
    'job_type': 'receipt',
    'order': 100,
    'receipt_number': 'R-100',
    'payload': {'receipt_number': 'R-100'},
    'created_at': '2026-05-15T09:11:00Z',
    'updated_at': '2026-05-15T09:11:00Z',
  };
}

void _setFakePrinterConfig() {
  SharedPreferences.setMockInitialValues({
    'default_printer_config': jsonEncode({
      'endpoint': {'kind': 'fake', 'name': 'محاكاة الطابعة', 'address': 'fake'},
      'is_enabled': true,
      'auto_claim_jobs': true,
      'agent_id': 'pointy-local-agent',
    }),
  });
}
