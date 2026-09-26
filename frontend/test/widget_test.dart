import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/barcode_label.dart';
import 'package:pointy_frontend/src/data/models/card_payment_receipt.dart';
import 'package:pointy_frontend/src/data/models/device_settings.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/device_printers.dart';
import 'package:pointy_frontend/src/data/models/print_job.dart';
import 'package:pointy_frontend/src/data/models/printer_config.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/register_cash_movement.dart';
import 'package:pointy_frontend/src/app.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_details_screen.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';
import 'package:pointy_frontend/src/data/repositories/attendance_repository.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/device_settings_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/inventory_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/features/returns_exchange/views/returns_exchange_lookup_screen.dart';
import 'package:pointy_frontend/src/data/services/barcode_label_command_encoder.dart';
import 'package:pointy_frontend/src/data/services/esc_pos_receipt_encoder.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/data/services/print_transport.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/category_management_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_stock_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/category_management_screen.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_image_picker.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_variant_details_screen.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_order_details_screen.dart';
import 'package:pointy_frontend/src/features/printing/view_models/printing_settings_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/register_cash_movement_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/register_session_close_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/payment/payment_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_catalog_pane.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_catalog_pane.dart';
import 'package:pointy_frontend/src/features/users/view_models/user_management_view_model.dart';
import 'package:pointy_frontend/src/features/users/views/user_management_screen.dart';
import 'package:pointy_frontend/src/data/models/employee.dart';
import 'package:pointy_frontend/src/data/repositories/dashboard_repository.dart';
import 'package:pointy_frontend/src/data/repositories/employee_repository.dart';
import 'package:pointy_frontend/src/data/repositories/fraud_repository.dart';
import 'package:pointy_frontend/src/features/dashboard/view_models/dashboard_view_model.dart';
import 'package:pointy_frontend/src/features/dashboard/views/dashboard_screen.dart';
import 'package:pointy_frontend/src/features/fraud/view_models/integrity_monitor_view_model.dart';
import 'package:pointy_frontend/src/features/fraud/views/integrity_monitor_screen.dart';
import 'package:pointy_frontend/src/features/attendance/view_models/attendance_view_model.dart';
import 'package:pointy_frontend/src/features/employees/view_models/employee_payroll_view_model.dart';
import 'package:pointy_frontend/src/features/employees/views/employee_payroll_screen.dart';
import 'package:pointy_frontend/src/features/employees/views/payroll_run_details_screen.dart';
import 'package:pointy_frontend/src/shared/components/pointy_navigation_surface.dart';
import 'package:pointy_frontend/src/shared/components/pointy_password_field.dart';
import 'package:pointy_frontend/src/shared/responsive/adaptive_modal.dart';
import 'package:pointy_frontend/src/shared/infinite_scroll_grid.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/product_tile.dart';

import 'shared/fake_app_navigation.dart';
import 'support/key_value_store_testing.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

/// Stands in for the native save-file dialog: records the bytes the analytics
/// export handed off and reports back a fixed destination path.
class _FakeSaveFilePicker extends FilePickerPlatform
    with MockPlatformInterfaceMixin {
  String? returnedPath = '/Users/tester/Downloads/analytics-events.csv';
  Uint8List? savedBytes;
  String? savedFileName;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    savedFileName = fileName;
    savedBytes = bytes;
    return returnedPath;
  }
}

void main() {
  setUp(() {
    installMemoryKeyValueStore();
  });

  test('printer endpoint parses transport and barcode label options', () {
    final endpoint = PrinterEndpoint.fromJson({
      'kind': 'wifi',
      'name': 'Counter',
      'address': '192.168.1.50',
      'port': 9100,
      'paper_width_mm': 58,
      'code_table': 'CP1256',
      'timeout_ms': 3000,
      'barcode_label_language': 'zpl',
      'label_width_mm': 50,
      'label_height_mm': 25,
      'label_gap_mm': 3,
      'label_dpi': 300,
    });

    expect(endpoint.kind, PrintTransportKind.wifi);
    expect(endpoint.address, '192.168.1.50');
    expect(endpoint.port, 9100);
    expect(endpoint.paperWidthMm, 58);
    expect(endpoint.codeTable, 'CP1256');
    expect(endpoint.timeoutMs, 3000);
    expect(endpoint.outputMode, PrinterOutputMode.escPos);
    expect(endpoint.barcodeLabelLanguage, BarcodeLabelPrinterLanguage.zpl);
    expect(endpoint.labelWidthMm, 50);
    expect(endpoint.labelHeightMm, 25);
    expect(endpoint.labelGapMm, 3);
    expect(endpoint.labelDpi, 300);
    expect(
      PrinterEndpoint.fromJson({'kind': 'bluetooth'}).kind,
      PrintTransportKind.bluetooth,
    );
    final systemPrinter = PrinterEndpoint.fromJson({
      'kind': 'system',
      'output_mode': 'pdf_a4',
    });
    expect(systemPrinter.kind, PrintTransportKind.system);
    expect(systemPrinter.outputMode, PrinterOutputMode.pdfA4);
    expect(
      PrinterEndpoint.fromJson({}).barcodeLabelLanguage,
      BarcodeLabelPrinterLanguage.auto,
    );
    // Receipt-protocol label printers (HPRT LPQ58/LPQ80 in ESC/POS mode) must
    // resolve to escPos, not fall back to auto — auto re-picks ZPL, which is
    // the silent fallback that printed nothing. Both the wire spelling and the
    // one `barcodeLabelPrinterLanguageToJson` emits have to round-trip.
    for (final value in ['esc_pos', 'escpos']) {
      expect(
        PrinterEndpoint.fromJson({
          'barcode_label_language': value,
        }).barcodeLabelLanguage,
        BarcodeLabelPrinterLanguage.escPos,
        reason: '$value should parse as ESC/POS',
      );
    }
  });

  test('Moamalat receipt parser decodes the terminal receipt URL', () {
    final receipt = const MoamalatReceiptParser().parse(
      _sampleMoamalatReceiptUrl,
    );

    expect(receipt.amount, 1.0);
    expect(receipt.maskedPan, '639974*********8809');
    expect(receipt.reference, '615316000050');
    expect(receipt.isSuccessful, isTrue);
  });

  test('purchasing permissions expose workflow capabilities', () {
    final cashier = PosUser.fromJson(
      _userJson(
        role: 'cashier',
        permissions: const [
          'purchasing.view_purchaseorder',
          'purchasing.edit_draft_purchaseorder',
          'purchasing.receive_purchaseorder',
          'purchasing.adjust_received_purchaseorder',
          'purchasing.cancel_purchaseorder',
          'purchasing.delete_purchaseorder',
        ],
      ),
    );

    final capabilities = AuthorizationCapabilities.forUser(cashier);

    expect(capabilities.canAccessPurchasing, isTrue);
    expect(capabilities.canEditDraftPurchaseOrder, isTrue);
    expect(capabilities.canReceivePurchaseOrder, isTrue);
    expect(capabilities.canAdjustPurchaseOrder, isTrue);
    expect(capabilities.canCancelPurchaseOrder, isTrue);
    expect(capabilities.canDeletePurchaseOrder, isTrue);
    expect(capabilities.canCreatePurchaseOrder, isFalse);
  });

  test('taking payments does not mean reading the shop\'s accounts', () {
    // The till asked for the bank accounts on every cashier sign-in and was
    // refused every time (403, field export 2026-09-25): a cashier holds
    // payments.view_payment but not treasury.view_moneyaccount.
    final cashier = PosUser.fromJson(
      _userJson(
        role: 'cashier',
        permissions: const ['payments.add_payment', 'payments.view_payment'],
      ),
    );
    final accountant = PosUser.fromJson(
      _userJson(
        role: 'accountant',
        permissions: const ['treasury.view_moneyaccount'],
      ),
    );

    expect(
      AuthorizationCapabilities.forUser(cashier).canViewMoneyAccounts,
      isFalse,
    );
    expect(
      AuthorizationCapabilities.forUser(accountant).canViewMoneyAccounts,
      isTrue,
    );
  });

  test('discount permissions expose management capabilities', () {
    final cashier = PosUser.fromJson(
      _userJson(
        role: 'cashier',
        permissions: const [
          'discounts.view_discountrule',
          'discounts.add_discountrule',
          'discounts.change_discountrule',
          'discounts.delete_discountrule',
        ],
      ),
    );

    final capabilities = AuthorizationCapabilities.forUser(cashier);

    expect(capabilities.canViewDiscountRules, isTrue);
    expect(capabilities.canCreateDiscountRule, isTrue);
    expect(capabilities.canChangeDiscountRule, isTrue);
    expect(capabilities.canDeleteDiscountRule, isTrue);
  });

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
          'public_invoice_url':
              'https://relay.example/invoices/installation-1/public-token',
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
    final printedText = utf8.decode(bytes, allowMalformed: true);
    expect(printedText, contains('https://relay.example/invoices'));
    expect(printedText, isNot(contains('x1')));
  });

  test('native barcode label encoder requires a resolved language', () async {
    await expectLater(
      const BarcodeLabelCommandEncoder().encodeLabels(
        endpoint: const PrinterEndpoint(
          kind: PrintTransportKind.serial,
          name: 'Counter',
          address: '/dev/tty.test',
        ),
        lines: const [
          BarcodeLabelPrintLine(
            label: BarcodeLabelDraft(
              displayName: 'قهوة عربية',
              productName: 'قهوة عربية',
              sku: 'COF-100',
              barcode: '123456789012',
              unitPrice: 5.5,
            ),
            copies: 2,
          ),
        ],
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('native barcode label encoder emits label-language commands', () async {
    const line = BarcodeLabelPrintLine(
      label: BarcodeLabelDraft(
        displayName: 'قهوة عربية',
        productName: 'قهوة عربية',
        sku: 'COF-100',
        barcode: '987654321098',
        unitPrice: 5.5,
      ),
      copies: 2,
      includePrice: false,
    );
    const endpoint = PrinterEndpoint(
      kind: PrintTransportKind.wifi,
      name: 'Label printer',
      address: '192.168.1.50',
      labelWidthMm: 40,
      labelHeightMm: 30,
      labelGapMm: 2,
      labelDpi: 203,
    );

    for (final entry in {
      BarcodeLabelPrinterLanguage.zpl: ['^XA', '^PW', '^BCN', '^PQ2'],
      BarcodeLabelPrinterLanguage.tspl: [
        'SIZE 40 mm,30 mm',
        'GAP 2 mm,0',
        'BARCODE',
        'PRINT 2,1',
      ],
      BarcodeLabelPrinterLanguage.epl: ['N', 'q', 'Q', 'B', 'P2'],
      BarcodeLabelPrinterLanguage.cpcl: [
        '! 0 200 200',
        'PAGE-WIDTH',
        'BARCODE 128',
        'PRINT',
      ],
    }.entries) {
      final bytes = await const BarcodeLabelCommandEncoder().encodeLabels(
        endpoint: endpoint.copyWith(barcodeLabelLanguage: entry.key),
        language: entry.key,
        lines: const [line],
      );
      final text = utf8.decode(bytes);

      for (final expected in entry.value) {
        expect(text, contains(expected), reason: entry.key.name);
      }
      expect(text, contains('987654321098'));
      expect(text, isNot(contains('5.50')));
    }
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

      final saveResult = await repository.saveDevicePrinters(
        const DevicePrinters([
          DevicePrinter(
            id: 'counter',
            config: PrinterConfig(
              endpoint: endpoint,
              isEnabled: false,
              autoClaimJobs: false,
            ),
            roles: {PrinterRole.posReceipt},
          ),
        ]),
      );
      expect(saveResult, isA<Ok<void>>());

      final loadResult = await repository.loadReceiptPrinterConfig();
      final config = switch (loadResult) {
        Ok<PrinterConfig>() => loadResult.value,
        Error<PrinterConfig>() => fail('Receipt printer should load'),
      };

      expect(config.endpoint.address, '192.168.1.55');
      expect(config.isEnabled, isTrue);
      expect(config.autoClaimJobs, isTrue);
    },
  );

  test('device settings repository persists usage mode', () async {
    final repository = DeviceSettingsRepository();

    final initialResult = await repository.loadUsageMode();
    expect(switch (initialResult) {
      Ok<DeviceUsageMode>(value: final mode) => mode,
      Error<DeviceUsageMode>() => fail('Usage mode should load'),
    }, DeviceUsageMode.singleUser);

    final saveResult = await repository.saveUsageMode(
      DeviceUsageMode.multiUser,
    );
    expect(saveResult, isA<Ok<void>>());

    final loadedResult = await repository.loadUsageMode();
    expect(switch (loadedResult) {
      Ok<DeviceUsageMode>(value: final mode) => mode,
      Error<DeviceUsageMode>() => fail('Usage mode should load'),
    }, DeviceUsageMode.multiUser);
  });

  test(
    'printing repository migrates and mirrors the legacy receipt printer',
    () async {
      final store = installMemoryKeyValueStore({
        'default_printer_config': jsonEncode({
          'endpoint': {
            'kind': 'serial',
            'name': 'Legacy',
            'address': '/dev/tty.legacy',
          },
        }),
      });
      final repository = PrintingRepository(_mockApiService());

      final migratedResult = await repository.loadReceiptPrinterConfig();
      final migratedConfig = switch (migratedResult) {
        Ok<PrinterConfig>(value: final config) => config,
        Error<PrinterConfig>() => fail('POS receipt printer should load'),
      };
      expect(migratedConfig.endpoint.address, '/dev/tty.legacy');

      final saveResult = await repository.saveDevicePrinters(
        const DevicePrinters([
          DevicePrinter(
            id: 'counter',
            config: PrinterConfig(
              endpoint: PrinterEndpoint(
                kind: PrintTransportKind.wifi,
                name: 'Counter',
                address: '192.168.1.55',
                port: 9100,
              ),
            ),
            roles: {PrinterRole.posReceipt},
          ),
        ]),
      );
      expect(saveResult, isA<Ok<void>>());

      // An older build still reads these two keys for its receipt printer.
      expect(
        await store.getString('printer_role_configs'),
        contains('pos_receipt'),
      );
      expect(
        await store.getString('default_printer_config'),
        contains('192.168.1.55'),
      );
    },
  );

  test(
    'printing settings view model tracks disconnected printer health',
    () async {
      _setFakePrinterConfig();
      final transport = _StatusPrintTransport(isAvailable: false);
      final viewModel = PrintingSettingsViewModel(
        PrintingRepository(
          _mockApiService(),
          serialTransport: transport,
          bluetoothTransport: transport,
          wifiTransport: transport,
          fakeTransport: transport,
        ),
        autoLoad: false,
        statusCheckInterval: const Duration(hours: 1),
      );
      addTearDown(viewModel.dispose);

      await viewModel.load();
      await Future<void>.delayed(Duration.zero);

      expect(viewModel.receiptPrinter, isNotNull);
      expect(viewModel.connectionState, PrinterConnectionState.disconnected);
      expect(viewModel.shouldWarnPrinterDisconnected, isTrue);
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
    await _confirmPayment(tester);

    expect(checkoutBody, isNotNull);
    expect(checkoutBody?['payments'], [
      {'method': 'cash', 'amount': '7.00'},
    ]);
    expect(checkoutBody?['lines'], [
      {'variant': 1, 'quantity': '2'},
    ]);
    expect(find.text('لا توجد عناصر في السلة'), findsOneWidget);
    expect(find.text('تم تسجيل البيع. رقم الإيصال: R-100'), findsOneWidget);
  });

  testWidgets('checkout can select an existing customer', (
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
    await tester.tap(find.byTooltip('إعدادات الفاتورة'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('تغيير'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('ليلى أحمد').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();
    await tester.tap(find.text('ادفع 3.50 د.ل'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _confirmPayment(tester);

    expect(checkoutBody?['customer'], 12);
  });

  testWidgets('checkout can split tender across cash and card', (
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
    await tester.tap(find.text('إضافة دفعة'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('payment_tender_amount_0')),
      '5.00',
    );
    await tester.pump();
    await _confirmPayment(tester);

    expect(checkoutBody?['payments'], [
      {'method': 'cash', 'amount': '5.00'},
      {'method': 'card', 'amount': '2.00'},
    ]);
  });

  testWidgets('payment sheet requires validated Moamalat receipt for card', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    PaymentSheetResult? result;

    await tester.pumpWidget(
      _localizedTestApp(
        PaymentSheet(
          total: 1,
          enableCashPayments: true,
          enableCardPayments: true,
          enableTransferPayments: false,
          requireCardReceipt: true,
          trustedCardTerminalIds: const ['0JA8Y13W'],
          showPrintInvoiceToggle: false,
          printInvoiceAfterPayment: false,
          onPrintInvoiceChanged: (_) {},
          showShareInvoiceToggle: false,
          shareInvoiceAfterPayment: false,
          onShareInvoiceChanged: (_) {},
          onSubmit: (submitted) => result = submitted,
          onCancel: () {},
        ),
      ),
    );

    await tester.tap(find.text('بطاقة'));
    await tester.pumpAndSettle();

    expect(find.text('هذه الدفعة تحتاج مسح إيصال البطاقة.'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('payment_confirm_button')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('payment_card_receipt_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('card_receipt_url_field')),
      _sampleMoamalatReceiptUrl,
    );
    await tester.tap(find.text('طابق الإيصال').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('تمت المطابقة'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('payment_confirm_button')));
    await tester.pump();

    expect(result?.payments.single.toJson(), {
      'method': 'card',
      'amount': '1.00',
      'card_receipt_url': _sampleMoamalatReceiptUrl,
    });
  });

  testWidgets('checkout rebalances split tender after deleting a line', (
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
    await tester.tap(find.text('إضافة دفعة'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('payment_tender_amount_0')),
      '5.00',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('payment_tender_remove_0')));
    await tester.pumpAndSettle();
    await _confirmPayment(tester);

    expect(checkoutBody?['payments'], [
      {'method': 'card', 'amount': '7.00'},
    ]);
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
      await _confirmPayment(tester);

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
    await _confirmPayment(tester);

    expect(checkoutBody?['print_invoice'], isA<Map<String, Object?>>());
    expect(reportCalls, 1);
    expect(
      find.text(
        'تم تسجيل البيع. رقم الإيصال: R-100 تم إرسال الفاتورة للطابعة.',
      ),
      findsOneWidget,
    );
  });

  test(
    'printing repository requeues post-sale print job after local failure',
    () async {
      final reportBodies = <Map<String, Object?>>[];
      var requeueCalls = 0;
      final repository = PrintingRepository(
        _mockApiService(
          onPrintJobReport: (request) {
            reportBodies.add(jsonDecode(request.body) as Map<String, Object?>);
          },
          onPrintJobRequeue: (_) => requeueCalls += 1,
        ),
        serialTransport: const _StatusPrintTransport(isAvailable: false),
      );
      const config = PrinterConfig(
        endpoint: PrinterEndpoint(
          kind: PrintTransportKind.serial,
          name: 'Counter printer',
          address: '/dev/tty.usbserial',
        ),
      );
      final job = PrintJob.fromJson(_printJobJson(status: 'claimed'));

      final result = await repository.printAndReportJob(
        job: job,
        config: config,
        requeueOnFailure: true,
      );

      expect(result, isA<Error<PrintJob>>());
      expect(reportBodies, hasLength(1));
      expect(reportBodies.single['status'], 'failed');
      expect(reportBodies.single['error_message'], 'offline');
      expect(requeueCalls, 1);
    },
  );

  test('printing repository sends product barcode label bytes', () async {
    final transport = _CapturingPrintTransport();
    final repository = PrintingRepository(
      _mockApiService(),
      serialTransport: transport,
      bluetoothTransport: transport,
      wifiTransport: transport,
      fakeTransport: transport,
    );
    await _saveOnlyPrinter(
      repository,
      const PrinterConfig(
        endpoint: PrinterEndpoint(
          kind: PrintTransportKind.serial,
          name: 'Label printer',
          address: '/dev/tty.label',
        ),
      ),
    );

    final result = await repository.printBarcodeLabels([
      BarcodeLabelPrintLine.product(
        const Product(
          id: 1,
          name: 'قهوة عربية',
          quantityOnHand: 10,
          defaultVariant: ProductVariant(
            id: 1,
            productId: 1,
            sku: 'COF-100',
            unitPrice: 5.5,
            barcode: '123456789012',
          ),
        ),
      ),
    ]);

    expect(result.isSuccess, isTrue);
    final text = utf8.decode(transport.printedBytes);
    expect(text, contains('^XA'));
    expect(text, contains('^PQ1'));
    expect(text, contains('123456789012'));
  });

  test('printing repository sends native ZPL barcode label bytes', () async {
    final transport = _CapturingPrintTransport();
    final repository = PrintingRepository(
      _mockApiService(),
      serialTransport: transport,
      bluetoothTransport: transport,
      wifiTransport: transport,
      fakeTransport: transport,
    );
    await _saveOnlyPrinter(
      repository,
      const PrinterConfig(
        endpoint: PrinterEndpoint(
          kind: PrintTransportKind.wifi,
          name: 'Zebra ZD421',
          address: '192.168.1.50',
          barcodeLabelLanguage: BarcodeLabelPrinterLanguage.zpl,
          labelWidthMm: 40,
          labelHeightMm: 30,
          labelGapMm: 2,
        ),
      ),
    );

    final result = await repository.printBarcodeLabels([
      BarcodeLabelPrintLine.product(
        const Product(
          id: 1,
          name: 'قهوة عربية',
          quantityOnHand: 10,
          defaultVariant: ProductVariant(
            id: 1,
            productId: 1,
            sku: 'COF-100',
            unitPrice: 5.5,
            barcode: '123456789012',
          ),
        ),
        copies: 2,
      ),
    ]);
    final text = utf8.decode(transport.printedBytes);

    expect(result.isSuccess, isTrue);
    expect(text, contains('^XA'));
    expect(text, contains('^BCN'));
    expect(text, contains('^PQ2'));
    expect(text, contains('123456789012'));
  });

  test(
    'printing repository safely auto-detects barcode label language',
    () async {
      final transport = _CapturingPrintTransport(
        probeResponse: PrintTransportResponse.success(
          utf8.encode('zpl'),
          'language',
        ),
      );
      final repository = PrintingRepository(
        _mockApiService(),
        serialTransport: transport,
        bluetoothTransport: transport,
        wifiTransport: transport,
        fakeTransport: transport,
      );
      await _saveOnlyPrinter(
        repository,
        const PrinterConfig(
          endpoint: PrinterEndpoint(
            kind: PrintTransportKind.wifi,
            name: 'Label printer',
            address: '192.168.1.50',
            barcodeLabelLanguage: BarcodeLabelPrinterLanguage.auto,
          ),
        ),
      );

      final result = await repository.printBarcodeLabels([
        BarcodeLabelPrintLine.product(
          const Product(
            id: 1,
            name: 'قهوة عربية',
            quantityOnHand: 10,
            defaultVariant: ProductVariant(
              id: 1,
              productId: 1,
              sku: 'COF-100',
              unitPrice: 5.5,
              barcode: '123456789012',
            ),
          ),
        ),
      ]);
      final text = utf8.decode(transport.printedBytes);

      expect(result.isSuccess, isTrue);
      expect(text, contains('^XA'));
    },
  );

  test(
    'printing repository falls back to ZPL when auto-detection fails',
    () async {
      final transport = _CapturingPrintTransport();
      final repository = PrintingRepository(
        _mockApiService(),
        serialTransport: transport,
        bluetoothTransport: transport,
        wifiTransport: transport,
        fakeTransport: transport,
      );
      await _saveOnlyPrinter(
        repository,
        const PrinterConfig(
          endpoint: PrinterEndpoint(
            kind: PrintTransportKind.wifi,
            name: 'Unknown label printer',
            address: '192.168.1.50',
            barcodeLabelLanguage: BarcodeLabelPrinterLanguage.auto,
          ),
        ),
      );

      final result = await repository.printBarcodeLabels([
        BarcodeLabelPrintLine.product(
          const Product(
            id: 1,
            name: 'قهوة عربية',
            quantityOnHand: 10,
            defaultVariant: ProductVariant(
              id: 1,
              productId: 1,
              sku: 'COF-100',
              unitPrice: 5.5,
              barcode: '123456789012',
            ),
          ),
        ),
      ]);
      final text = utf8.decode(transport.printedBytes);

      expect(result.isSuccess, isTrue);
      expect(text, contains('^XA'));
      expect(text, contains('^BCN'));
      expect(text, contains('123456789012'));
    },
  );

  test('printing repository sends a barcode label test print', () async {
    final transport = _CapturingPrintTransport();
    final repository = PrintingRepository(
      _mockApiService(),
      serialTransport: transport,
      bluetoothTransport: transport,
      wifiTransport: transport,
      fakeTransport: transport,
    );
    const config = PrinterConfig(
      endpoint: PrinterEndpoint(
        kind: PrintTransportKind.wifi,
        name: 'Zebra ZD421',
        address: '192.168.1.50',
        barcodeLabelLanguage: BarcodeLabelPrinterLanguage.zpl,
      ),
    );

    final result = await repository.printBarcodeLabelTest(config);
    final text = utf8.decode(transport.printedBytes);

    expect(result.isSuccess, isTrue);
    expect(text, contains('^XA'));
    expect(text, contains('ملصق اختبار'));
    expect(text, contains('TEST-LABEL'));
    expect(text, contains('123456789012'));
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
    await _confirmPayment(tester);

    expect(find.text('ادفع 3.50 د.ل'), findsOneWidget);
    expect(
      find.text('تعذر تسجيل البيع. تحقق من جلسة الدرج وحاول مرة أخرى.'),
      findsOneWidget,
    );
    expect(find.text('لا توجد عناصر في السلة'), findsNothing);
  });

  testWidgets('checkout surfaces a clear message when the session is stale', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(checkoutNoOpenSession: true)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _startRegisterSession(tester);
    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    await tester.tap(find.text('ادفع 3.50 د.ل'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _confirmPayment(tester);

    // Instead of the generic error, the cashier sees an actionable message
    // telling them to open a new register session.
    expect(
      find.text(
        'لم تعد جلسة الدرج مفتوحة. يرجى فتح جلسة درج جديدة ثم إعادة المحاولة.',
      ),
      findsOneWidget,
    );
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
    await _confirmPayment(tester);

    expect(checkoutBody, isNotNull);
    expect(find.text('تم تسجيل البيع. رقم الإيصال: R-100'), findsOneWidget);
  });

  testWidgets('checkout sells a made-to-order product with no own stock', (
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
          // A recipe/made-to-order product carries no stock of its own and
          // overselling is off — the POS must not block it on a phantom
          // shortage (the backend skips stock for prepared products).
          productQuantityOnHand: 0,
          productIsPrepared: true,
          shopSettingsAllowOverselling: false,
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

    await tester.tap(find.text('ادفع 3.50 د.ل'));
    await tester.pumpAndSettle();

    // No stock warning dialog appears; checkout proceeds straight to payment.
    expect(find.text('تنبيه المخزون'), findsNothing);
    await _confirmPayment(tester);

    expect(checkoutBody, isNotNull);
    expect(find.text('تم تسجيل البيع. رقم الإيصال: R-100'), findsOneWidget);
  });

  testWidgets('checkout blocks loss sale when protection is enabled', (
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
          saleDiscountPreviewHasLoss: true,
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

    await tester.tap(find.text('ادفع 3.50 د.ل'));
    await tester.pumpAndSettle();

    expect(find.text('تنبيه الخسارة'), findsOneWidget);
    expect(
      find.text('لا يمكن إتمام البيع لأن إعدادات المتجر تمنع البيع بخسارة.'),
      findsOneWidget,
    );
    expect(find.text('قهوة البيت: الخسارة 1.00 د.ل'), findsOneWidget);
    expect(find.text('تأكيد الدفع'), findsNothing);
    expect(checkoutBody, isNull);
  });

  testWidgets('checkout warns before allowed loss sale', (
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
          shopSettingsPreventSellingAtLoss: false,
          saleDiscountPreviewHasLoss: true,
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

    await tester.tap(find.text('ادفع 3.50 د.ل'));
    await tester.pumpAndSettle();

    expect(find.text('تنبيه الخسارة'), findsOneWidget);
    expect(
      find.text(
        'نحن نبيع بعض عناصر السلة بخسارة. هل تريد إتمام البيع رغم ذلك؟',
      ),
      findsOneWidget,
    );
    expect(checkoutBody, isNull);

    await tester.tap(find.text('إتمام البيع'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await _confirmPayment(tester);

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

    expect(find.text('لوحة التحكم'), findsWidgets);
    await _openPosFromDashboard(tester);
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

  testWidgets('register gate renders on phone width before starting POS', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openPosFromDashboard(tester);

    expect(find.text('جلسة الدرج'), findsOneWidget);
    expect(
      find.text('لا توجد جلسة درج مفتوحة. ابدأ جلسة جديدة قبل البيع.'),
      findsOneWidget,
    );
    expect(find.text('بدء الجلسة'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

    await _openPosFromDashboard(tester);
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

    await _openNavigationDestination(tester, 'المنتجات');

    expect(find.text('إدارة المنتجات'), findsOneWidget);
    expect(find.text('إضافة منتج'), findsOneWidget);
    expect(find.text('منتج جديد'), findsNothing);

    await tester.tap(find.text('إضافة منتج'));
    await tester.pumpAndSettle();

    expect(find.text('منتج جديد'), findsOneWidget);
    expect(find.text('اسم المنتج'), findsOneWidget);
    expect(find.text('بيانات المنتج'), findsOneWidget);
    expect(find.text('التالي'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, 'قهوة عربية');
    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();

    expect(find.text('الخيار الافتراضي'), findsOneWidget);
    expect(find.text('رمز المنتج'), findsOneWidget);
    expect(find.text('إنشاء المنتج'), findsOneWidget);
  });

  testWidgets('category tree lazily pages roots and children', (
    WidgetTester tester,
  ) async {
    final categoryRequests = <Uri>[];
    final apiService = _mockApiService(
      onProductCategoryRequest: (request) {
        categoryRequests.add(request.url);
      },
    );
    final manager = PosUser.fromJson(_userJson(role: 'manager'));

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
        home: CategoryManagementScreen(
          viewModel: CategoryManagementViewModel(CatalogRepository(apiService)),
          navigation: FakeAppNavigation(currentUser: manager),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('مشروبات'), findsOneWidget);
    expect(
      categoryRequests.any(
        (uri) =>
            uri.queryParameters['root'] == 'true' &&
            uri.queryParameters['page'] == '1',
      ),
      isTrue,
    );
    expect(
      categoryRequests.any(
        (uri) =>
            uri.queryParameters['root'] == 'true' &&
            uri.queryParameters['page'] == '2',
      ),
      isTrue,
    );

    await tester.tap(find.byTooltip('عرض الفروع'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('قهوة'), findsOneWidget);
    expect(find.text('تحميل فروع إضافية'), findsOneWidget);
    expect(
      categoryRequests.any(
        (uri) =>
            uri.queryParameters['parent'] == '1' &&
            uri.queryParameters['page'] == '1',
      ),
      isTrue,
    );

    await tester.tap(find.text('تحميل فروع إضافية'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('شاي'), findsOneWidget);
    expect(
      categoryRequests.any(
        (uri) =>
            uri.queryParameters['parent'] == '1' &&
            uri.queryParameters['page'] == '2',
      ),
      isTrue,
    );
  });

  testWidgets('POS screen exposes reusable search and ordering controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _startRegisterSession(tester);

    expect(find.text('ابحث عن منتج أو امسح الباركود'), findsOneWidget);
    expect(find.byTooltip('الفلاتر والترتيب'), findsOneWidget);

    await tester.tap(find.byTooltip('الفلاتر والترتيب'));
    await tester.pumpAndSettle();

    expect(find.text('الفلاتر والترتيب'), findsOneWidget);
    expect(find.text('ترتيب النتائج'), findsOneWidget);
    expect(find.text('حالة المنتج'), findsNothing);
  });

  testWidgets('POS barcode scan adds the matching product to the cart', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(productBarcode: '123456')),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _startRegisterSession(tester);

    await tester.enterText(
      find.byKey(const ValueKey('product_lookup_field')),
      '123456',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('قهوة البيت'), findsWidgets);
    expect(find.text('تمت إضافة قهوة البيت'), findsOneWidget);
    expect(find.text('ادفع 3.50 د.ل'), findsOneWidget);
  });

  testWidgets('POS captures scanner input when lookup field is not focused', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(productBarcode: '123456')),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _startRegisterSession(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    await _scanBarcode(tester, '123456');
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('تمت إضافة قهوة البيت'), findsOneWidget);
    expect(find.text('ادفع 3.50 د.ل'), findsOneWidget);
  });

  testWidgets(
    'catalog screen exposes reusable search, filtering, and ordering controls',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        PointyApp(apiService: _mockApiService(productBarcode: '123456')),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _openNavigationDestination(tester, 'المنتجات');

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

  testWidgets('catalog barcode lookup field opens product details', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(productBarcode: '123456')),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'المنتجات');

    await tester.enterText(
      find.byKey(const ValueKey('catalog_product_lookup_field')),
      '123456',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('تفاصيل المنتج'), findsOneWidget);
    expect(find.text('قهوة البيت'), findsWidgets);
  });

  testWidgets(
    'device settings turns on the search-mode picker for the catalog',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = installMemoryKeyValueStore();
      final productLists = <Uri>[];
      const picker = ValueKey('product_search_mode_picker');

      await tester.pumpWidget(
        PointyApp(
          apiService: _mockApiService(
            onProductList: (request) => productLists.add(request.url),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _openNavigationDestination(tester, 'المنتجات');
      expect(find.byKey(picker), findsNothing);

      await _openNavigationDestination(tester, 'إعدادات الجهاز');
      final toggle = find.byKey(
        const ValueKey('product_search_mode_picker_toggle'),
      );
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(await store.getString('product_search_mode_picker'), 'true');

      await _openNavigationDestination(tester, 'المنتجات');
      expect(find.byKey(picker), findsOneWidget);

      await tester.tap(find.byKey(picker));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('product_search_mode_name')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('catalog_product_lookup_field')),
        'قهوة',
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      final searches = productLists.where(
        (uri) => uri.queryParameters['search'] == 'قهوة',
      );
      expect(searches, isNotEmpty);
      expect(searches.last.queryParameters['search_in'], 'name');
    },
  );

  testWidgets(
    'a device with the picker on offers it on the till and on purchasing',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      installMemoryKeyValueStore({'product_search_mode_picker': 'true'});
      const picker = ValueKey('product_search_mode_picker');

      await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _startRegisterSession(tester);
      expect(
        find.descendant(
          of: find.byType(PosCatalogPane),
          matching: find.byKey(picker),
        ),
        findsOneWidget,
      );

      await _openNavigationDestination(tester, 'المشتريات');
      await tester.tap(find.text('أمر شراء جديد'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(
        find.descendant(
          of: find.byType(PurchaseCatalogPane),
          matching: find.byKey(picker),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'catalog captures scanner input when lookup field is not focused',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        PointyApp(apiService: _mockApiService(productBarcode: '123456')),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _openNavigationDestination(tester, 'المنتجات');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      await _scanBarcode(tester, '123456');
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('تفاصيل المنتج'), findsOneWidget);
      expect(find.text('قهوة البيت'), findsWidgets);
    },
  );

  testWidgets('catalog details can edit parent product and variant', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(520, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, Object?>? productBody;
    Map<String, Object?>? variantBody;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onProductUpdate: (request) {
            productBody = jsonDecode(request.body) as Map<String, Object?>;
          },
          onProductVariantUpdate: (request) {
            variantBody = jsonDecode(request.body) as Map<String, Object?>;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'المنتجات');

    await tester.tap(find.byType(ProductTile).first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byTooltip('تعديل المنتج').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'قهوة مطورة');
    await tester.tap(find.text('حفظ المنتج'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(productBody?['name'], 'قهوة مطورة');
    expect(productBody?['is_active'], isTrue);

    await tester.ensureVisible(find.byTooltip('تعديل الخيار').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('تعديل الخيار').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(3), '4.25');
    await tester.tap(find.text('حفظ الخيار'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(variantBody?['product'], 1);
    expect(variantBody?['unit_price'], '4.25');
    expect(variantBody?['is_active'], isTrue);
  });

  testWidgets('catalog shows inline product details pane on wide screens', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'المنتجات');

    expect(find.text('اختر منتجًا من القائمة لعرض تفاصيله.'), findsOneWidget);

    // The catalog row is fully tappable; tapping it selects the product inline.
    await tester.tap(find.byType(ProductTile).first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // Detail renders inline: the product list stays visible, no route push.
    expect(find.text('قائمة المنتجات'), findsOneWidget);
    expect(find.byType(ProductDetailsView), findsOneWidget);
    expect(find.byType(ProductDetailsScreen), findsNothing);
    expect(find.text('اختر منتجًا من القائمة لعرض تفاصيله.'), findsNothing);
  });

  testWidgets('navigation drawer exposes primary destinations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byTooltip('فتح القائمة'));
    await tester.pumpAndSettle();

    expect(find.text('مدير النظام'), findsOneWidget);
    expect(find.text('لوحة التحكم'), findsWidgets);
    expect(find.text('شاشة البيع'), findsOneWidget);

    await _expandNavigationDrawerGroup(tester, 'المبيعات');
    expect(find.text('الفواتير'), findsOneWidget);
    expect(find.text('جلسات الدرج'), findsOneWidget);
    expect(find.text('الخصومات'), findsOneWidget);

    await _expandNavigationDrawerGroup(tester, 'المخزون والمشتريات');
    expect(find.text('المنتجات'), findsWidgets);
    expect(find.text('التصنيفات'), findsOneWidget);
    expect(find.text('المشتريات'), findsOneWidget);

    await _expandNavigationDrawerGroup(tester, 'الأشخاص والرواتب');
    expect(find.text('الجهات'), findsOneWidget);
    expect(find.text('الموظفون والرواتب'), findsOneWidget);

    await _expandNavigationDrawerGroup(tester, 'التقارير والمراجعة');
    expect(find.text('المصروفات'), findsOneWidget);
    expect(find.text('التقارير'), findsOneWidget);
    expect(find.text('سجل النشاط'), findsOneWidget);

    await _expandNavigationDrawerGroup(tester, 'الإعدادات');
    expect(find.text('إعدادات الجهاز'), findsOneWidget);
    expect(find.text('المستخدمون'), findsOneWidget);
    expect(find.text('إعدادات المتجر'), findsOneWidget);
    await tester.drag(
      find.byType(PointyNavigationSurface),
      const Offset(0, -320),
    );
    await tester.pumpAndSettle();
    expect(find.text('تسجيل الخروج'), findsOneWidget);
  });

  testWidgets('dashboard navigation returns from a pushed destination', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.byTooltip('تحديث لوحة التحكم'), findsOneWidget);

    await _openNavigationDestination(tester, 'المنتجات');

    expect(find.text('إدارة المنتجات'), findsOneWidget);
    expect(find.byTooltip('تحديث لوحة التحكم'), findsNothing);

    await _openNavigationDestination(tester, 'لوحة التحكم');

    expect(find.byTooltip('تحديث لوحة التحكم'), findsOneWidget);
    expect(find.text('إدارة المنتجات'), findsNothing);
  });

  testWidgets('contacts drawer opens customers and suppliers management', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'الجهات');

    expect(find.text('العملاء والموردون'), findsOneWidget);
    expect(find.text('العملاء'), findsOneWidget);
    expect(find.text('الموردون'), findsOneWidget);
    expect(find.text('ليلى أحمد'), findsOneWidget);
    expect(find.textContaining('+218911234567'), findsOneWidget);

    await tester.tap(find.text('الموردون'));
    await tester.pumpAndSettle();

    expect(find.text('مورد المدينة'), findsOneWidget);
    expect(find.textContaining('+21891222333'), findsOneWidget);
  });

  testWidgets('customer details shows invoices and adjustments', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'الجهات');
    await tester.tap(find.text('ليلى أحمد'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('بيانات العميل'), findsOneWidget);

    // The sales summary sits below the profile and payment-cards sections, so in
    // the test viewport it starts below the fold; scroll it into view (building
    // the lazy ListView item) before asserting its contents.
    await tester.scrollUntilVisible(
      find.text('ملخص تعاملات العميل'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('ملخص تعاملات العميل'), findsOneWidget);
    expect(find.text('إجمالي الفواتير'), findsOneWidget);
    expect(find.text('صافي المبيعات'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('الفواتير'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('الفواتير'), findsOneWidget);
    expect(find.text('إيصال R-100'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('الإرجاع والاستبدال والاسترداد'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('الإرجاع والاستبدال والاسترداد'), findsOneWidget);
    expect(find.text('إرجاع'), findsOneWidget);
    expect(find.textContaining('طلب العميل الإرجاع'), findsOneWidget);
  });

  testWidgets(
    'purchasing drawer opens searchable order list then create flow',
    (WidgetTester tester) async {
      Map<String, Object?>? purchaseBody;
      await tester.pumpWidget(
        PointyApp(
          apiService: _mockApiService(
            productBarcode: '123456',
            onPurchaseOrderCreate: (request) {
              purchaseBody = jsonDecode(request.body) as Map<String, Object?>;
            },
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _openNavigationDestination(tester, 'المشتريات');

      expect(find.text('فواتير المشتريات'), findsOneWidget);
      expect(find.text('أمر الشراء P20260515000200'), findsOneWidget);
      expect(find.textContaining('فاتورة المورد INV-4432'), findsOneWidget);
      expect(
        find.text('ابحث برقم أمر الشراء أو فاتورة المورد أو المنتج'),
        findsOneWidget,
      );
      // "مسودة" now appears both as the draft order's status pill and as the
      // draft quick-filter chip.
      expect(find.textContaining('مسودة'), findsWidgets);

      await tester.tap(find.text('أمر شراء جديد'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('أمر شراء جديد'), findsOneWidget);
      expect(find.text('كتالوج الشراء'), findsOneWidget);
      expect(find.text('مسودة الشراء'), findsOneWidget);

      await tester.tap(find.byTooltip('إعدادات مسودة الشراء'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('تغيير'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.text('مورد المدينة').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('supplier_invoice_number_field')),
        'SUP-2026-55',
      );
      await tester.enterText(
        find.byKey(const ValueKey('supplier_invoice_date_field')),
        '20260518',
      );
      expect(find.text('2026-05-18'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
      await tester.pumpAndSettle();
      expect(find.textContaining('فاتورة المورد SUP-2026-55'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('purchase_product_lookup_field')),
        '123456',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('إرسال أمر الشراء 2.75 د.ل'), findsOneWidget);

      await tester.tap(find.text('إرسال أمر الشراء 2.75 د.ل'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(purchaseBody?['supplier'], 14);
      expect(purchaseBody?['supplier_invoice_number'], 'SUP-2026-55');
      expect(purchaseBody?['supplier_invoice_date'], '2026-05-18');
    },
  );

  testWidgets(
    'purchase order creates a missing-barcode product via the full workflow',
    (WidgetTester tester) async {
      await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _openNavigationDestination(tester, 'المشتريات');
      await tester.tap(find.text('أمر شراء جديد'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.enterText(
        find.byKey(const ValueKey('purchase_product_lookup_field')),
        '987654',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // The full product-creation wizard now opens for an unknown barcode —
      // the old quick-create sheet is gone. Matched inside the wizard: the
      // catalog pane's own "new product" button carries the same words.
      expect(
        find.descendant(
          of: find.byType(ProductForm),
          matching: find.text('منتج جديد'),
        ),
        findsOneWidget,
      );
      expect(find.text('إضافة منتج سريع'), findsNothing);

      // Step 1 — parent details.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'اسم المنتج'),
        'سكر المورد',
      );
      await tester.tap(find.text('التالي'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // Step 2 — the default variant's SKU and barcode arrive prefilled with
      // the scanned code; supply the sale price and create.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'السعر'),
        '4.25',
      );
      await tester.tap(find.text('إنشاء المنتج'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      // The created product's default variant is added straight to the order.
      expect(find.text('سكر المورد'), findsWidgets);
      expect(find.text('استلام أمر الشراء فورًا'), findsOneWidget);
      expect(find.text('اختر موردًا قبل إرسال أمر الشراء.'), findsOneWidget);

      // Set a purchase cost on the freshly added line, then submit the order.
      await tester.enterText(find.widgetWithText(TextField, 'التكلفة'), '4.25');
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('إعدادات مسودة الشراء'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('تغيير'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.text('مورد المدينة').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('إرسال أمر الشراء'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(
        find.text('تم استلام أمر الشراء رقم P20260515000200.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('purchase order details show lines and status actions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'المشتريات');
    await tester.tap(find.text('أمر الشراء P20260515000200'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('P20260515000200'), findsOneWidget);
    expect(find.text('رقم فاتورة المورد'), findsOneWidget);
    expect(find.text('INV-4432'), findsOneWidget);
    expect(find.text('تاريخ فاتورة المورد'), findsOneWidget);
    expect(find.text('2026/05/18'), findsOneWidget);
    expect(find.text('إرسال'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('محتويات أمر الشراء'), 120);
    await tester.pumpAndSettle();

    expect(find.text('محتويات أمر الشراء'), findsOneWidget);
    expect(find.text('قهوة البيت'), findsOneWidget);
    expect(find.textContaining('الكمية 2'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('إرسال'), -120);
    await tester.pumpAndSettle();

    await tester.tap(find.text('إرسال'));
    await tester.pumpAndSettle();
    // Submitting a purchase order now asks for confirmation first.
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('إرسال'),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('استلام كميات'), findsOneWidget);

    await tester.tap(find.text('استلام كميات'));
    await tester.pumpAndSettle();

    expect(find.text('استلام كميات أمر الشراء'), findsOneWidget);
    expect(find.text('مستلم سليم'), findsOneWidget);
    expect(find.text('تالف عند الوصول'), findsOneWidget);
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.textContaining('مستلم'), findsWidgets);
    expect(find.text('استلام كميات'), findsNothing);

    // Corrections (return / refund / exchange) now live in the pinned footer's
    // "more actions" sheet — open it before returning items.
    await tester.tap(find.text('إجراءات أخرى'));
    await tester.pumpAndSettle();
    expect(find.text('إرجاع'), findsOneWidget);

    await tester.tap(find.text('إرجاع'));
    await tester.pumpAndSettle();
    expect(find.text('إرجاع مشتريات'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(
      find.text('تم تسجيل إرجاع المشتريات رقم P20260515000200.'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(find.text('المرتجعات والاستبدالات'), 300);
    await tester.pumpAndSettle();
    expect(find.text('المرتجعات والاستبدالات'), findsOneWidget);
    expect(find.text('إرجاع'), findsWidgets);
  });

  testWidgets('purchase order details show landed cost allocations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(purchaseOrderDetailHasLandedCosts: true),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'المشتريات');
    await tester.tap(find.text('أمر الشراء P20260515000200'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('طريقة توزيع تكاليف الوصول'), findsOneWidget);
    expect(find.text('حسب الكمية'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('محتويات أمر الشراء'), 120);
    await tester.pumpAndSettle();

    expect(find.textContaining('تكلفة وصول 1.00 د.ل'), findsOneWidget);
    expect(find.textContaining('التكلفة الفعلية 4.25 د.ل'), findsOneWidget);
    expect(find.text('8.50 د.ل'), findsWidgets);

    await tester.scrollUntilVisible(find.text('شحن'), 120);
    await tester.pumpAndSettle();

    expect(find.text('شحن'), findsOneWidget);
    expect(find.text('تخليص'), findsOneWidget);
  });

  testWidgets('purchase order details can record supplier payment', (
    WidgetTester tester,
  ) async {
    Map<String, Object?>? paymentBody;
    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onSupplierPaymentCreate: (request) {
            paymentBody = jsonDecode(request.body) as Map<String, Object?>;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'المشتريات');
    await tester.tap(find.text('أمر الشراء P20260515000200'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('غير مدفوع'), findsWidgets);
    expect(find.text('المتبقي للمورد'), findsWidgets);

    // On a draft order the next step is "submit", so recording a supplier
    // payment is reached from the footer's "more actions" sheet.
    await tester.tap(find.text('إجراءات أخرى'));
    await tester.pumpAndSettle();
    expect(find.text('تسجيل دفعة'), findsOneWidget);

    await tester.tap(find.text('تسجيل دفعة'));
    await tester.pumpAndSettle();

    expect(find.text('دفعة للمورد'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'المبلغ'), '3.50');
    await tester.enterText(
      find.widgetWithText(TextField, 'مرجع اختياري'),
      'TR-55',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'ملاحظات اختيارية'),
      'دفعة جزئية',
    );
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(paymentBody?['purchase_order'], 200);
    expect(paymentBody?['amount'], '3.50');
    expect(paymentBody?['method'], 'cash');
    expect(paymentBody?['reference'], 'TR-55');
    expect(paymentBody?['notes'], 'دفعة جزئية');
    expect(
      find.text('تم تسجيل دفعة المورد لأمر الشراء رقم P20260515000200.'),
      findsOneWidget,
    );
    expect(find.text('مدفوع جزئيًا'), findsWidgets);
  });

  testWidgets(
    'purchase order details posts partial and damaged receive lines',
    (WidgetTester tester) async {
      Map<String, Object?>? receiveBody;
      await tester.pumpWidget(
        PointyApp(
          apiService: _mockApiService(
            onPurchaseOrderReceive: (request) {
              receiveBody = jsonDecode(request.body) as Map<String, Object?>;
            },
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await _openNavigationDestination(tester, 'المشتريات');
      await tester.tap(find.text('أمر الشراء P20260515000200'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(find.text('إرسال'));
      await tester.pumpAndSettle();
      // Submitting a purchase order now asks for confirmation first.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('إرسال'),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.text('استلام كميات'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'مستلم سليم'), '1');
      await tester.enterText(
        find.widgetWithText(TextField, 'تالف عند الوصول'),
        '1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'ملاحظة الاستلام'),
        'قطعة تالفة عند الوصول',
      );
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(receiveBody?['note'], 'قطعة تالفة عند الوصول');
      expect(receiveBody?['lines'], [
        {
          'purchase_line': 1,
          'quantity_received': '1.000',
          'quantity_damaged': '1.000',
        },
      ]);
      await tester.scrollUntilVisible(find.textContaining('تالف 1'), 120);
      await tester.pumpAndSettle();
      expect(find.textContaining('تالف 1'), findsWidgets);
      await tester.scrollUntilVisible(find.text('سجل الاستلام'), 300);
      await tester.pumpAndSettle();
      expect(find.text('سجل الاستلام'), findsOneWidget);
    },
  );

  testWidgets('purchase exchange dialog posts outbound and replacement lines', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(520, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, Object?>? exchangeBody;
    final repository = PurchaseRepository(
      _mockApiService(
        onPurchaseOrderExchange: (request) {
          exchangeBody = jsonDecode(request.body) as Map<String, Object?>;
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: PurchaseOrderDetailsScreen(
          purchaseRepository: repository,
          printingRepository: PrintingRepository(_mockApiService()),
          shopSettingsRepository: ShopSettingsRepository(_mockApiService()),
          initialOrder: PurchaseOrder.fromJson(
            _purchaseOrderJson(
              status: 'received',
              submittedAt: '2026-05-15T10:00:00Z',
              receivedAt: '2026-05-15T10:10:00Z',
              receivedQuantity: 2,
              openQuantity: 0,
              canAdjust: true,
            ),
          ),
          capabilities: AuthorizationCapabilities.forUser(
            PosUser.fromJson(_userJson(role: 'manager')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('إجراءات أخرى'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('استبدال'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('العناصر الصادرة'), findsOneWidget);
    expect(find.text('العناصر البديلة'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(exchangeBody?['lines'], [
      {'line': 1, 'quantity': '1.000'},
    ]);
    expect(exchangeBody?['replacement_lines'], [
      {'variant': 1, 'quantity': '1.000', 'unit_cost': '3.75'},
    ]);
  });

  testWidgets('returns/exchange lookup finds an invoice and exchanges items', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, Object?>? exchangeBody;
    final apiService = _mockApiService(
      onSaleExchange: (request) {
        exchangeBody = jsonDecode(request.body) as Map<String, Object?>;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: _returnsLookupScreen(
          apiService,
          PosUser.fromJson(
            _userJson(
              role: 'cashier',
              permissions: const [
                'sales.add_order',
                'sales.process_return_lookup',
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Look up the invoice by its receipt number.
    await tester.enterText(find.byType(TextField).first, 'R-100');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    // The invoice's Exchange action is offered; open the dialog.
    expect(find.text('استبدال'), findsOneWidget);
    await tester.tap(find.text('استبدال'));
    await tester.pumpAndSettle();
    expect(find.text('العناصر المُرتجعة'), findsOneWidget);
    expect(find.text('العناصر البديلة'), findsOneWidget);

    // Return one of the original line.
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();

    // Search for and add a replacement product. The field searches as you type,
    // so just enter the query and let the debounce fire — no button to press.
    await tester.enterText(
      find.widgetWithText(TextField, 'ابحث عن منتج بديل'),
      'قهوة',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(exchangeBody?['lines'], [
      {'line': 1000, 'quantity': '1'},
    ]);
    expect(exchangeBody?['replacement_lines'], [
      {'variant': 1, 'quantity': '1'},
    ]);
    expect(exchangeBody?['settlement_method'], 'cash');
  });

  testWidgets('returns/exchange lookup reports an unknown receipt number', (
    WidgetTester tester,
  ) async {
    final apiService = _mockApiService();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: _returnsLookupScreen(
          apiService,
          PosUser.fromJson(
            _userJson(
              role: 'cashier',
              permissions: const ['sales.process_return_lookup'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'R-404');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('لا توجد فاتورة بهذا الرقم.'), findsOneWidget);
    // The miss also says what to do about it.
    expect(
      find.text(
        'تأكّد من رقم الفاتورة المطبوع على الإيصال، أو جرّب رقمًا آخر.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'returns/exchange lookup separates a server failure from a missing invoice',
    (WidgetTester tester) async {
      var lookups = 0;
      final apiService = _mockApiService(onSaleLookup: (_) => lookups += 1);

      await tester.pumpWidget(_returnsLookupApp(apiService));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'R-500');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(lookups, 1);
      // A 500 must never be reported as "no invoice with that number" — the
      // cashier would tell the customer their real receipt is invalid.
      expect(find.text('لا توجد فاتورة بهذا الرقم.'), findsNothing);
      expect(find.text('تعذّر البحث عن الفاتورة'), findsOneWidget);
      expect(
        find.text(
          'لم يصل ردّ من الخادم، ولا يعني ذلك أن الفاتورة غير موجودة. '
          'تحقّق من الاتصال ثم أعد المحاولة.',
        ),
        findsOneWidget,
      );

      // ...and the failure offers a way forward rather than a dead end.
      final retry = _filledButtonWithLabel('إعادة المحاولة');
      expect(retry, findsOneWidget);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(lookups, 2);
    },
  );

  testWidgets(
    'returns/exchange lookup keeps search inert until a receipt is typed',
    (WidgetTester tester) async {
      var lookups = 0;
      final apiService = _mockApiService(onSaleLookup: (_) => lookups += 1);

      await tester.pumpWidget(_returnsLookupApp(apiService));
      await tester.pumpAndSettle();

      FilledButton searchButton() =>
          tester.widget<FilledButton>(_filledButtonWithLabel('بحث'));

      expect(searchButton().onPressed, isNull);
      // Whitespace is not a receipt number either.
      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.pump();
      expect(searchButton().onPressed, isNull);

      await tester.enterText(find.byType(TextField).first, 'R-100');
      await tester.pump();
      expect(searchButton().onPressed, isNotNull);

      await tester.tap(_filledButtonWithLabel('بحث'));
      await tester.pumpAndSettle();
      expect(lookups, 1);
    },
  );

  testWidgets(
    'purchase details hide guarded workflow actions without permission',
    (WidgetTester tester) async {
      final repository = PurchaseRepository(
        _mockApiService(
          purchaseOrderDetailStatus: 'received',
          purchaseOrderDetailCanAdjust: true,
        ),
      );
      final cashier = PosUser.fromJson(
        _userJson(
          role: 'cashier',
          permissions: const ['purchasing.view_purchaseorder'],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: PurchaseOrderDetailsScreen(
            purchaseRepository: repository,
            printingRepository: PrintingRepository(_mockApiService()),
            shopSettingsRepository: ShopSettingsRepository(_mockApiService()),
            initialOrder: PurchaseOrder.fromJson(
              _purchaseOrderJson(
                status: 'received',
                submittedAt: '2026-05-15T10:00:00Z',
                receivedAt: '2026-05-15T10:10:00Z',
                receivedQuantity: 2,
                openQuantity: 0,
                canAdjust: true,
              ),
            ),
            capabilities: AuthorizationCapabilities.forUser(cashier),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('إرسال'), findsNothing);
      expect(find.text('استلام كميات'), findsNothing);
      expect(find.text('إلغاء'), findsNothing);
      expect(find.text('إرجاع'), findsNothing);
      expect(find.text('استرداد'), findsNothing);
      expect(find.text('استبدال'), findsNothing);
    },
  );

  testWidgets('purchase adjustment stock failure shows clear Arabic message', (
    WidgetTester tester,
  ) async {
    final repository = PurchaseRepository(
      _mockApiService(
        purchaseOrderDetailStatus: 'received',
        purchaseOrderDetailCanAdjust: true,
        purchaseReturnStatusCode: 409,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: PurchaseOrderDetailsScreen(
          purchaseRepository: repository,
          printingRepository: PrintingRepository(_mockApiService()),
          shopSettingsRepository: ShopSettingsRepository(_mockApiService()),
          initialOrder: PurchaseOrder.fromJson(
            _purchaseOrderJson(
              status: 'received',
              submittedAt: '2026-05-15T10:00:00Z',
              receivedAt: '2026-05-15T10:10:00Z',
              receivedQuantity: 2,
              openQuantity: 0,
              canAdjust: true,
            ),
          ),
          capabilities: AuthorizationCapabilities.forUser(
            PosUser.fromJson(_userJson(role: 'manager')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('إجراءات أخرى'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إرجاع'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'لا يمكن تعديل أمر الشراء لأن الكمية المستلمة بيعت أو لم تعد متوفرة في المخزون.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('login screen authenticates before showing dashboard', (
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

    expect(find.text('لوحة التحكم'), findsOneWidget);
    expect(find.text('نقدية الافتتاح'), findsNothing);
  });

  testWidgets('first-run onboarding creates the initial admin user', (
    WidgetTester tester,
  ) async {
    Map<String, Object?>? setupPayload;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          isAuthenticated: false,
          requiresOnboarding: true,
          onInitialAdminCreate: (request) {
            setupPayload = jsonDecode(request.body) as Map<String, Object?>;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إعداد نقطة البيع'), findsOneWidget);
    expect(find.text('تسجيل الدخول'), findsNothing);

    await tester.enterText(find.byType(TextFormField).at(0), 'owner');
    await tester.enterText(find.byType(TextFormField).at(1), 'سارة');
    await tester.enterText(find.byType(TextFormField).at(2), 'علي');
    await tester.enterText(
      find.byType(TextFormField).at(3),
      'owner@example.com',
    );
    await tester.enterText(
      find.byType(TextFormField).at(4),
      'Owner-Strong-Pass-2026!',
    );
    await tester.enterText(
      find.byType(TextFormField).at(5),
      'Owner-Strong-Pass-2026!',
    );
    await tester.tap(find.text('إنشاء المدير'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(setupPayload?['username'], 'owner');
    expect(setupPayload?['password'], 'Owner-Strong-Pass-2026!');

    // The first-run shop-setup wizard now appears right after admin creation;
    // skip it to land on the dashboard.
    expect(find.text('إعداد المتجر'), findsOneWidget);
    await tester.tap(find.text('تخطٍّ'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('لوحة التحكم'), findsOneWidget);
  });

  testWidgets('multi-user device mode forgets authenticated user on startup', (
    WidgetTester tester,
  ) async {
    installMemoryKeyValueStore({'device_usage_mode': 'multi_user'});
    var logoutRequests = 0;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onLogout: (_) {
            logoutRequests += 1;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('تسجيل الدخول'), findsOneWidget);
    expect(logoutRequests, 1);
  });

  testWidgets('login screen adapts between compact and wide layouts', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(isAuthenticated: false)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('login_compact_header')), findsOneWidget);
    expect(find.byKey(const ValueKey('login_brand_panel')), findsNothing);
    expect(find.text('دفتر'), findsOneWidget);
    expect(find.text('تسجيل الدخول'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(isAuthenticated: false)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.byKey(const ValueKey('login_brand_panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('login_compact_header')), findsNothing);
    expect(find.text('دفتر'), findsOneWidget);
    expect(find.text('تسجيل الدخول'), findsOneWidget);
  });

  testWidgets('manager can open user management', (WidgetTester tester) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'المستخدمون');

    expect(find.text('إدارة المستخدمين'), findsOneWidget);
    expect(find.text('كاشير الوردية'), findsOneWidget);
    expect(find.text('إضافة مستخدم'), findsOneWidget);
  });

  testWidgets('new user password can be revealed before it is handed over', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'المستخدمون');
    await tester.tap(find.text('إضافة مستخدم'));
    await tester.pumpAndSettle();

    final field = find.byType(PointyPasswordField);
    expect(field, findsOneWidget);
    EditableText entry() => tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );

    // The admin types this password once and then dictates it to the employee;
    // with no confirmation field, an unreadable typo locks that person out.
    expect(entry().obscureText, isTrue);
    await tester.tap(
      find.descendant(of: field, matching: find.byType(IconButton)),
    );
    await tester.pumpAndSettle();
    expect(entry().obscureText, isFalse);
  });

  testWidgets('manager can open and create discount rules', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, Object?>? discountBody;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onDiscountRuleCreate: (request) {
            discountBody = jsonDecode(request.body) as Map<String, Object?>;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'الخصومات');

    expect(find.text('إدارة الخصومات'), findsOneWidget);
    expect(find.text('خصم القهوة'), findsOneWidget);
    expect(find.text('خصم جديد'), findsOneWidget);

    await tester.tap(find.byTooltip('الفلاتر والترتيب'));
    await tester.pumpAndSettle();
    expect(find.text('الفلاتر والترتيب'), findsOneWidget);
    expect(find.text('الحالة'), findsOneWidget);
    expect(find.text('نطاق الخصم'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, -700));
    await tester.pumpAndSettle();
    expect(find.text('طريقة التطبيق'), findsOneWidget);
    await tester.tap(find.text('تطبيق'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('خصم جديد'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'اسم الخصم'),
      'خصم الافتتاح',
    );
    final formScroll = find.byKey(const ValueKey('discount_rule_form_scroll'));
    final saveButton = find.byKey(const ValueKey('discount_rule_save_button'));

    // The form is a single scroll (no wizard steps): fill fields top to
    // bottom, then save once.
    final valueField = find.widgetWithText(TextFormField, 'قيمة الخصم');
    await tester.dragUntilVisible(
      valueField,
      formScroll,
      const Offset(0, -250),
    );
    await tester.enterText(valueField, '10');
    await tester.pumpAndSettle();

    final productToggle = find.text('تطبيقه على منتجات محددة');
    await tester.dragUntilVisible(
      productToggle,
      formScroll,
      const Offset(0, -250),
    );
    await tester.tap(productToggle);
    await tester.pumpAndSettle();

    final productPicker = find.byKey(
      const ValueKey('discount_product_picker_field'),
    );
    await tester.dragUntilVisible(
      productPicker,
      formScroll,
      const Offset(0, -250),
    );
    await tester.tap(productPicker);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.enterText(
      find.byKey(const ValueKey('discount_constraint_search_field')),
      'قهوة',
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    await tester.tap(
      find.byKey(const ValueKey('discount_constraint_option_1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('discount_constraint_apply_button')),
    );
    await tester.pumpAndSettle();

    await tester.tap(saveButton);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(discountBody?['name'], 'خصم الافتتاح');
    expect(discountBody?['channel'], 'sales');
    expect(discountBody?['application_type'], 'automatic');
    expect(discountBody?['scope'], 'document');
    expect(discountBody?['value_type'], 'percentage');
    expect(discountBody?['value'], '10');
    expect(discountBody?['rounding_mode'], 'none');
    expect(discountBody?['rounding_increment'], isNull);
    expect(discountBody?['products'], [1]);
  });

  testWidgets('discount form validates on unfocus and reveals the blocker', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'الخصومات');
    await tester.tap(find.text('خصم جديد'));
    await tester.pumpAndSettle();

    final nameField = find.widgetWithText(TextFormField, 'اسم الخصم');
    final formScroll = find.byKey(const ValueKey('discount_rule_form_scroll'));
    final saveButton = find.byKey(const ValueKey('discount_rule_save_button'));

    // Leaving the required name empty flags it the moment focus moves on, so
    // the mistake is reported where the user is looking instead of being held
    // back until Save.
    expect(find.text('هذا الحقل مطلوب.'), findsNothing);
    await tester.tap(nameField);
    await tester.pumpAndSettle();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.text('هذا الحقل مطلوب.'), findsOneWidget);

    // Scroll the still-empty name off the top of the single-scroll form.
    for (var i = 0; i < 8 && tester.getTopLeft(nameField).dy >= 0; i++) {
      await tester.drag(formScroll, const Offset(0, -150));
      await tester.pumpAndSettle();
    }
    expect(tester.getTopLeft(nameField).dy, lessThan(0));

    // Saving must carry the user back to the field that blocked the save,
    // not just drop a snackbar about a step this form no longer has.
    await tester.tap(saveButton);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('أكمل الحقول المطلوبة المميزة بالأحمر.'), findsOneWidget);
    final revealed = tester.getTopLeft(nameField).dy;
    expect(revealed, greaterThanOrEqualTo(0));
    expect(revealed, lessThan(1000));
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

    await _openNavigationDestination(tester, 'إعدادات المتجر');

    expect(find.text('إعدادات المتجر'), findsWidgets);
    expect(find.text('هوية المتجر'), findsOneWidget);
    expect(find.text('الإيصالات'), findsOneWidget);
    expect(find.text('الطابعة المحلية'), findsNothing);
    expect(find.text('جلسة الدرج'), findsOneWidget);
    expect(find.text('طرق الدفع'), findsOneWidget);
    expect(find.text('المخزون والربحية'), findsOneWidget);

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

    await tester.tap(find.text('طرق الدفع'));
    await tester.pumpAndSettle();
    expect(find.text('أجهزة البطاقة الموثوقة'), findsOneWidget);
    expect(
      find.text(
        'لا توجد أجهزة محددة؛ سيتم قبول أي جهاز بطاقة عند مطابقة الإيصال.',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('trusted_card_terminal_id_field')),
      findsNothing,
    );

    // The terminal manager writes each change straight to the server — a
    // terminal is a money route another screen reads, not a preference that
    // waits for "save" — so the list here is what came back from it.
    await tester.tap(
      find.byKey(const ValueKey('manage_trusted_card_terminals_button')),
    );
    await tester.pumpAndSettle();
    expect(find.text('إدارة أجهزة البطاقة'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('trusted_card_terminal_id_field')),
      '0ja8y13w',
    );
    await tester.tap(
      find.byKey(const ValueKey('add_trusted_card_terminal_button')),
    );
    await tester.pumpAndSettle();
    expect(find.text(ltrIsolated('0JA8Y13W')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('trusted_card_terminal_id_field')),
      'abc123',
    );
    await tester.tap(
      find.byKey(const ValueKey('add_trusted_card_terminal_button')),
    );
    await tester.pumpAndSettle();
    expect(find.text(ltrIsolated('ABC123')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('remove_trusted_card_terminal_ABC123')),
    );
    await tester.pumpAndSettle();
    expect(find.text(ltrIsolated('ABC123')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('card_terminals_done_button')));
    await tester.pumpAndSettle();
    expect(find.text(ltrIsolated('0JA8Y13W')), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('هوية المتجر'));
    await tester.pumpAndSettle();
    expect(find.text('شعار المتجر'), findsOneWidget);
    expect(find.text('لم يتم رفع شعار بعد.'), findsOneWidget);
    expect(find.text('رفع شعار'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, 'متجر الاختبار');
    await tester.tap(find.text('حفظ الإعدادات'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(settingsBody?['shop_name'], 'متجر الاختبار');
    expect(settingsBody?['cashier_return_window_hours'], 42);
    expect(settingsBody?['enable_card_payments'], true);
    expect(settingsBody?['require_card_payment_receipt'], false);
    expect(settingsBody?['prevent_selling_at_loss'], true);
    expect(settingsBody?['trusted_card_terminal_ids'], ['0JA8Y13W']);
    expect(settingsBody?['card_commission_percent'], '1.00');
    expect(settingsBody?['transfer_commission_percent'], '0.00');
    expect(find.text('تم حفظ إعدادات المتجر.'), findsOneWidget);
  });

  testWidgets('manual backup saves selected destination before starting', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final backupRequests = <String>[];
    Map<String, Object?>? scheduleBody;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onBackupScheduleUpdate: (request) {
            backupRequests.add(request.method);
            scheduleBody = jsonDecode(request.body) as Map<String, Object?>;
          },
          onBackupStart: (request) {
            backupRequests.add(request.method);
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'إعدادات المتجر');
    // The backup tile sits low in the (now longer) settings list; scroll it
    // into view so the tap lands on it and opens the backup page.
    await tester.ensureVisible(find.text('النسخ والاستعادة'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('النسخ والاستعادة'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('backup_destination_field')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('PointyBackup').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('نسخ الآن'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(scheduleBody?['destination_path'], '/mnt/pointy-backup');
    expect(backupRequests, ['PATCH', 'POST']);
    expect(find.text('بدأ النسخ الاحتياطي.'), findsOneWidget);
  });

  testWidgets('manager can filter and download analytics export', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Uri? exportUri;

    // The desktop save flow moves the spooled download to the picked path, so
    // the fake dialog must return somewhere actually writable.
    final saveDirectory = Directory.systemTemp.createTempSync('pointy-export');
    addTearDown(() => saveDirectory.deleteSync(recursive: true));
    final savePicker = _FakeSaveFilePicker()
      ..returnedPath =
          '${saveDirectory.path}${Platform.pathSeparator}analytics-events.csv';
    final previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = savePicker;
    addTearDown(() => FilePickerPlatform.instance = previousPicker);

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onAnalyticsExport: (request) {
            exportUri = request.url;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'إعدادات المتجر');

    expect(find.text('تصدير التتبع'), findsOneWidget);
    // The export tile sits low in the (now longer) settings list; scroll it into
    // view so the tap lands on it and opens the export page.
    await tester.ensureVisible(find.text('تصدير التتبع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تصدير التتبع'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('analytics_export_event_type_field')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('أداء').last);
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('analytics_export_severity_field')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('تحذير').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('analytics_export_search_field')),
      'checkout',
    );
    await tester.enterText(
      find.byKey(const ValueKey('analytics_export_platform_field')),
      'flutter-web',
    );

    await tester.tap(
      find.byKey(const ValueKey('analytics_export_download_button')),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(exportUri?.path, endsWith('/analytics-events/export/'));
    expect(exportUri?.queryParameters['format'], 'csv');
    expect(exportUri?.queryParameters['event_type'], 'performance');
    expect(exportUri?.queryParameters['severity'], 'warning');
    expect(exportUri?.queryParameters['search'], 'checkout');
    expect(exportUri?.queryParameters['platform'], 'flutter-web');
    // Desktop saves by moving the spooled download to the chosen path: the
    // dialog only picks the destination (no bytes cross it), the file lands
    // there intact, and the path is surfaced to the user.
    expect(savePicker.savedFileName, 'analytics.csv');
    expect(savePicker.savedBytes, isNull);
    final savedFile = File(savePicker.returnedPath!);
    expect(savedFile.existsSync(), isTrue);
    expect(savedFile.readAsStringSync(), 'id,name\n1,frontend.operation\n');
    expect(
      find.text('حُفظ ملف التتبع في: ${savePicker.returnedPath!}'),
      findsOneWidget,
    );
  });

  testWidgets('manager sees the migrated printer, tests it and edits it', (
    WidgetTester tester,
  ) async {
    _setFakePrinterConfig();
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'إعدادات الجهاز');

    expect(find.text('إعدادات الجهاز'), findsWidgets);
    expect(find.text('استخدام الجهاز'), findsOneWidget);

    // App updates and the other device sections come first, so the printers
    // start below the fold; scroll them into view (building the lazy ListView
    // item) before reading them.
    final deviceSettingsScrollable = find
        .ancestor(
          of: find.text('استخدام الجهاز'),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('الطابعات'),
      240,
      scrollable: deviceSettingsScrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('الطابعات'), findsOneWidget);
    expect(find.text('ماذا يُطبع وأين'), findsOneWidget);
    expect(find.text('تفعيل وكيل الطباعة المحلي'), findsNothing);

    // The one printer an older build knew about is on the list, still doing
    // receipts and labels; nobody does A4 documents yet.
    final card = find.byKey(const ValueKey('printer_card_legacy-receipt'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: card, matching: find.text('محاكاة الطابعة')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('إيصالات البيع')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('ملصقات الباركود')),
      findsOneWidget,
    );
    expect(find.text('بلا طابعة — تُفتح نافذة الطباعة لتختار'), findsOneWidget);

    // It does two jobs, so its test asks which one to prove: a shop that
    // only ever printed labels on it must not be handed a receipt test.
    await tester.tap(find.byKey(const ValueKey('printer_test_legacy-receipt')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('printer_test_legacy-receipt_barcodeLabel')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('printer_test_legacy-receipt_receipt')),
    );
    await tester.pumpAndSettle();
    expect(find.text('أُرسلت الطباعة التجريبية'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('printer_menu_legacy-receipt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تعديل').last);
    // The editor looks for printers as it opens, and the platform's printer
    // list never answers under test: its spinner would never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('تعديل الطابعة'), findsOneWidget);
    expect(find.text('اختر الطابعة'), findsOneWidget);
    expect(find.text('عرض الورق بالملليمتر'), findsOneWidget);
    expect(find.text('ماذا تطبع هذه الطابعة؟'), findsOneWidget);
    final dropdownCenterY = tester
        .getCenter(find.byType(DropdownButtonFormField<String>))
        .dy;
    final discoverButtonCenterY = tester
        .getCenter(find.byTooltip('اكتشاف الطابعات'))
        .dy;
    expect((dropdownCenterY - discoverButtonCenterY).abs(), lessThan(1));

    // Nothing changed, so leaving asks nothing.
    await tester.tap(find.text('إلغاء'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('تعديل الطابعة'), findsNothing);
    expect(card, findsOneWidget);
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

    await tester.tap(find.byTooltip('فتح القائمة'));
    await tester.pumpAndSettle();

    expect(find.text('كاشير الوردية'), findsOneWidget);
    expect(find.text('شاشة البيع'), findsOneWidget);
    await _expandNavigationDrawerGroup(tester, 'المبيعات');
    expect(find.text('جلسات الدرج'), findsOneWidget);
    await _expandNavigationDrawerGroup(tester, 'الإعدادات');
    expect(find.text('إعدادات الجهاز'), findsOneWidget);
    expect(find.text('المنتجات'), findsNothing);
    expect(find.text('الخصومات'), findsNothing);
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
            navigation: FakeAppNavigation(currentUser: cashier),
            onOpenUserDetails: (_) {},
            onOpenUserPermissions: (_) async => false,
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
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'جلسات الدرج');

    expect(find.text('سجل جلسات الدرج'), findsOneWidget);
    expect(find.text('جلسة RS-1'), findsOneWidget);
    expect(find.text('جلسة RS-2'), findsOneWidget);
    expect(find.text('اختر جلسة درج لعرض مبيعاتها.'), findsOneWidget);

    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('مبيعات جلسة RS-1'), findsOneWidget);
    expect(find.text('الملخص'), findsOneWidget);
    expect(_tabText('المبيعات'), findsOneWidget);
    expect(find.text('حركات النقد'), findsOneWidget);
    await tester.tap(_tabText('الملخص'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // The manager summary spans all payment methods plus a category breakdown
    // and cash reconciliation. The top sections render immediately; the cash
    // block sits lower in the (lazy) list, so scroll it into view.
    expect(find.text('ملخص المبيعات'), findsOneWidget);
    expect(find.text('حسب طريقة الدفع'), findsOneWidget);
    final summaryScrollable = find
        .ancestor(
          of: find.text('ملخص المبيعات'),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('ملخص النقد'),
      240,
      scrollable: summaryScrollable,
    );
    expect(find.text('ملخص النقد'), findsOneWidget);
    expect(find.text('فرق -0.25 د.ل'), findsWidgets);

    await tester.tap(_tabText('المبيعات'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إيصال R-100'), findsOneWidget);
    expect(find.text('7.00 د.ل'), findsWidgets);

    await tester.tap(find.text('حركات النقد'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إضافة نقدية'), findsOneWidget);
    expect(find.textContaining('تسوية الصندوق'), findsOneWidget);
  });

  testWidgets('register session history opens compact details in a sheet', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await _openNavigationDestination(tester, 'جلسات الدرج');

    expect(find.text('جلسة RS-1'), findsOneWidget);
    expect(find.text('اختر جلسة درج لعرض مبيعاتها.'), findsNothing);

    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('مبيعات جلسة RS-1'), findsOneWidget);
    expect(find.text('الملخص'), findsOneWidget);
    expect(_tabText('المبيعات'), findsOneWidget);
    expect(find.text('حركات النقد'), findsOneWidget);

    await tester.tap(_tabText('المبيعات'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إيصال R-100'), findsOneWidget);
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

    await _openNavigationDestination(tester, 'جلسات الدرج');

    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(_tabText('المبيعات'));
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

      await _openNavigationDestination(tester, 'جلسات الدرج');
      await tester.tap(find.text('جلسة RS-1'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(_tabText('المبيعات'));
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
        {'line': 1000, 'quantity': '1'},
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

    await _openNavigationDestination(tester, 'جلسات الدرج');
    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(_tabText('المبيعات'));
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

    await _openNavigationDestination(tester, 'جلسات الدرج');
    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(_tabText('المبيعات'));
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

    await _openNavigationDestination(tester, 'جلسات الدرج');

    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(_tabText('المبيعات'));
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

    await _openPosFromDashboard(tester);
    expect(find.text('جلسة RS-1'), findsOneWidget);
    expect(find.text('نقدية الافتتاح: 12.00 د.ل'), findsOneWidget);

    await tester.tap(find.text('متابعة البيع'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('البيع الحالي'), findsOneWidget);
    // The close-session control now lives inside the labeled session-pill menu.
    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle();
    expect(find.text('إغلاق جلسة الدرج'), findsOneWidget);
  });

  testWidgets('adaptive modal bottom sheet shrinks to fit short content', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return FilledButton(
                onPressed: () {
                  showAdaptiveModalBottomSheet<void>(
                    context: context,
                    builder: (sheetContext) => const SizedBox(
                      key: ValueKey('short_sheet_content'),
                      height: 120,
                    ),
                  );
                },
                child: const Text('open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final screenHeight = tester.getSize(find.byType(Scaffold)).height;
    final sheetHeight = tester.getSize(find.byType(BottomSheet)).height;
    expect(sheetHeight, lessThan(screenHeight / 2));
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

    await tester.enterText(
      find.byKey(const ValueKey('register_session_closing_cash_field')),
      '25.50',
    );
    await tester.enterText(
      find.byKey(const ValueKey('register_session_count_025_field')),
      '1',
    );
    await tester.enterText(
      find.byKey(const ValueKey('register_session_count_050_field')),
      '2',
    );
    await tester.enterText(
      find.byKey(const ValueKey('register_session_count_075_field')),
      '3',
    );
    await tester.enterText(
      find.byKey(const ValueKey('register_session_count_100_field')),
      '4',
    );

    await tester.pump();

    // 25.50 entered + 7.50 in counted denominations.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('register_session_closing_total_tile')),
        matching: find.text('33.00 د.ل'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('register_session_close_submit_button')),
    );
    await tester.pump();

    expect(submittedInput?.closingCash, 25.50);
    expect(submittedInput?.count025, 1);
    expect(submittedInput?.count050, 2);
    expect(submittedInput?.count075, 3);
    expect(submittedInput?.count100, 4);
  });

  testWidgets('dashboard leads with hero numbers and actionable alerts', (
    WidgetTester tester,
  ) async {
    var openedCatalog = false;
    var openedIntegrityMonitor = false;
    final apiService = PosApiService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/dashboard/')) {
          return _jsonResponse(_richDashboardJson());
        }
        return http.Response('', 404);
      }),
    );
    final viewModel = DashboardViewModel(DashboardRepository(apiService));
    final user = PosUser.fromJson(
      _userJson(
        permissions: const [
          'sales.view_order',
          'inventory.view_stockitem',
          'employees.view_payrollrun',
          'fraud.view_fraudfinding',
        ],
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
        home: DashboardScreen(
          viewModel: viewModel,
          capabilities: AuthorizationCapabilities.forUser(user),
          navigation: FakeAppNavigation(
            currentUser: user,
            onNavigate: (destination) {
              if (destination == AppNavigationDestination.catalog) {
                openedCatalog = true;
              }
            },
          ),
          onOpenIntegrityMonitor: () => openedIntegrityMonitor = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('dashboard_hero_card')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('dashboard_action_center_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('dashboard_alert_out_of_stock')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('dashboard_alert_register_variance')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('dashboard_alert_pending_loans')),
      findsOneWidget,
    );

    final fraudAlert = find.byKey(
      const ValueKey('dashboard_alert_fraud_findings'),
    );
    expect(fraudAlert, findsOneWidget);
    await tester.ensureVisible(fraudAlert);
    await tester.tap(fraudAlert);
    expect(openedIntegrityMonitor, isTrue);

    final lowStockAlert = find.byKey(
      const ValueKey('dashboard_alert_low_stock'),
    );
    await tester.ensureVisible(lowStockAlert);
    await tester.tap(lowStockAlert);
    expect(openedCatalog, isTrue);
  });

  testWidgets(
    'dashboard surfaces profit-from-sales and net-profit without overflow '
    'across phone, tablet, and desktop widths',
    (WidgetTester tester) async {
      final json = _richDashboardJson();
      final sections = json['sections']! as Map<String, Object?>;
      final sales = sections['sales']! as Map<String, Object?>;
      const topProduct = {
        'product_id': 1,
        'product_name': 'قهوة مختصة',
        'sku': 'C1',
        'quantity': 30,
        'revenue': '300.00',
        'profit': '120.00',
        'variant_count': 0,
      };
      sales['top_products'] = const [topProduct];
      sales['reports'] = const {
        'products': {
          'top_sold': <Object?>[],
          'revenue': <Object?>[],
          'profit': [topProduct],
        },
        'variants': <String, Object?>{},
      };
      sections['customers'] = const {
        'summary': {
          'active_customer_count': 50,
          'new_customer_count': 8,
          'customers_with_sales_count': 30,
          'repeat_customer_count': 12,
          'marketing_consent_count': 20,
        },
        'top_customers': <Object?>[],
        'recent_customers': <Object?>[],
      };

      final apiService = PosApiService(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/dashboard/')) {
            return _jsonResponse(json);
          }
          return http.Response('', 404);
        }),
      );
      final viewModel = DashboardViewModel(DashboardRepository(apiService));
      final user = PosUser.fromJson(
        _userJson(
          permissions: const [
            'sales.view_order',
            'sales.view_registersession',
            'reports.view_reportrun',
            'payments.view_payment',
            'inventory.view_stockitem',
            'employees.view_payrollrun',
            'customers.view_customer',
            'discounts.view_discountrule',
            'fraud.view_fraudfinding',
          ],
        ),
      );

      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final width in [390.0, 768.0, 1366.0]) {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = Size(width, 1600);

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
            home: DashboardScreen(
              viewModel: viewModel,
              capabilities: AuthorizationCapabilities.forUser(user),
              navigation: FakeAppNavigation(currentUser: user),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey('dashboard_hero_card')),
          findsOneWidget,
          reason: 'hero missing at width $width',
        );
        // Profit from sales (gross profit) and net profit are both surfaced.
        expect(
          find.text('ربح المبيعات'),
          findsWidgets,
          reason: 'profit-from-sales label missing at width $width',
        );
        expect(
          find.text('صافي الربح'),
          findsWidgets,
          reason: 'net-profit label missing at width $width',
        );
        // The new profit-led product card and team/customer cards render.
        expect(find.text('أفضل المنتجات ربحًا'), findsWidgets);
        expect(
          tester.takeException(),
          isNull,
          reason: 'layout overflow at width $width',
        );
      }
    },
  );

  testWidgets('integrity monitor lists findings and records a review verdict', (
    WidgetTester tester,
  ) async {
    Map<String, Object?> findingJson({String status = 'active'}) => {
      'id': 11,
      'rule_code': 'cash_shortage',
      'status': status,
      'severity': 'critical',
      'risk_score': 88,
      'target_user_label': 'سالم الكاشير',
      'summary': {
        'rule_title': 'عجز نقدي',
        'headline': 'عجز نقدي متكرر في جلسات الدرج',
        'amount': '120.00',
      },
      'evidence': {
        'cash_shortage': [
          {
            'session_number': 'RS-9',
            'cash_variance': '-60.00',
            'occurred_at': '2026-06-11T20:00:00Z',
          },
        ],
      },
      'metrics': const <String, Object?>{},
      'peer_metrics': {'rate': '0.4', 'median': '0.05', 'threshold': '0.15'},
      'pattern_count': 2,
      'occurrence_count': 1,
      'window_start': '2026-05-13T00:00:00Z',
      'window_end': '2026-06-12T00:00:00Z',
      'last_detected_at': '2026-06-12T08:00:00Z',
      'reviewed_by_username': status == 'reviewed' ? 'manager' : '',
      'resolution_note': '',
    };

    var reviewed = false;
    final apiService = PosApiService(
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/fraud-findings/11/review/')) {
          reviewed = true;
          return _jsonResponse(findingJson(status: 'reviewed'));
        }
        if (path.endsWith('/fraud-findings/')) {
          return _jsonResponse({
            'results': [findingJson()],
            'next': null,
          });
        }
        return http.Response('', 404);
      }),
    );
    final viewModel = IntegrityMonitorViewModel(FraudRepository(apiService));
    final user = PosUser.fromJson(
      _userJson(
        permissions: const [
          'fraud.view_fraudfinding',
          'fraud.change_fraudfinding',
        ],
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
        home: IntegrityMonitorScreen(
          viewModel: viewModel,
          capabilities: AuthorizationCapabilities.forUser(user),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('integrity_status_card')), findsOneWidget);
    final card = find.byKey(const ValueKey('fraud_finding_card_11'));
    expect(card, findsOneWidget);
    expect(find.text('سالم الكاشير'), findsOneWidget);

    await tester.tap(card);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('integrity_note_field')),
      'تمت مطابقة الجلسات مع الكاميرا',
    );
    await tester.tap(find.byKey(const ValueKey('integrity_review_button')));
    await tester.pumpAndSettle();

    expect(reviewed, isTrue);
    // The finding moved out of the active list into the settled section.
    expect(viewModel.activeFindings, isEmpty);
    expect(viewModel.settledFindings, hasLength(1));
  });

  testWidgets('payroll home prepares the current month and opens the run', (
    WidgetTester tester,
  ) async {
    final draftRun = _payrollRunJson(id: 7, status: 'draft');
    final apiService = _payrollApiService(
      employees: [_employeeJson()],
      runDetails: {7: draftRun},
    );
    final viewModel = EmployeePayrollViewModel(EmployeeRepository(apiService));

    await tester.pumpWidget(_payrollApp(viewModel, apiService));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('payroll_month_workflow_card')),
      findsOneWidget,
    );
    final prepareButton = find.byKey(
      const ValueKey('payroll_prepare_month_button'),
    );
    expect(prepareButton, findsOneWidget);

    await tester.tap(prepareButton);
    await tester.pumpAndSettle();

    // Drafting the month pushes the run details screen for review.
    expect(find.byType(PayrollRunDetailsScreen), findsOneWidget);
    expect(
      find.byKey(const ValueKey('payroll_details_approve_button')),
      findsOneWidget,
    );
  });

  testWidgets('payroll run details walks approve then record payment', (
    WidgetTester tester,
  ) async {
    final draftRun = _payrollRunJson(
      id: 3,
      status: 'draft',
      lines: [
        _payrollLineJson(id: 31, employeeName: 'سالم'),
        _payrollLineJson(id: 32, employeeName: 'مريم'),
      ],
    );
    final apiService = _payrollApiService(
      employees: [_employeeJson()],
      runDetails: {3: draftRun},
    );
    final viewModel = EmployeePayrollViewModel(EmployeeRepository(apiService));
    final capabilities = AuthorizationCapabilities.forUser(
      PosUser.fromJson(_userJson(permissions: _payrollPermissions)),
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
        home: PayrollRunDetailsScreen(
          viewModel: viewModel,
          attendanceViewModel: AttendanceViewModel(
            AttendanceRepository(apiService),
          ),
          capabilities: capabilities,
          initialRun: PayrollRun.fromJson(draftRun),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('سالم'), findsOneWidget);
    expect(find.text('مريم'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('payroll_details_approve_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('payroll_confirm_dialog_button')),
    );
    await tester.pumpAndSettle();

    // Approved: the footer now offers the payment step.
    final markPaidButton = find.byKey(
      const ValueKey('payroll_details_mark_paid_button'),
    );
    expect(markPaidButton, findsOneWidget);

    await tester.tap(markPaidButton);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('payroll_confirm_dialog_button')),
    );
    await tester.pumpAndSettle();

    // Paid: no further action is offered.
    expect(markPaidButton, findsNothing);
    expect(
      find.byKey(const ValueKey('payroll_details_approve_button')),
      findsNothing,
    );
  });

  testWidgets('payroll run details applies BioTime attendance to a draft', (
    WidgetTester tester,
  ) async {
    final draftRun = _payrollRunJson(
      id: 5,
      status: 'draft',
      lines: [_payrollLineJson(id: 51, employeeName: 'سالم')],
    );
    final apiService = _payrollApiService(
      employees: [_employeeJson()],
      runDetails: {5: draftRun},
      bioTimeEnabled: true,
    );
    final viewModel = EmployeePayrollViewModel(EmployeeRepository(apiService));
    final capabilities = AuthorizationCapabilities.forUser(
      PosUser.fromJson(
        _userJson(
          permissions: [
            ..._payrollPermissions,
            'attendance.view_attendanceday',
            'attendance.change_biotimeconnection',
          ],
        ),
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
        home: PayrollRunDetailsScreen(
          viewModel: viewModel,
          attendanceViewModel: AttendanceViewModel(
            AttendanceRepository(apiService),
          ),
          capabilities: capabilities,
          initialRun: PayrollRun.fromJson(draftRun),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final applyButton = find.byKey(
      const ValueKey('payroll_details_apply_attendance_button'),
    );
    expect(applyButton, findsOneWidget);

    await tester.tap(applyButton);
    await tester.pumpAndSettle();

    // Net total falls after the BioTime absence deduction is applied.
    expect(find.textContaining('450'), findsWidgets);
  });

  testWidgets(
    'payroll run details hides the BioTime card when not configured',
    (WidgetTester tester) async {
      final draftRun = _payrollRunJson(
        id: 6,
        status: 'draft',
        lines: [_payrollLineJson(id: 61, employeeName: 'سالم')],
      );
      final apiService = _payrollApiService(
        employees: [_employeeJson()],
        runDetails: {6: draftRun},
        // BioTime not configured for this shop.
      );
      final viewModel = EmployeePayrollViewModel(
        EmployeeRepository(apiService),
      );
      final capabilities = AuthorizationCapabilities.forUser(
        PosUser.fromJson(
          _userJson(
            permissions: [
              ..._payrollPermissions,
              'attendance.view_attendanceday',
              'attendance.change_biotimeconnection',
            ],
          ),
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
          home: PayrollRunDetailsScreen(
            viewModel: viewModel,
            attendanceViewModel: AttendanceViewModel(
              AttendanceRepository(apiService),
            ),
            capabilities: capabilities,
            initialRun: PayrollRun.fromJson(draftRun),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Permission alone is not enough: without BioTime the card stays hidden.
      expect(
        find.byKey(const ValueKey('payroll_details_apply_attendance_button')),
        findsNothing,
      );
    },
  );

  testWidgets('payroll home surfaces pending loan requests for review', (
    WidgetTester tester,
  ) async {
    final apiService = _payrollApiService(
      employees: [_employeeJson()],
      payrollRuns: [_payrollRunJson(id: 9, status: 'paid')],
      runDetails: {9: _payrollRunJson(id: 9, status: 'paid')},
      loans: [
        {
          'id': 4,
          'employee': 1,
          'employee_name': 'سالم',
          'employee_number': 'E1',
          'status': 'requested',
          'amount': '300.00',
          'monthly_deduction': '50.00',
          'outstanding_balance': '0.00',
          'deducted_amount': '0.00',
          'purpose': '',
        },
      ],
    );
    final viewModel = EmployeePayrollViewModel(EmployeeRepository(apiService));

    await tester.pumpWidget(_payrollApp(viewModel, apiService));
    await tester.pumpAndSettle();

    final loansCard = find.byKey(const ValueKey('payroll_pending_loans_card'));
    expect(loansCard, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pending_loan_approve_4')));
    await tester.pumpAndSettle();

    // Approving a loan is one-way, so the card asks before committing.
    expect(find.text('الموافقة على السلفة؟'), findsOneWidget);
    expect(loansCard, findsOneWidget);

    await tester.tap(find.text('موافقة').last);
    await tester.pumpAndSettle();

    // Approved request leaves the attention card with nothing to show.
    expect(loansCard, findsNothing);
  });

  testWidgets('product details screen presents product information', (
    WidgetTester tester,
  ) async {
    final product = const Product(
      id: 42,
      name: 'قهوة عربية',
      quantityOnHand: 8,
      description: 'حبوب مطحونة بعناية',
      defaultVariant: ProductVariant(
        id: 42,
        productId: 42,
        sku: 'COF-100',
        unitPrice: 5.50,
        barcode: '123456',
      ),
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
        home: ProductVariantDetailsScreen(
          viewModel: ProductStockViewModel(
            InventoryRepository(apiService),
            PurchaseRepository(apiService),
            product,
          ),
          printingRepository: PrintingRepository(apiService),
          capabilities: AuthorizationCapabilities.forUser(
            PosUser.fromJson(_userJson()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('تفاصيل الخيار'), findsOneWidget);
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

  testWidgets('product details barcode labels ask for copy count', (
    WidgetTester tester,
  ) async {
    // The device's one printer, from before printers had jobs: it keeps the
    // label job it always had.
    _setFakePrinterConfig();
    final product = const Product(
      id: 42,
      name: 'قهوة عربية',
      quantityOnHand: 8,
      description: 'حبوب مطحونة بعناية',
      defaultVariant: ProductVariant(
        id: 42,
        productId: 42,
        sku: 'COF-100',
        unitPrice: 5.50,
        barcode: '123456789012',
      ),
    );
    final apiService = _mockApiService();
    final transport = _CapturingPrintTransport();

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
        home: ProductVariantDetailsScreen(
          viewModel: ProductStockViewModel(
            InventoryRepository(apiService),
            PurchaseRepository(apiService),
            product,
          ),
          printingRepository: PrintingRepository(
            apiService,
            serialTransport: transport,
            bluetoothTransport: transport,
            wifiTransport: transport,
            fakeTransport: transport,
          ),
          capabilities: AuthorizationCapabilities.forUser(
            PosUser.fromJson(_userJson()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    await tester.tap(find.text('طباعة ملصقات'));
    await tester.pumpAndSettle();

    expect(find.text('طباعة ملصقات الباركود'), findsOneWidget);
    expect(find.text('عدد النسخ'), findsOneWidget);
    expect(find.text('طباعة السعر'), findsOneWidget);
    expect(find.text('طباعة تاريخ الانتهاء'), findsOneWidget);
    expect(find.text('معاينة الملصق'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).last, '3');
    await tester.tap(find.text('طباعة').last);
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.text('تم إرسال 3 ملصقات باركود للطابعة.'), findsOneWidget);
    final text = utf8.decode(transport.printedBytes);
    expect(text, contains('^XA'));
    expect(text, contains('^PQ3'));
    expect(text, contains('123456789012'));
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

    await _openNavigationDestination(tester, 'المنتجات');

    await tester.tap(find.byType(ProductTile).first);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('الخيارات'), findsWidgets);
    await tester.ensureVisible(find.text('COF-001').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('COF-001').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('المتاح'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);

    await tester.tap(find.text('حركة مخزون جديدة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '5');
    await tester.enterText(find.byType(TextFormField).last, 'جرد الرف');
    await tester.tap(find.text('حفظ الحركة'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(movementBody?['variant'], 1);
    expect(movementBody?['movement_type'], 'increase');
    expect(movementBody?['quantity'], '5');
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

  testWidgets('product image search loads additional pages while scrolling', (
    WidgetTester tester,
  ) async {
    final requestedPages = <int>[];
    final repository = CatalogRepository(
      PosApiService(
        baseUrl: 'http://pointy.test/api',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/products/image-search/')) {
            final page = int.parse(request.url.queryParameters['page'] ?? '1');
            requestedPages.add(page);
            expect(request.url.queryParameters['page_size'], '30');
            final results = page == 1
                ? List.generate(
                    30,
                    (index) => {
                      'title': 'قهوة ${index + 1}',
                      'thumbnail_url':
                          'https://images.example.com/thumb-$index.jpg',
                      'source_url': 'https://shop.example.com/coffee-$index',
                      'source_name': 'متجر الصور',
                      'provider': 'serper',
                      'import_token': 'token-$index',
                    },
                  )
                : const [];
            return http.Response(
              jsonEncode({'results': results}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 404);
        }),
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
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 520,
            child: ProductImageSearchSheet(
              catalogRepository: repository,
              initialQuery: 'قهوة',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(requestedPages, [1]);
    expect(find.text('عرض المزيد'), findsNothing);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
    await tester.pump();
    await tester.pump();

    expect(requestedPages, [1, 2]);
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
  await _openPosFromDashboard(tester);
  await tester.enterText(find.byType(TextField), '12.00');
  await tester.tap(find.text('بدء الجلسة'));
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

Finder _tabText(String label) {
  return find.descendant(of: find.byType(TabBar), matching: find.text(label));
}

Future<void> _expandNavigationDrawerGroup(
  WidgetTester tester,
  String label,
) async {
  final drawer = find.byType(PointyNavigationSurface);
  final group = find.descendant(of: drawer, matching: find.text(label));
  if (group.evaluate().isEmpty) {
    // The drawer scrolls; a group lower than the viewport is not yet built.
    await tester.scrollUntilVisible(
      group,
      150,
      scrollable: find
          .descendant(of: drawer, matching: find.byType(Scrollable))
          .first,
    );
    await tester.pumpAndSettle();
  }
  expect(group, findsWidgets);
  await tester.ensureVisible(group.first);
  await tester.pumpAndSettle();
  await tester.tap(group.first);
  await tester.pumpAndSettle();
}

Future<void> _openNavigationDestination(
  WidgetTester tester,
  String label,
) async {
  Finder railSurface() {
    return find.byType(PointyNavigationRailSurface);
  }

  Finder railDestination() {
    return find.descendant(of: railSurface(), matching: find.text(label));
  }

  Finder collapsedRailDestination() {
    return find.descendant(of: railSurface(), matching: find.byTooltip(label));
  }

  Finder drawerDestination() {
    return find.descendant(
      of: find.byType(PointyNavigationSurface),
      matching: find.text(label),
    );
  }

  Future<void> tapDestination(Finder destination) async {
    await tester.ensureVisible(destination.first);
    await tester.pumpAndSettle();
    await tester.tap(destination.first);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  Future<void> expandVisibleGroups(
    Finder scope,
    Finder Function() destination,
  ) async {
    const groupLabels = [
      'الرئيسية',
      'المبيعات',
      'المخزون والمشتريات',
      'الأشخاص والرواتب',
      'التقارير والمراجعة',
      'الإعدادات',
    ];
    for (final groupLabel in groupLabels) {
      if (tester.any(destination())) {
        return;
      }
      final group = find.descendant(of: scope, matching: find.text(groupLabel));
      if (!tester.any(group)) {
        continue;
      }
      await tester.ensureVisible(group);
      await tester.pumpAndSettle();
      if (tester.any(destination())) {
        return;
      }
      await tester.tap(group);
      await tester.pumpAndSettle();
    }
  }

  Future<Finder> revealRailDestination() async {
    var destination = railDestination();
    if (tester.any(destination)) {
      return destination;
    }
    final tooltipDestination = collapsedRailDestination();
    if (tester.any(tooltipDestination)) {
      return tooltipDestination;
    }
    if (!tester.any(railSurface())) {
      return destination;
    }

    // The rail remembers its scroll offset across pages, so it may open
    // mid-list; reset to the top before sweeping downward.
    await tester.drag(railSurface(), const Offset(0, 2400));
    await tester.pumpAndSettle();
    await expandVisibleGroups(railSurface(), railDestination);
    destination = railDestination();
    for (
      var attempts = 0;
      attempts < 6 && !tester.any(destination);
      attempts++
    ) {
      await tester.drag(railSurface(), const Offset(0, -240));
      await tester.pumpAndSettle();
      await expandVisibleGroups(railSurface(), railDestination);
      destination = railDestination();
    }
    if (tester.any(destination)) {
      return destination;
    }
    return collapsedRailDestination();
  }

  Future<Finder> revealDrawerDestination() async {
    var destination = drawerDestination();
    if (!tester.any(destination) &&
        tester.any(find.byType(PointyNavigationSurface))) {
      // The drawer remembers its scroll offset across pages, so it may open
      // mid-list; reset to the top before sweeping downward.
      await tester.drag(
        find.byType(PointyNavigationSurface),
        const Offset(0, 2400),
      );
      await tester.pumpAndSettle();
      destination = drawerDestination();
    }
    for (
      var attempts = 0;
      attempts < 8 && !tester.any(destination);
      attempts++
    ) {
      await expandVisibleGroups(
        find.byType(PointyNavigationSurface),
        drawerDestination,
      );
      destination = drawerDestination();
      if (tester.any(destination)) {
        return destination;
      }
      await tester.drag(
        find.byType(PointyNavigationSurface),
        const Offset(0, -240),
      );
      await tester.pumpAndSettle();
      destination = drawerDestination();
    }
    return destination;
  }

  final visibleRailDestination = await revealRailDestination();
  if (tester.any(visibleRailDestination)) {
    await tapDestination(visibleRailDestination);
    return;
  }

  var visibleDrawerDestination = drawerDestination();
  if (tester.any(visibleDrawerDestination)) {
    await tapDestination(visibleDrawerDestination);
    return;
  }

  final openDrawerButton = find.byTooltip('فتح القائمة');
  if (tester.any(openDrawerButton)) {
    await tester.tap(openDrawerButton);
    await tester.pumpAndSettle();
    visibleDrawerDestination = await revealDrawerDestination();
    expect(visibleDrawerDestination, findsWidgets);
    await tapDestination(visibleDrawerDestination);
    return;
  }

  final expandRailButton = find.byTooltip('توسيع التنقل');
  if (tester.any(expandRailButton)) {
    await tester.tap(expandRailButton);
    await tester.pumpAndSettle();
    final expandedRailDestination = await revealRailDestination();
    expect(expandedRailDestination, findsWidgets);
    await tapDestination(expandedRailDestination);
    return;
  }

  fail('Could not find navigation control for "$label".');
}

Future<void> _openPosFromDashboard(WidgetTester tester) async {
  if (find.text('نقطة البيع').evaluate().isNotEmpty ||
      find.text('البيع الحالي').evaluate().isNotEmpty) {
    return;
  }
  await _openNavigationDestination(tester, 'شاشة البيع');
}

Future<void> _confirmPayment(WidgetTester tester) async {
  expect(find.text('إتمام الدفع'), findsOneWidget);
  await tester.tap(find.text('تأكيد الدفع'));
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

Future<void> _scanBarcode(WidgetTester tester, String barcode) async {
  for (final character in barcode.characters) {
    await tester.sendKeyEvent(_logicalKeyForCharacter(character));
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
}

LogicalKeyboardKey _logicalKeyForCharacter(String character) {
  return switch (character) {
    '0' => LogicalKeyboardKey.digit0,
    '1' => LogicalKeyboardKey.digit1,
    '2' => LogicalKeyboardKey.digit2,
    '3' => LogicalKeyboardKey.digit3,
    '4' => LogicalKeyboardKey.digit4,
    '5' => LogicalKeyboardKey.digit5,
    '6' => LogicalKeyboardKey.digit6,
    '7' => LogicalKeyboardKey.digit7,
    '8' => LogicalKeyboardKey.digit8,
    '9' => LogicalKeyboardKey.digit9,
    _ => throw ArgumentError.value(character, 'character'),
  };
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

class _StatusPrintTransport extends PrintTransport {
  const _StatusPrintTransport({required this.isAvailable});

  final bool isAvailable;

  @override
  Future<List<PrinterEndpoint>> discover() async => const [];

  @override
  Future<PrintTransportStatus> status(PrinterEndpoint endpoint) async {
    return PrintTransportStatus(
      isAvailable: isAvailable,
      message: isAvailable ? 'ready' : 'offline',
    );
  }

  @override
  Future<PrintTransportResult> printJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async {
    return isAvailable
        ? const PrintTransportResult.success('printed')
        : const PrintTransportResult.failure('offline');
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    return isAvailable
        ? const PrintTransportResult.success('printed')
        : const PrintTransportResult.failure('offline');
  }
}

class _CapturingPrintTransport extends PrintTransport {
  _CapturingPrintTransport({this.probeResponse});

  final PrintTransportResponse? probeResponse;
  List<int> printedBytes = const [];

  @override
  Future<List<PrinterEndpoint>> discover() async => const [];

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
  Future<PrintTransportResult> printBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
  }) async {
    printedBytes = List<int>.of(bytes);
    return const PrintTransportResult.success('printed bytes');
  }

  @override
  Future<PrintTransportResponse> sendAndReceiveBytes({
    required List<int> bytes,
    required PrinterEndpoint endpoint,
    Duration? readTimeout,
  }) async {
    return probeResponse ??
        const PrintTransportResponse.failure('no probe response');
  }

  @override
  Future<PrintTransportResult> printTest(PrinterEndpoint endpoint) async {
    return const PrintTransportResult.success('printed');
  }
}

Widget _localizedTestApp(Widget child) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(body: child),
  );
}

/// `FilledButton.icon` builds a private subclass, so `find.byType(FilledButton)`
/// (which matches the runtime type exactly) misses it — match the supertype.
Finder _filledButtonWithLabel(String label) {
  return find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((widget) => widget is FilledButton),
  );
}

/// Hosts [ReturnsExchangeLookupScreen] as a returns-desk cashier: the lookup
/// permission, but no checkout rights.
Widget _returnsLookupApp(PosApiService apiService) {
  return MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: _returnsLookupScreen(
      apiService,
      PosUser.fromJson(
        _userJson(
          role: 'cashier',
          permissions: const ['sales.process_return_lookup'],
        ),
      ),
    ),
  );
}

ReturnsExchangeLookupScreen _returnsLookupScreen(
  PosApiService apiService,
  PosUser user,
) {
  return ReturnsExchangeLookupScreen(
    saleRepository: SaleRepository(apiService),
    printingRepository: PrintingRepository(apiService),
    shopSettingsRepository: ShopSettingsRepository(apiService),
    catalogRepository: CatalogRepository(apiService),
    capabilities: AuthorizationCapabilities.forUser(user),
    navigation: FakeAppNavigation(currentUser: user),
  );
}

PosApiService _mockApiService({
  bool isAuthenticated = true,
  bool hasOpenSession = false,
  int checkoutStatusCode = 200,
  bool checkoutNoOpenSession = false,
  int purchaseReturnStatusCode = 200,
  String purchaseOrderDetailStatus = 'draft',
  bool purchaseOrderDetailCanAdjust = true,
  bool purchaseOrderDetailHasLandedCosts = false,
  String currentUserRole = 'manager',
  String currentUserDisplayName = 'مدير النظام',
  List<String> currentUserPermissions = const [],
  bool requiresOnboarding = false,
  void Function(http.Request request)? onInitialAdminCreate,
  void Function(http.Request request)? onCheckout,
  void Function(http.Request request)? onLogout,
  void Function(http.Request request)? onPurchaseOrderCreate,
  void Function(http.Request request)? onPurchaseOrderReceive,
  void Function(http.Request request)? onPurchaseOrderExchange,
  void Function(http.Request request)? onSupplierPaymentCreate,
  void Function(http.Request request)? onCashMovement,
  void Function(http.Request request)? onReprint,
  void Function(http.Request request)? onReturn,
  void Function(http.Request request)? onSaleLookup,
  void Function(http.Request request)? onSaleExchange,
  void Function(http.Request request)? onVoid,
  void Function(http.Request request)? onPrintJobReport,
  void Function(http.Request request)? onPrintJobRequeue,
  void Function(http.Request request)? onPrintAuditRecord,
  void Function(http.Request request)? onPrintAuditReport,
  void Function(http.Request request)? onStockMovement,
  void Function(int page)? onOrderPage,
  void Function(http.Request request)? onShopSettingsUpdate,
  void Function(http.Request request)? onAnalyticsExport,
  void Function(http.Request request)? onDiscountRuleCreate,
  void Function(http.Request request)? onProductCategoryRequest,
  void Function(http.Request request)? onProductList,
  void Function(http.Request request)? onProductUpdate,
  void Function(http.Request request)? onProductVariantUpdate,
  void Function(http.Request request)? onBackupScheduleUpdate,
  void Function(http.Request request)? onBackupStart,
  bool shopSettingsAutoPrint = false,
  bool shopSettingsRequireOpeningCash = true,
  bool shopSettingsAllowOverselling = false,
  bool shopSettingsPreventSellingAtLoss = true,
  bool shopSettingsRequireCardReceipt = false,
  List<String> shopSettingsTrustedCardTerminalIds = const [],
  String backupDestinationPath = '',
  bool backupScheduleEnabled = false,
  String backupScheduledTime = '02:00:00',
  bool saleDiscountPreviewHasLoss = false,
  int shopSettingsCashierReturnWindowHours = 42,
  int productQuantityOnHand = 12,
  bool productIsPrepared = false,
  String productBarcode = '',
  String registerHistorySessionStatus = 'closed',
  bool orderCanVoid = true,
  bool orderCanReturn = true,
  bool orderRequiresManagerAdjustment = false,
}) {
  var authenticated = isAuthenticated;
  var onboardingRequired = requiresOnboarding;
  var currentSessionIsOpen = hasOpenSession;
  var supplierPaidTotal = 0.0;
  var configuredBackupDestinationPath = backupDestinationPath;
  var configuredBackupScheduleEnabled = backupScheduleEnabled;
  var configuredBackupScheduledTime = backupScheduledTime;
  // The registry the card-terminal routes below add to, update and delete —
  // seeded from the shop settings so a test that starts with trusted terminals
  // sees them in the manager too.
  final cardTerminals = <Map<String, Object?>>[
    for (final (index, terminalId)
        in shopSettingsTrustedCardTerminalIds.indexed)
      {
        'id': index + 1,
        'terminal_id': terminalId,
        'label': '',
        'money_account': null,
        'is_active': true,
        'display_order': index,
      },
  ];

  return PosApiService(
    client: MockClient((request) async {
      final path = request.url.path;

      if (path.endsWith('/setup/status/')) {
        return _jsonResponse({
          'requires_onboarding': onboardingRequired && !authenticated,
        });
      }

      if (path.endsWith('/setup/admin/')) {
        onInitialAdminCreate?.call(request);
        if (!onboardingRequired) {
          return _jsonResponse({'detail': 'Setup completed.'}, statusCode: 409);
        }
        final body = jsonDecode(request.body) as Map<String, Object?>;
        authenticated = true;
        onboardingRequired = false;
        return _jsonResponse(
          _userJson(
            username: body['username']?.toString() ?? 'admin',
            displayName: body['first_name']?.toString() ?? 'مدير النظام',
            role: 'manager',
            permissions: currentUserPermissions,
          ),
          statusCode: 201,
        );
      }

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
        onLogout?.call(request);
        authenticated = false;
        return http.Response('', 204);
      }

      if (path.endsWith('/dashboard/')) {
        return _jsonResponse(_dashboardJson());
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
              preventSellingAtLoss: shopSettingsPreventSellingAtLoss,
              requireCardPaymentReceipt: shopSettingsRequireCardReceipt,
              trustedCardTerminalIds: shopSettingsTrustedCardTerminalIds,
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
            preventSellingAtLoss: shopSettingsPreventSellingAtLoss,
            requireCardPaymentReceipt: shopSettingsRequireCardReceipt,
            trustedCardTerminalIds: shopSettingsTrustedCardTerminalIds,
            cashierReturnWindowHours: shopSettingsCashierReturnWindowHours,
          ),
        );
      }

      if (path.endsWith('/shop-settings/logo/')) {
        if (request.method == 'DELETE') {
          return _jsonResponse(
            _shopSettingsJson(
              autoPrintReceipts: shopSettingsAutoPrint,
              requireOpeningCash: shopSettingsRequireOpeningCash,
              allowOverselling: shopSettingsAllowOverselling,
              preventSellingAtLoss: shopSettingsPreventSellingAtLoss,
              requireCardPaymentReceipt: shopSettingsRequireCardReceipt,
              trustedCardTerminalIds: shopSettingsTrustedCardTerminalIds,
              cashierReturnWindowHours: shopSettingsCashierReturnWindowHours,
            ),
          );
        }
        return _jsonResponse(
          _shopSettingsJson(
            autoPrintReceipts: shopSettingsAutoPrint,
            requireOpeningCash: shopSettingsRequireOpeningCash,
            allowOverselling: shopSettingsAllowOverselling,
            preventSellingAtLoss: shopSettingsPreventSellingAtLoss,
            requireCardPaymentReceipt: shopSettingsRequireCardReceipt,
            trustedCardTerminalIds: shopSettingsTrustedCardTerminalIds,
            cashierReturnWindowHours: shopSettingsCashierReturnWindowHours,
            logoAttachment: const {
              'id': 10,
              'original_filename': 'logo.png',
              'content_type': 'image/png',
              'content_url':
                  'http://127.0.0.1:8000/api/attachments/10/content/',
              'download_url':
                  'http://127.0.0.1:8000/api/attachments/10/download/',
              'is_primary': true,
            },
          ),
        );
      }

      if (path.endsWith('/backup/destinations/')) {
        return _jsonResponse({
          'destinations': [
            {
              'label': 'PointyBackup',
              'path': '/mnt/pointy-backup',
              'backup_path': '/mnt/pointy-backup/pointy-backups',
              'is_available': true,
              'is_writable': true,
              'total_bytes': 10737418240,
              'free_bytes': 8589934592,
            },
          ],
        });
      }

      if (path.endsWith('/backup/')) {
        if (request.method == 'PATCH') {
          onBackupScheduleUpdate?.call(request);
          final body = jsonDecode(request.body) as Map<String, Object?>;
          configuredBackupScheduleEnabled = body['enabled'] == true;
          configuredBackupDestinationPath =
              body['destination_path']?.toString() ?? '';
          configuredBackupScheduledTime =
              body['scheduled_time']?.toString() ??
              configuredBackupScheduledTime;
          return _jsonResponse(
            _backupOperationsJson(
              enabled: configuredBackupScheduleEnabled,
              destinationPath: configuredBackupDestinationPath,
              scheduledTime: configuredBackupScheduledTime,
            ),
          );
        }
        if (request.method == 'POST') {
          onBackupStart?.call(request);
          if (configuredBackupDestinationPath.isEmpty) {
            return http.Response.bytes(
              utf8.encode(
                jsonEncode({'detail': 'Backup destination is required.'}),
              ),
              400,
              headers: const {
                'Content-Type': 'application/json; charset=utf-8',
              },
            );
          }
          return _jsonResponse(_backupJobJson());
        }
        return _jsonResponse(
          _backupOperationsJson(
            enabled: configuredBackupScheduleEnabled,
            destinationPath: configuredBackupDestinationPath,
            scheduledTime: configuredBackupScheduledTime,
          ),
        );
      }

      if (path.endsWith('/analytics-events/export/')) {
        onAnalyticsExport?.call(request);
        return http.Response.bytes(
          utf8.encode('id,name\n1,frontend.operation\n'),
          200,
          headers: {
            'content-type': 'text/csv; charset=utf-8',
            'content-disposition': 'attachment; filename="analytics.csv"',
          },
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

      if (path.endsWith('/register-sessions/1/summary/')) {
        return _jsonResponse(_sessionSummaryJson());
      }

      if (path.endsWith('/register-sessions/1/orders/')) {
        // Cursor-paginated (see CreatedAtCursorPagination): page 1 has no
        // cursor, the next page echoes the cursor page 1 handed out.
        final cursor = request.url.queryParameters['cursor'];
        final page = cursor == null ? 1 : 2;
        onOrderPage?.call(page);
        if (page == 2) {
          return _jsonResponse({
            'next': null,
            'previous':
                'http://localhost/api/register-sessions/1/orders/?cursor=p1',
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
          'next': 'http://localhost/api/register-sessions/1/orders/?cursor=p2',
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
        final page = request.url.queryParameters['cursor'] == null ? 1 : 2;
        if (page == 2) {
          return _jsonResponse({
            'next': null,
            'previous': 'http://localhost/api/register-sessions/?cursor=p1',
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
          'next': 'http://localhost/api/register-sessions/?cursor=p2',
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
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          final defaultVariant =
              body['default_variant'] as Map<String, Object?>? ??
              const <String, Object?>{};
          return _jsonResponse({
            'id': 9,
            'quantity_on_hand': 0,
            'description': '',
            'is_active': true,
            ...body,
            'default_variant': {
              'id': 9,
              'product': 9,
              'product_name': body['name'] ?? '',
              'display_name': body['name'] ?? '',
              'full_name': body['name'] ?? '',
              'quantity_on_hand': 0,
              ...defaultVariant,
            },
          });
        }
        onProductList?.call(request);
        return _jsonResponse(
          _productPageJson(
            quantityOnHand: productQuantityOnHand,
            barcode: productBarcode,
            isPrepared: productIsPrepared,
          ),
        );
      }

      if (path.endsWith('/products/1/')) {
        if (request.method == 'PATCH') {
          onProductUpdate?.call(request);
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({
            ..._productJson(
              quantityOnHand: productQuantityOnHand,
              barcode: productBarcode,
            ),
            ...body,
            'category_details': const [],
          });
        }
        return _jsonResponse(
          _productJson(
            quantityOnHand: productQuantityOnHand,
            barcode: productBarcode,
          ),
        );
      }

      if (path.endsWith('/products/1/variants/')) {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({
            ..._productVariantJson(
              id: 2,
              quantityOnHand: 0,
              barcode: body['barcode']?.toString() ?? '',
            ),
            ...body,
            'id': 2,
            'product': 1,
            'product_name': 'قهوة البيت',
            'quantity_on_hand': 0,
          });
        }
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [
            _productVariantJson(
              quantityOnHand: productQuantityOnHand,
              barcode: productBarcode,
            ),
          ],
        });
      }

      if (path.endsWith('/product-variants/')) {
        final requestedBarcode = request.url.queryParameters['barcode'];
        if (requestedBarcode != null && requestedBarcode != productBarcode) {
          return _jsonResponse({'next': null, 'results': []});
        }
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [
            _productVariantJson(
              quantityOnHand: productQuantityOnHand,
              barcode: productBarcode,
            ),
          ],
        });
      }

      if (path.endsWith('/product-variants/1/')) {
        if (request.method == 'PATCH') {
          onProductVariantUpdate?.call(request);
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({
            ..._productVariantJson(
              quantityOnHand: productQuantityOnHand,
              barcode: productBarcode,
            ),
            ...body,
          });
        }
        return _jsonResponse(
          _productVariantJson(
            quantityOnHand: productQuantityOnHand,
            barcode: productBarcode,
          ),
        );
      }

      if (path.endsWith('/product-categories/')) {
        onProductCategoryRequest?.call(request);
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({..._productCategoryJson(id: 9), ...body});
        }

        // The POS/purchasing quick-access strip and the category screen both
        // request pinned categories; no fixture pins any, so return none.
        if (request.url.queryParameters['is_quick_access'] == 'true') {
          return _jsonResponse({
            'count': 0,
            'next': null,
            'previous': null,
            'results': <Object?>[],
          });
        }

        final page =
            int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
        final parent = request.url.queryParameters['parent'];

        if (parent == '1') {
          if (page == 2) {
            return _jsonResponse({
              'count': 2,
              'next': null,
              'previous':
                  'http://localhost/api/product-categories/?parent=1&page=1',
              'results': [
                _productCategoryJson(
                  id: 4,
                  name: 'شاي',
                  parent: 1,
                  parentName: 'مشروبات',
                ),
              ],
            });
          }
          return _jsonResponse({
            'count': 2,
            'next': 'http://localhost/api/product-categories/?parent=1&page=2',
            'previous': null,
            'results': [
              _productCategoryJson(
                id: 2,
                name: 'قهوة',
                parent: 1,
                parentName: 'مشروبات',
              ),
            ],
          });
        }

        if (page == 2) {
          return _jsonResponse({
            'count': 3,
            'next': null,
            'previous':
                'http://localhost/api/product-categories/?root=true&page=1',
            'results': [_productCategoryJson(id: 3, name: 'وجبات')],
          });
        }
        return _jsonResponse({
          'count': 3,
          'next': 'http://localhost/api/product-categories/?root=true&page=2',
          'previous': null,
          'results': [
            _productCategoryJson(id: 1, name: 'مشروبات', childrenCount: 2),
          ],
        });
      }

      if (path.endsWith('/variant-option-values/')) {
        return _jsonResponse({
          'count': 2,
          'next': null,
          'previous': null,
          'results': [
            {
              'id': 1,
              'option': 1,
              'option_name': 'الحجم',
              'code': 'large',
              'name': 'كبير',
              'display_order': 1,
              'is_active': true,
            },
            {
              'id': 2,
              'option': 2,
              'option_name': 'اللون',
              'code': 'red',
              'name': 'أحمر',
              'display_order': 2,
              'is_active': true,
            },
          ],
        });
      }

      if (path.endsWith('/variant-options/')) {
        return _jsonResponse({
          'count': 2,
          'next': null,
          'previous': null,
          'results': [
            _variantOptionJson(),
            _variantOptionJson(
              id: 2,
              code: 'color',
              name: 'اللون',
              values: const [
                {
                  'id': 2,
                  'option': 2,
                  'option_name': 'اللون',
                  'code': 'red',
                  'name': 'أحمر',
                  'display_order': 1,
                  'is_active': true,
                },
                {
                  'id': 3,
                  'option': 2,
                  'option_name': 'اللون',
                  'code': 'blue',
                  'name': 'أزرق',
                  'display_order': 2,
                  'is_active': true,
                },
              ],
            ),
          ],
        });
      }

      if (path.endsWith('/customers/')) {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({
            'id': 12,
            'customer_number': 'C20260519000012',
            'created_at': '2026-05-19T09:00:00Z',
            'updated_at': '2026-05-19T09:00:00Z',
            ...body,
          });
        }
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [_customerJson()],
        });
      }

      if (path.endsWith('/customers/12/sales-summary/')) {
        return _jsonResponse(_customerSalesSummaryJson());
      }

      if (path.endsWith('/customers/12/orders/')) {
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [_orderJson()],
        });
      }

      if (path.endsWith('/customers/12/adjustments/')) {
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [_customerAdjustmentJson()],
        });
      }

      if (path.endsWith('/customers/12/')) {
        return _jsonResponse(_customerJson());
      }

      if (path.endsWith('/suppliers/')) {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({
            'id': 14,
            'created_at': '2026-05-19T09:00:00Z',
            'updated_at': '2026-05-19T09:00:00Z',
            ...body,
          });
        }
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [_supplierJson()],
        });
      }

      if (path.endsWith('/discount-rules/')) {
        if (request.method == 'POST') {
          onDiscountRuleCreate?.call(request);
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({..._discountRuleJson(id: 3), ...body});
        }
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [_discountRuleJson()],
        });
      }

      if (path.endsWith('/discount-rules/1/enable/')) {
        return _jsonResponse(_discountRuleJson(isActive: true));
      }

      if (path.endsWith('/discount-rules/1/disable/')) {
        return _jsonResponse(_discountRuleJson(isActive: false));
      }

      if (path.endsWith('/discount-rules/1/')) {
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({..._discountRuleJson(), ...body});
        }
        if (request.method == 'DELETE') {
          return _jsonResponse(
            _discountRuleJson(
              isActive: false,
              metadata: {'archived_at': '2026-05-20T10:00:00Z'},
            ),
          );
        }
      }

      if (path.endsWith('/purchase-orders/discount-preview/')) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return _jsonResponse(_purchaseDiscountPreviewJson(body));
      }

      if (path.endsWith('/purchase-orders/')) {
        if (request.method == 'POST') {
          onPurchaseOrderCreate?.call(request);
          final body = jsonDecode(request.body) as Map<String, Object?>;
          final lines = body['lines'] is List<Object?>
              ? body['lines'] as List<Object?>
              : const <Object?>[];
          return _jsonResponse({
            ..._purchaseOrderJson(),
            ...body,
            'lines': [
              for (final line in lines.whereType<Map<String, Object?>>())
                {
                  'id': 1,
                  'product': 1,
                  'variant': line['variant'],
                  'product_name': 'قهوة البيت',
                  'variant_sku': 'COF-001',
                  'quantity': line['quantity'],
                  'adjusted_quantity': 0,
                  'adjustable_quantity': 2,
                  'unit_cost': line['unit_cost'],
                  'line_total': line['unit_cost'],
                },
            ],
          });
        }
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [_purchaseOrderJson()],
        });
      }

      if (path.endsWith('/supplier-payments/')) {
        if (request.method == 'POST') {
          onSupplierPaymentCreate?.call(request);
          final body = jsonDecode(request.body) as Map<String, Object?>;
          supplierPaidTotal += double.tryParse('${body['amount']}') ?? 0;
          return _jsonResponse({
            'id': 501,
            'supplier': body['supplier'] ?? 14,
            'supplier_name': 'مورد المدينة',
            'purchase_order': body['purchase_order'],
            'purchase_order_number': 'P20260515000200',
            'amount': body['amount'],
            'method': body['method'],
            'reference': body['reference'] ?? '',
            'notes': body['notes'] ?? '',
            'paid_at': '2026-05-19T11:00:00Z',
            'created_by_username': 'manager',
            'created_at': '2026-05-19T11:00:00Z',
            'updated_at': '2026-05-19T11:00:00Z',
          });
        }
        return _jsonResponse({
          'count': 0,
          'next': null,
          'previous': null,
          'results': const [],
        });
      }

      if (path.endsWith('/purchase-orders/200/submit/')) {
        return _jsonResponse(
          _purchaseOrderJson(
            status: 'submitted',
            submittedAt: '2026-05-15T10:00:00Z',
          ),
        );
      }

      if (path.endsWith('/purchase-orders/200/receive/')) {
        onPurchaseOrderReceive?.call(request);
        final body = request.body.isEmpty
            ? const <String, Object?>{}
            : jsonDecode(request.body) as Map<String, Object?>;
        final lines = body['lines'] is List<Object?>
            ? body['lines'] as List<Object?>
            : const <Object?>[];
        final typedLines = lines.whereType<Map<String, Object?>>().toList();
        final firstLine = typedLines.isEmpty ? null : typedLines.first;
        final receivedQuantity = firstLine == null
            ? 2
            : (double.tryParse('${firstLine['quantity_received']}') ?? 0)
                  .round();
        final damagedQuantity = firstLine == null
            ? 0
            : (double.tryParse('${firstLine['quantity_damaged']}') ?? 0)
                  .round();
        final rejectedQuantity = firstLine == null
            ? 0
            : (double.tryParse('${firstLine['quantity_rejected']}') ?? 0)
                  .round();
        final openQuantity =
            2 - receivedQuantity - damagedQuantity - rejectedQuantity;
        return _jsonResponse(
          _purchaseOrderJson(
            status: openQuantity > 0 ? 'partially_received' : 'received',
            submittedAt: '2026-05-15T10:00:00Z',
            receivedAt: openQuantity > 0 ? null : '2026-05-15T10:10:00Z',
            receivedQuantity: receivedQuantity,
            damagedQuantity: damagedQuantity,
            rejectedQuantity: rejectedQuantity,
            openQuantity: openQuantity,
            canAdjust: openQuantity <= 0,
            receipts: [
              _purchaseReceiptJson(
                receivedQuantity: receivedQuantity,
                damagedQuantity: damagedQuantity,
                note: body['note']?.toString() ?? '',
              ),
            ],
          ),
        );
      }

      if (path.endsWith('/purchase-orders/200/return-items/')) {
        if (purchaseReturnStatusCode != 200) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'code': 'received_stock_unavailable',
                'detail': 'received stock already sold',
              }),
            ),
            purchaseReturnStatusCode,
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
          );
        }
        return _jsonResponse(
          _purchaseOrderJson(
            status: 'received',
            submittedAt: '2026-05-15T10:00:00Z',
            receivedAt: '2026-05-15T10:10:00Z',
            adjustedQuantity: 1,
            adjustableQuantity: 1,
            canAdjust: true,
            adjustments: [_purchaseAdjustmentJson()],
          ),
        );
      }

      if (path.endsWith('/purchase-orders/200/exchange-items/')) {
        onPurchaseOrderExchange?.call(request);
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return _jsonResponse(
          _purchaseOrderJson(
            status: 'received',
            submittedAt: '2026-05-15T10:00:00Z',
            receivedAt: '2026-05-15T10:10:00Z',
            receivedQuantity: 2,
            openQuantity: 0,
            canAdjust: true,
            adjustments: [_purchaseExchangeAdjustmentJson(body)],
          ),
        );
      }

      if (path.endsWith('/purchase-orders/200/cancel/')) {
        return _jsonResponse(
          _purchaseOrderJson(
            status: 'cancelled',
            submittedAt: '2026-05-15T10:00:00Z',
          ),
        );
      }

      if (path.endsWith('/purchase-orders/last-cost/')) {
        return _jsonResponse({
          'product': int.tryParse(
            request.url.queryParameters['product'] ?? '0',
          ),
          'unit_cost': '2.75',
        });
      }

      if (path.endsWith('/purchase-orders/product-cost-history/')) {
        return _jsonResponse({
          'count': 1,
          'next': null,
          'previous': null,
          'results': [
            {
              'product': int.tryParse(
                request.url.queryParameters['product'] ?? '0',
              ),
              'purchase_order': 200,
              'purchase_order_number': 'PO-200',
              'supplier': 10,
              'supplier_name': 'مورد القهوة',
              'quantity': 2,
              'unit_cost': '3.75',
              'line_total': '7.50',
              'created_at': '2026-05-15T10:00:00Z',
            },
          ],
        });
      }

      if (path.endsWith('/purchase-orders/product-margin-impact/')) {
        return _jsonResponse({
          'product': int.tryParse(
            request.url.queryParameters['product'] ?? '0',
          ),
          'unit_price': '5.50',
          'latest_unit_cost': '3.75',
          'gross_profit': '1.75',
          'margin_percent': '31.82',
          'cost_change': '0.50',
        });
      }

      if (path.endsWith('/purchase-orders/200/')) {
        final purchaseOrderDetailTotal = purchaseOrderDetailHasLandedCosts
            ? 8.5
            : 7.5;
        return _jsonResponse(
          _purchaseOrderJson(
            status: purchaseOrderDetailStatus,
            submittedAt: purchaseOrderDetailStatus == 'draft'
                ? null
                : '2026-05-15T10:00:00Z',
            receivedAt: purchaseOrderDetailStatus == 'received'
                ? '2026-05-15T10:10:00Z'
                : null,
            receivedQuantity: purchaseOrderDetailStatus == 'received' ? 2 : 0,
            openQuantity: purchaseOrderDetailStatus == 'received' ? 0 : 2,
            canAdjust: purchaseOrderDetailCanAdjust,
            paidTotal: supplierPaidTotal.toStringAsFixed(2),
            balanceDue: (purchaseOrderDetailTotal - supplierPaidTotal)
                .toStringAsFixed(2),
            paymentStatus: supplierPaidTotal <= 0
                ? 'unpaid'
                : supplierPaidTotal >= purchaseOrderDetailTotal
                ? 'paid'
                : 'partial',
            landedCostEntries: purchaseOrderDetailHasLandedCosts
                ? const [
                    {'id': 1, 'name': 'شحن', 'amount': '0.75'},
                    {'id': 2, 'name': 'تخليص', 'amount': '0.25'},
                  ]
                : const [],
            landedCostTotal: purchaseOrderDetailHasLandedCosts
                ? '1.00'
                : '0.00',
            landedCostAllocationMethod: 'quantity',
          ),
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
        if (checkoutNoOpenSession) {
          return _jsonResponse({
            'detail': 'No open register session for this request owner.',
          }, statusCode: 400);
        }
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

      if (path.endsWith('/orders/discount-preview/')) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return _jsonResponse(
          _saleDiscountPreviewJson(body, hasLoss: saleDiscountPreviewHasLoss),
        );
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

      if (path.endsWith('/orders/lookup/')) {
        onSaleLookup?.call(request);
        final receipt = request.url.queryParameters['receipt'];
        if (receipt == 'R-500') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'detail': 'Server error.'})),
            500,
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
          );
        }
        if (receipt != 'R-100') {
          return http.Response.bytes(
            utf8.encode(jsonEncode({'detail': 'No invoice matches.'})),
            404,
            headers: const {'Content-Type': 'application/json; charset=utf-8'},
          );
        }
        return _jsonResponse(_orderJson());
      }

      if (path.endsWith('/orders/100/exchange-items/')) {
        onSaleExchange?.call(request);
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

      if (path.endsWith('/print-jobs/501/requeue/')) {
        onPrintJobRequeue?.call(request);
        return _jsonResponse(_printJobJson());
      }

      if (path.endsWith('/print-audit-events/record/')) {
        onPrintAuditRecord?.call(request);
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return _jsonResponse(_printAuditEventJson(body));
      }

      if (RegExp(r'/print-audit-events/\d+/report/$').hasMatch(path)) {
        onPrintAuditReport?.call(request);
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return _jsonResponse(
          _printAuditEventJson({
            'status': body['status'] ?? 'completed',
            'message': body['message'] ?? '',
          }),
        );
      }

      if (path.endsWith('/print-audit-events/')) {
        return _jsonResponse({
          'count': 0,
          'next': null,
          'previous': null,
          'results': <Object?>[],
        });
      }

      // The shop's money accounts and card machines. The practice fake keeps
      // ONE bank account, which is what an untouched install has: the till's
      // bank picker stays hidden and checkout is unchanged, while the terminal
      // registry is still a real list that can be added to and removed from.
      if (path.endsWith('/money-accounts/')) {
        return _jsonResponseList(const [
          {
            'id': 1,
            'name': 'المصرف',
            'kind': 'bank',
            'bank_name': '',
            'bank_slug': '',
            'account_number': '',
            'iban': '',
            'opening_balance': '0.00',
            'is_default': true,
            'is_active': true,
          },
        ]);
      }

      if (path.endsWith('/card-terminals/')) {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          final terminal = {
            'id': cardTerminals.length + 1,
            'terminal_id': body['terminal_id'],
            'label': body['label'] ?? '',
            'money_account': body['money_account'],
            'is_active': true,
            'display_order': cardTerminals.length,
          };
          cardTerminals.add(terminal);
          return _jsonResponse(terminal);
        }
        return _jsonResponseList(cardTerminals);
      }

      final terminalMatch = RegExp(r'/card-terminals/(\d+)/$').firstMatch(path);
      if (terminalMatch != null) {
        final id = int.parse(terminalMatch.group(1)!);
        final index = cardTerminals.indexWhere(
          (terminal) => terminal['id'] == id,
        );
        if (index < 0) {
          return http.Response('not found', 404);
        }
        if (request.method == 'DELETE') {
          cardTerminals.removeAt(index);
          return http.Response('', 204);
        }
        final body = jsonDecode(request.body) as Map<String, Object?>;
        cardTerminals[index] = {...cardTerminals[index], ...body};
        return _jsonResponse(cardTerminals[index]);
      }

      return http.Response('not found', 404);
    }),
  );
}

const _sampleMoamalatReceiptUrl =
    'https://receipt.moamalat.net:9443/frontTicketDigital/#/digital/ticket?query='
    'eJxdUstum0AU%2FZURy6qJZgBjsFcDdmVagxPAjtzd1EYNagALcCU36iqOVaVf0UXkNGobpUoX%2FZOZv%20mdsa1WvQuYOefc14GJ08c2cYij61i3sIV1YhuGqXf5E3%2FkW%2F6lS6PupRak1eycFU3I8lTraDENaQ%2FRoTsOpzSEQ0LPXvt9RLXnSEvSKs8KduFlzQq0gR%20PI5pQNJz%20y%2Fpz4PBLak%20JcSYJj1XzZLWQ5cNxMEIuDV8RSVC%2FBxjFKhwYEBMs8RMaAm4ZjtM2nx3CtrFzqDYoL%20ZpBZpTGp2ORgGK6bA%2FUKwqaasyiQfHttMmpuu2W05LN90Xuz0mkRJBmPKpsNiXPe3dzZsEUqKIihU1mzVZWeyXOBgoWb94X2azNFzmb9RALQn2WJMmmfIT60fYOtItROyOYXTM3d7L5ryssg9MFvXKuRJCtFQ2zctl0QBEjgFD%2FOFYrP8bJG5Ys6zlKPfimt8jvhVr%2Fltci7W44V8RvxMb%2Fg1G%2FI7UMuVitR8dfET8FkS%2FZMou7yfIP4kNAm6nzvNU9edP4kpuKj4jkG35D%20h2A%209HcYXg8gCttwBt%20FbmRWm9KIs63dvWr6qyCtK6Zm8P0ElZNS4r3kmbsK6rpEh9adIyiKUcUO7HifoB%2FgIuTbwBIKb28Q%2Fm9%206L';

http.Response _jsonResponse(Map<String, Object?> body, {int statusCode = 200}) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
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

const List<String> _payrollPermissions = [
  'employees.view_employee',
  'employees.add_employee',
  'employees.add_compensationplan',
  'employees.view_payrollrun',
  'employees.add_payrollrun',
  'employees.change_payrollrun',
  'employees.approve_payrollrun',
  'employees.mark_payrollrun_paid',
  'employees.view_employeeloan',
  'employees.approve_employeeloan',
  'employees.reject_employeeloan',
];

String _isoDate(DateTime date) {
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

Map<String, Object?> _employeeJson({int id = 1, String name = 'سالم'}) {
  return {
    'id': id,
    'employee_number': 'E$id',
    'full_name': name,
    'status': 'active',
    'employment_type': 'full_time',
    'hire_date': '2025-01-01',
    'has_system_access': false,
    'payroll_total': '0.00',
    'active_compensation_plan': {
      'id': id,
      'employee': id,
      'pay_type': 'monthly_salary',
      'salary_type': 'monthly_fixed',
      'amount': '500.00',
      'commission_percent': '0.00',
      'expected_units_per_period': '1.00',
      'effective_from': '2025-01-01',
      'is_active': true,
    },
  };
}

Map<String, Object?> _payrollLineJson({
  required int id,
  String employeeName = 'سالم',
}) {
  return {
    'id': id,
    'employee': 1,
    'employee_name': employeeName,
    'employee_number': 'E1',
    'pay_type': 'monthly_salary',
    'salary_type': 'monthly_fixed',
    'units': '1.00',
    'rate': '500.00',
    'gross_amount': '500.00',
    'absence_days': '0.00',
    'absence_day_rate': '16.67',
    'absence_deduction_amount': '0.00',
    'raise_amount': '0.00',
    'manual_addition_amount': '0.00',
    'manual_deduction_amount': '0.00',
    'additions_amount': '0.00',
    'deductions_amount': '0.00',
    'net_amount': '500.00',
    'adjustments': const <Object?>[],
    'notes': '',
  };
}

Map<String, Object?> _payrollRunJson({
  required int id,
  String status = 'draft',
  List<Map<String, Object?>>? lines,
}) {
  final now = DateTime.now();
  final resolvedLines = lines ?? [_payrollLineJson(id: id * 10)];
  return {
    'id': id,
    'run_number': 'PR$id',
    'status': status,
    'period_start': _isoDate(DateTime(now.year, now.month)),
    'period_end': _isoDate(DateTime(now.year, now.month + 1, 0)),
    'payment_date': null,
    'notes': '',
    'gross_total': '500.00',
    'additions_total': '0.00',
    'deductions_total': '0.00',
    'net_total': '500.00',
    'line_count': resolvedLines.length,
    'lines': resolvedLines,
    'approved_by_username': '',
    'paid_by_username': '',
  };
}

PosApiService _payrollApiService({
  List<Map<String, Object?>> employees = const [],
  List<Map<String, Object?>> payrollRuns = const [],
  List<Map<String, Object?>> loans = const [],
  Map<int, Map<String, Object?>> runDetails = const {},
  bool bioTimeEnabled = false,
}) {
  var runs = [...payrollRuns];
  var loanList = [...loans];
  final details = {...runDetails};

  return PosApiService(
    client: MockClient((request) async {
      final path = request.url.path;

      if (path.endsWith('/payroll-runs/draft-monthly/')) {
        final run = details.values.first;
        runs = [run, ...runs];
        return _jsonResponse({'created': true, 'payroll_run': run});
      }

      final approveMatch = RegExp(
        r'/payroll-runs/(\d+)/approve/$',
      ).firstMatch(path);
      if (approveMatch != null) {
        final id = int.parse(approveMatch.group(1)!);
        final run = {...details[id]!, 'status': 'approved'};
        details[id] = run;
        return _jsonResponse(run);
      }

      final applyAttendanceMatch = RegExp(
        r'/payroll-runs/(\d+)/apply-attendance/$',
      ).firstMatch(path);
      if (applyAttendanceMatch != null) {
        final id = int.parse(applyAttendanceMatch.group(1)!);
        final base = details[id]!;
        final lines = [
          for (final line in (base['lines'] as List<Object?>))
            {...(line as Map<String, Object?>), 'absence_days': '1.00'},
        ];
        final run = {
          ...base,
          'lines': lines,
          'deductions_total': '50.00',
          'net_total': '450.00',
        };
        details[id] = run;
        return _jsonResponse(run);
      }

      final paidMatch = RegExp(
        r'/payroll-runs/(\d+)/mark-paid/$',
      ).firstMatch(path);
      if (paidMatch != null) {
        final id = int.parse(paidMatch.group(1)!);
        final run = {...details[id]!, 'status': 'paid'};
        details[id] = run;
        return _jsonResponse(run);
      }

      final detailMatch = RegExp(r'/payroll-runs/(\d+)/$').firstMatch(path);
      if (detailMatch != null) {
        final id = int.parse(detailMatch.group(1)!);
        return _jsonResponse(details[id]!);
      }

      if (path.endsWith('/payroll-runs/')) {
        return _jsonResponse({'results': runs, 'next': null});
      }

      final loanApproveMatch = RegExp(
        r'/employee-loans/(\d+)/approve/$',
      ).firstMatch(path);
      if (loanApproveMatch != null) {
        final id = int.parse(loanApproveMatch.group(1)!);
        final loan = {
          ...loanList.firstWhere((entry) => entry['id'] == id),
          'status': 'approved',
        };
        loanList = [
          for (final entry in loanList)
            if (entry['id'] == id) loan else entry,
        ];
        return _jsonResponse(loan);
      }

      if (path.endsWith('/employee-loans/')) {
        return _jsonResponse({'results': loanList, 'next': null});
      }

      if (path.endsWith('/employees/')) {
        return _jsonResponse({'results': employees, 'next': null});
      }

      if (path.endsWith('/attendance/connection/')) {
        return _jsonResponse({
          'base_url': bioTimeEnabled ? 'https://biotime.example' : '',
          'is_enabled': bioTimeEnabled,
        });
      }

      return http.Response('', 404);
    }),
  );
}

Widget _payrollApp(
  EmployeePayrollViewModel viewModel,
  PosApiService apiService,
) {
  final capabilities = AuthorizationCapabilities.forUser(
    PosUser.fromJson(_userJson(permissions: _payrollPermissions)),
  );

  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: EmployeePayrollScreen(
      viewModel: viewModel,
      attendanceViewModel: AttendanceViewModel(
        AttendanceRepository(apiService),
      ),
      userRepository: UserRepository(apiService),
      capabilities: capabilities,
      navigation: FakeAppNavigation(
        currentUser: PosUser.fromJson(
          _userJson(permissions: _payrollPermissions),
        ),
        capabilities: capabilities,
      ),
    ),
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

Map<String, Object?> _richDashboardJson() {
  return {
    'generated_at': '2026-06-12T09:00:00Z',
    'period': {
      'days': 30,
      'start': '2026-05-13T00:00:00Z',
      'end': '2026-06-12T00:00:00Z',
      'previous_start': '2026-04-13T00:00:00Z',
      'previous_end': '2026-05-13T00:00:00Z',
    },
    'sections': {
      'sales': {
        'summary': {
          'gross_sales': '1530.00',
          'discount_total': '20.00',
          'refund_total': '10.00',
          'net_sales': '1500.00',
          'net_sales_change_percent': '12.50',
          'gross_profit': '600.00',
          'profit_margin_percent': '40.00',
          'order_count': 42,
          'order_count_change_percent': '5.00',
          'average_order_value': '35.71',
          'items_sold': 90,
          'void_count': 1,
          'return_count': 2,
        },
        'registers': {
          'open_count': 1,
          'closed_count': 3,
          'variance_count': 1,
          'variance_total': '5.00',
        },
        'trend': const <Object?>[],
        'hourly_sales': const <Object?>[],
        'top_products': const <Object?>[],
        'top_categories': const <Object?>[],
        'recent_orders': const <Object?>[],
      },
      'inventory': {
        'summary': {
          'product_count': 10,
          'active_product_count': 9,
          'stock_item_count': 12,
          'low_stock_count': 3,
          'out_of_stock_count': 2,
          'committed_units': 0,
          'expected_units': 0,
          'retail_stock_value': '5000.00',
        },
        'low_stock_items': const <Object?>[],
        'low_stock_variants': const <Object?>[],
        'dusty_items': const <Object?>[],
        'movement_mix': const <Object?>[],
        'recent_movements': const <Object?>[],
      },
      'payroll': {
        'summary': {
          'salary_expense': '200.00',
          'paid_total': '200.00',
          'pending_total': '300.00',
          'active_employee_count': 4,
          'payroll_run_count': 1,
          'draft_run_count': 1,
          'pending_run_count': 1,
          'pending_loan_request_count': 2,
        },
        'recent_runs': const <Object?>[],
      },
      'profitability': {
        'summary': {
          'gross_profit': '600.00',
          'payroll_paid_total': '200.00',
          'payroll_accrued_total': '300.00',
          'payment_commission_total': '15.00',
          'purchase_spend_total': '0.00',
          'operating_expense_total': '215.00',
          'net_operating_profit': '385.00',
        },
      },
      'fraud': {
        'summary': {
          'active_count': 2,
          'critical_count': 1,
          'top_risk_score': 88,
        },
        'recent_findings': [
          {
            'id': 11,
            'rule_code': 'cash_shortage',
            'rule_title': 'عجز نقدي',
            'headline': 'عجز نقدي متكرر في جلسات الدرج',
            'user_label': 'سالم',
            'severity': 'critical',
            'risk_score': 88,
            'last_detected_at': '2026-06-12T08:00:00Z',
          },
        ],
      },
    },
  };
}

Map<String, Object?> _dashboardJson() {
  return {
    'generated_at': '2026-05-21T09:00:00Z',
    'period': {
      'days': 30,
      'start': '2026-04-21T00:00:00Z',
      'end': '2026-05-21T00:00:00Z',
      'previous_start': '2026-03-22T00:00:00Z',
      'previous_end': '2026-04-21T00:00:00Z',
    },
    'sections': <String, Object?>{},
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
  bool enableOnlineInvoices = false,
  bool allowOverselling = false,
  bool preventSellingAtLoss = true,
  bool requireCardPaymentReceipt = false,
  List<String> trustedCardTerminalIds = const [],
  int cashierReturnWindowHours = 42,
  Map<String, Object?>? logoAttachment,
}) {
  return {
    'shop_name': 'متجر نقطة البيع',
    'logo_attachment': logoAttachment,
    'receipt_header': 'أهلا بكم',
    'receipt_footer': 'شكرا لزيارتكم',
    'enable_online_invoices': enableOnlineInvoices,
    'require_opening_cash': requireOpeningCash,
    'auto_print_receipts': autoPrintReceipts,
    'allow_overselling': allowOverselling,
    'prevent_selling_at_loss': preventSellingAtLoss,
    'low_stock_threshold': 5,
    'cashier_return_window_hours': cashierReturnWindowHours,
    'enable_cash_payments': true,
    'enable_card_payments': true,
    'enable_transfer_payments': true,
    'require_card_payment_receipt': requireCardPaymentReceipt,
    'trusted_card_terminal_ids': trustedCardTerminalIds,
    'card_commission_percent': '1.00',
    'transfer_commission_percent': '0.00',
  };
}

Map<String, Object?> _backupOperationsJson({
  required bool enabled,
  required String destinationPath,
  required String scheduledTime,
}) {
  return {
    'schedule': {
      'enabled': enabled,
      'destination_path': destinationPath,
      'scheduled_time': scheduledTime,
      'retention_count': 7,
      'next_scheduled_at': enabled && destinationPath.isNotEmpty
          ? '2026-06-09T02:00:00Z'
          : null,
      'updated_at': '2026-06-09T01:00:00Z',
    },
    'active_job': null,
    'latest_backup_job': null,
    'latest_restore_job': null,
  };
}

Map<String, Object?> _backupJobJson() {
  return {
    'id': 1,
    'operation': 'backup',
    'status': 'queued',
    'progress_percent': 0,
    'progress_message': 'تمت جدولة النسخ الاحتياطي.',
    'destination_path': '/mnt/pointy-backup',
    'backup_file_name': '',
    'archive_size_bytes': 0,
    'error_message': '',
    'metadata': <String, Object?>{},
    'initiated_by_user_id': 1,
    'initiated_by_username': 'manager',
    'created_at': '2026-06-09T01:00:00Z',
    'updated_at': '2026-06-09T01:00:00Z',
    'started_at': null,
    'completed_at': null,
  };
}

Map<String, Object?> _productPageJson({
  int quantityOnHand = 12,
  String barcode = '',
  bool isPrepared = false,
}) {
  return {
    'next': null,
    'results': [
      _productJson(
        quantityOnHand: quantityOnHand,
        barcode: barcode,
        isPrepared: isPrepared,
      ),
    ],
  };
}

Map<String, Object?> _productJson({
  int quantityOnHand = 12,
  String barcode = '',
  bool isPrepared = false,
}) {
  return {
    'id': 1,
    'name': 'قهوة البيت',
    'description': '',
    'is_active': true,
    'is_prepared': isPrepared,
    'categories': const [],
    'category_details': const [],
    'variant_options': const [],
    'variant_option_details': const [],
    'quantity_on_hand': quantityOnHand,
    'default_variant': _productVariantJson(
      quantityOnHand: quantityOnHand,
      barcode: barcode,
      isPrepared: isPrepared,
    ),
    'variants': [
      _productVariantJson(
        quantityOnHand: quantityOnHand,
        barcode: barcode,
        isPrepared: isPrepared,
      ),
    ],
  };
}

Map<String, Object?> _productVariantJson({
  int id = 1,
  int productId = 1,
  int quantityOnHand = 12,
  String barcode = '',
  bool isPrepared = false,
}) {
  return {
    'id': id,
    'product': productId,
    'product_name': 'قهوة البيت',
    'product_detail': {
      'id': productId,
      'name': 'قهوة البيت',
      'description': '',
      'is_active': true,
      'categories': const [],
      'category_details': const [],
      'variant_options': const [],
      'variant_option_details': const [],
    },
    'name': '',
    'display_name': 'قهوة البيت',
    'full_name': 'قهوة البيت',
    'sku': 'COF-001',
    'barcode': barcode,
    'unit_price': '3.50',
    'is_active': true,
    'is_default': true,
    'is_prepared': isPrepared,
    'option_values': const [],
    'option_value_details': const [],
    'quantity_on_hand': quantityOnHand,
  };
}

Map<String, Object?> _variantOptionJson({
  int id = 1,
  String code = 'size',
  String name = 'الحجم',
  List<Map<String, Object?>> values = const [
    {
      'id': 1,
      'option': 1,
      'option_name': 'الحجم',
      'code': 'large',
      'name': 'كبير',
      'display_order': 1,
      'is_active': true,
    },
  ],
}) {
  return {
    'id': id,
    'code': code,
    'name': name,
    'display_order': id,
    'is_active': true,
    'values': values,
  };
}

Map<String, Object?> _productCategoryJson({
  int id = 1,
  String name = 'مشروبات',
  String description = '',
  int? parent,
  String parentName = '',
  int childrenCount = 0,
  bool isActive = true,
}) {
  return {
    'id': id,
    'name': name,
    'description': description,
    'parent': parent,
    'parent_name': parentName,
    'children_count': childrenCount,
    'is_active': isActive,
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

Map<String, Object?> _discountRuleJson({
  int id = 1,
  String name = 'خصم القهوة',
  String description = 'خصم تلقائي على مبيعات القهوة',
  String channel = 'sales',
  String applicationType = 'automatic',
  String couponCode = '',
  String scope = 'document',
  String valueType = 'percentage',
  String value = '10.0000',
  String? maxDiscountAmount,
  String minOrderSubtotal = '0.00',
  int? minLineQuantity,
  int priority = 100,
  bool exclusive = true,
  bool isActive = true,
  String? startsAt,
  String? endsAt,
  int? usageLimit,
  int? perCustomerUsageLimit,
  int? perSupplierUsageLimit,
  List<int> products = const [],
  List<int> customers = const [],
  List<int> suppliers = const [],
  Map<String, Object?> metadata = const {},
}) {
  return {
    'id': id,
    'name': name,
    'description': description,
    'channel': channel,
    'application_type': applicationType,
    'coupon_code': couponCode,
    'scope': scope,
    'value_type': valueType,
    'value': value,
    'max_discount_amount': maxDiscountAmount,
    'min_order_subtotal': minOrderSubtotal,
    'min_line_quantity': minLineQuantity,
    'priority': priority,
    'exclusive': exclusive,
    'is_active': isActive,
    'starts_at': startsAt,
    'ends_at': endsAt,
    'usage_limit': usageLimit,
    'per_customer_usage_limit': perCustomerUsageLimit,
    'per_supplier_usage_limit': perSupplierUsageLimit,
    'products': products,
    'customers': customers,
    'suppliers': suppliers,
    'metadata': metadata,
    'redemption_count': 2,
    'applied_count': 5,
    'created_at': '2026-05-15T09:00:00Z',
    'updated_at': '2026-05-16T09:30:00Z',
  };
}

Map<String, Object?> _purchaseOrderJson({
  int id = 200,
  String orderNumber = 'P20260515000200',
  String status = 'draft',
  String total = '7.50',
  String landedCostTotal = '0.00',
  List<Map<String, Object?>> landedCostEntries = const [],
  String landedCostAllocationMethod = 'line_value',
  String? submittedAt,
  String? receivedAt,
  String? dueDate = '2026-05-25',
  String paidTotal = '0.00',
  String creditAppliedTotal = '0.00',
  String adjustmentCreditTotal = '0.00',
  String balanceDue = '7.50',
  String paymentStatus = 'unpaid',
  bool isOverdue = false,
  int adjustedQuantity = 0,
  int adjustableQuantity = 2,
  int? receivedQuantity,
  int? damagedQuantity,
  int? rejectedQuantity,
  int? openQuantity,
  bool canAdjust = false,
  int? supplierId = 14,
  String? supplierName = 'مورد المدينة',
  String supplierInvoiceNumber = 'INV-4432',
  String? supplierInvoiceDate = '2026-05-18',
  List<Map<String, Object?>> receipts = const [],
  List<Map<String, Object?>> adjustments = const [],
}) {
  final subtotal = double.tryParse(total) ?? 0;
  final landedCost = double.tryParse(landedCostTotal) ?? 0;
  final documentTotal = (subtotal + landedCost).toStringAsFixed(2);
  final lineQuantity = 2;
  final effectiveUnitCost = lineQuantity == 0
      ? 0.0
      : (subtotal + landedCost) / lineQuantity;
  final landedUnitCost = lineQuantity == 0 ? 0.0 : landedCost / lineQuantity;

  return {
    'id': id,
    'order_number': orderNumber,
    'supplier': supplierId,
    'supplier_name': supplierName,
    'supplier_reference': supplierInvoiceNumber,
    'supplier_invoice_number': supplierInvoiceNumber,
    'supplier_invoice_date': supplierInvoiceDate,
    'status': status,
    'notes': '',
    'lines': [
      {
        'id': 1,
        'product': 1,
        'product_name': 'قهوة البيت',
        'variant_sku': 'COF-001',
        'quantity': lineQuantity,
        'received_quantity': receivedQuantity,
        'damaged_quantity': damagedQuantity,
        'rejected_quantity': rejectedQuantity,
        'open_quantity': openQuantity,
        'adjusted_quantity': adjustedQuantity,
        'adjustable_quantity': adjustableQuantity,
        'unit_cost': '3.75',
        'line_total': total,
        if (landedCost > 0) ...{
          'allocated_landed_cost': landedCostTotal,
          'landed_unit_cost': landedUnitCost.toStringAsFixed(2),
          'effective_unit_cost': effectiveUnitCost.toStringAsFixed(2),
          'effective_line_total': documentTotal,
        },
      },
    ],
    'receipts': receipts,
    'adjustments': adjustments,
    'subtotal': total,
    'landed_cost_entries': landedCostEntries,
    'landed_cost_total': landedCostTotal,
    'landed_cost_allocation_method': landedCostAllocationMethod,
    'total': documentTotal,
    'due_date': dueDate,
    'paid_total': paidTotal,
    'credit_applied_total': creditAppliedTotal,
    'adjustment_credit_total': adjustmentCreditTotal,
    'balance_due': balanceDue,
    'payment_status': paymentStatus,
    'is_overdue': isOverdue,
    'can_return': canAdjust,
    'can_refund': canAdjust,
    'can_exchange': canAdjust,
    'submitted_at': submittedAt,
    'received_at': receivedAt,
    'created_at': '2026-05-15T09:00:00Z',
    'updated_at': '2026-05-15T09:30:00Z',
  };
}

Map<String, Object?> _purchaseAdjustmentJson() {
  return {
    'id': 300,
    'adjustment_type': 'return',
    'amount': '3.75',
    'reason': '',
    'settlement_method': 'supplier_credit',
    'created_by': 1,
    'created_by_username': 'manager',
    'credits': [
      {
        'id': 401,
        'amount': '3.75',
        'remaining_amount': '3.75',
        'created_at': '2026-05-15T10:20:00Z',
      },
    ],
    'lines': [
      {
        'id': 301,
        'purchase_line': 1,
        'product': 1,
        'product_name': 'قهوة البيت',
        'quantity': 1,
        'unit_cost': '3.75',
        'line_total': '3.75',
      },
    ],
    'created_at': '2026-05-15T10:20:00Z',
    'updated_at': '2026-05-15T10:20:00Z',
  };
}

Map<String, Object?> _purchaseExchangeAdjustmentJson(
  Map<String, Object?> body,
) {
  final lines = body['lines'] is List<Object?>
      ? body['lines'] as List<Object?>
      : const <Object?>[];
  final replacementLines = body['replacement_lines'] is List<Object?>
      ? body['replacement_lines'] as List<Object?>
      : const <Object?>[];
  return {
    'id': 301,
    'adjustment_type': 'exchange',
    'amount': '3.75',
    'outbound_amount': '3.75',
    'replacement_amount': '3.75',
    'net_amount': '0.00',
    'reason': body['reason'] ?? '',
    'settlement_method': '',
    'created_by': 1,
    'created_by_username': 'manager',
    'credits': const [],
    'lines': [
      for (final line in lines.whereType<Map<String, Object?>>())
        {
          'id': 302,
          'purchase_line': line['line'],
          'product': 1,
          'product_name': 'قهوة البيت',
          'quantity': line['quantity'],
          'unit_cost': '3.75',
          'line_total': '3.75',
        },
    ],
    'replacement_lines': [
      for (final line in replacementLines.whereType<Map<String, Object?>>())
        {
          'id': 303,
          'product': line['product'] ?? line['variant'],
          'product_name': 'قهوة البيت',
          'quantity': line['quantity'],
          'unit_cost': line['unit_cost'],
          'line_total': line['unit_cost'],
        },
    ],
    'created_at': '2026-05-15T10:20:00Z',
    'updated_at': '2026-05-15T10:20:00Z',
  };
}

Map<String, Object?> _purchaseReceiptJson({
  int receivedQuantity = 1,
  int damagedQuantity = 0,
  int rejectedQuantity = 0,
  String note = '',
}) {
  return {
    'id': 350,
    'note': note,
    'created_by_username': 'manager',
    'created_at': '2026-05-15T10:10:00Z',
    'lines': [
      {
        'purchase_line': 1,
        'product_name': 'قهوة البيت',
        'quantity_received': receivedQuantity,
        'quantity_damaged': damagedQuantity,
        'quantity_rejected': rejectedQuantity,
      },
    ],
  };
}

Map<String, Object?> _customerJson({
  int id = 12,
  String customerNumber = 'C20260519000012',
  String fullName = 'ليلى أحمد',
  String phone = '+218911234567',
  String gender = 'female',
  String? birthday = '1995-05-12',
  bool marketingConsent = true,
}) {
  return {
    'id': id,
    'customer_number': customerNumber,
    'full_name': fullName,
    'phone': phone,
    'email': 'layla@example.com',
    'gender': gender,
    'birthday': birthday,
    'marketing_consent': marketingConsent,
    'notes': '',
    'is_active': true,
    'created_at': '2026-05-19T09:00:00Z',
    'updated_at': '2026-05-19T09:00:00Z',
  };
}

Map<String, Object?> _customerSalesSummaryJson() {
  return {
    'customer': 12,
    'invoice_count': 1,
    'paid_invoice_count': 1,
    'void_invoice_count': 0,
    'return_count': 1,
    'void_count': 0,
    'refund_count': 1,
    'exchange_count': 0,
    'total_invoiced': '7.00',
    'return_total': '3.50',
    'void_total': '0.00',
    'refund_total': '3.50',
    'exchange_total': '0.00',
    'net_sales': '3.50',
    'last_invoice_at': '2026-05-15T09:10:00Z',
  };
}

Map<String, Object?> _customerAdjustmentJson() {
  return {
    'id': 700,
    'order': 100,
    'receipt_number': 'R-100',
    'customer': 12,
    'register_session': 1,
    'register_session_number': 'RS-1',
    'adjustment_type': 'return',
    'amount': '3.50',
    'refund_method': 'cash',
    'reason': 'طلب العميل الإرجاع',
    'created_by': 1,
    'created_by_username': 'manager',
    'lines': [
      {
        'id': 701,
        'order_line': 1000,
        'product': 1,
        'variant': 1,
        'product_name': 'قهوة البيت',
        'variant_name': 'قهوة البيت',
        'quantity': 1,
        'unit_price': '3.50',
        'discount_total': '0.00',
        'line_total': '3.50',
      },
    ],
    'created_at': '2026-05-15T09:20:00Z',
    'updated_at': '2026-05-15T09:20:00Z',
  };
}

Map<String, Object?> _supplierJson({
  int id = 14,
  String name = 'مورد المدينة',
  String phone = '+21891222333',
}) {
  return {
    'id': id,
    'name': name,
    'contact_name': 'منى',
    'phone': phone,
    'email': 'supplier@example.com',
    'address': 'طرابلس',
    'notes': '',
    'is_active': true,
    'payable_balance': '120.00',
    'credit_balance': '15.00',
    'net_balance': '105.00',
    'created_at': '2026-05-19T09:00:00Z',
    'updated_at': '2026-05-19T09:00:00Z',
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

Map<String, Object?> _sessionSummaryJson() {
  return {
    'session': {
      'id': 1,
      'session_number': 'RS-1',
      'status': 'closed',
      'owner_name': 'كاشير',
      'opened_at': '2026-05-15T08:00:00Z',
      'closed_at': '2026-05-15T20:00:00Z',
    },
    'sales': {
      'gross_sales': '7.00',
      'discount_total': '0.00',
      'net_sales': '7.00',
      'order_count': 1,
      'void_count': 0,
      'items_sold': '2',
    },
    'refunds': {
      'refund_total': '0.00',
      'return_count': 0,
      'cash_refund_total': '0.00',
    },
    'payment_methods': [
      {
        'method': 'cash',
        'gross': '6.00',
        'commission': '0.00',
        'refund': '0.00',
        'net': '6.00',
        'count': 1,
      },
      {
        'method': 'card',
        'gross': '1.00',
        'commission': '0.00',
        'refund': '0.00',
        'net': '1.00',
        'count': 1,
      },
      {
        'method': 'transfer',
        'gross': '0.00',
        'commission': '0.00',
        'refund': '0.00',
        'net': '0.00',
        'count': 0,
      },
    ],
    'payment_totals': {
      'gross': '7.00',
      'commission': '0.00',
      'refund': '0.00',
      'net': '7.00',
      'count': 2,
    },
    'categories': [
      {'category': 'مشروبات', 'quantity': '2', 'net': '7.00'},
    ],
    'cash': {
      'opening_cash': '12.00',
      'cash_sales_total': '6.00',
      'pay_in_total': '5.00',
      'pay_out_total': '0.00',
      'cash_refund_total': '0.00',
      'expected_cash': '23.00',
      'closing_cash': '18.75',
      'cash_variance': '-0.25',
      'has_cash_variance': true,
      'denomination_total': '0.00',
      'denominations': [
        {'value': '0.25', 'count': 0},
        {'value': '0.50', 'count': 0},
        {'value': '0.75', 'count': 0},
        {'value': '1.00', 'count': 0},
      ],
    },
    'expenses': {'total': '0.00', 'count': 0},
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
    'payments': [
      {
        'id': 900,
        'method': 'cash',
        'amount': total,
        'commission_percent': '0.00',
        'commission_amount': '0.00',
        'external_reference': '',
        'created_at': createdAt,
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

Map<String, Object?> _saleDiscountPreviewJson(
  Map<String, Object?> body, {
  bool hasLoss = false,
}) {
  final lines = body['lines'] is List<Object?>
      ? body['lines'] as List<Object?>
      : const <Object?>[];
  var subtotal = 0.0;
  for (final line in lines.whereType<Map<String, Object?>>()) {
    final productId =
        int.tryParse('${line['variant'] ?? line['product']}') ?? 0;
    final quantity = int.tryParse('${line['quantity']}') ?? 0;
    final unitPrice = productId == 1 ? 3.50 : 0.0;
    subtotal += unitPrice * quantity;
  }
  final normalizedCouponCode = body['coupon_code']?.toString().trim() ?? '';
  return {
    'subtotal': subtotal.toStringAsFixed(2),
    'discount_total': '0.00',
    'total': subtotal.toStringAsFixed(2),
    'applied_discounts': const [],
    'loss_lines': hasLoss
        ? const [
            {
              'line_key': '0',
              'product': 1,
              'product_id': 1,
              'variant': 1,
              'variant_id': 1,
              'product_name': 'قهوة البيت',
              'variant_name': 'قهوة البيت',
              'quantity': 1,
              'unit_price': '3.50',
              'unit_cost': '4.50',
              'discount_total': '0.00',
              'line_total': '3.50',
              'line_cost': '4.50',
              'loss_amount': '1.00',
            },
          ]
        : const [],
    'unapplied_coupon_codes': normalizedCouponCode.isEmpty
        ? const []
        : [normalizedCouponCode],
  };
}

Map<String, Object?> _purchaseDiscountPreviewJson(Map<String, Object?> body) {
  final rawLines = body['lines'] is List<Object?>
      ? body['lines'] as List<Object?>
      : const <Object?>[];
  final previewLines = <Map<String, Object?>>[];
  var subtotal = 0.0;
  for (final line in rawLines.whereType<Map<String, Object?>>()) {
    final quantity = double.tryParse('${line['quantity']}') ?? 0;
    final unitCost = double.tryParse('${line['unit_cost']}') ?? 0;
    final lineTotal = unitCost * quantity;
    subtotal += lineTotal;
    previewLines.add({
      'product': line['product'] ?? line['variant'] ?? 0,
      'variant': line['variant'] ?? 0,
      'quantity': quantity,
      'unit_cost': unitCost.toStringAsFixed(2),
      'line_total': lineTotal.toStringAsFixed(2),
    });
  }
  final landedCostEntries = body['landed_cost_entries'] is List<Object?>
      ? body['landed_cost_entries'] as List<Object?>
      : const <Object?>[];
  final landedCostTotal = landedCostEntries
      .whereType<Map<String, Object?>>()
      .fold<double>(
        0,
        (sum, entry) =>
            sum + (double.tryParse('${entry['amount'] ?? '0'}') ?? 0),
      );
  final codes = body['discount_codes'] is List<Object?>
      ? body['discount_codes'] as List<Object?>
      : const <Object?>[];
  final normalizedCode = codes.isEmpty ? '' : codes.first.toString().trim();
  final hasValidCode = normalizedCode.toUpperCase() == 'SUPSAVE';
  final discountTotal = hasValidCode ? 1.0 : 0.0;
  final allocationMethod = body['landed_cost_allocation_method']?.toString();
  final landedAllocations = _allocatePreviewAmounts(
    amount: landedCostTotal,
    weights: [
      for (final line in previewLines)
        switch (allocationMethod) {
          'quantity' => double.tryParse('${line['quantity']}') ?? 0,
          'equal' => 1.0,
          _ => double.tryParse('${line['line_total']}') ?? 0,
        },
    ],
  );
  final discountAllocations = _allocatePreviewAmounts(
    amount: discountTotal,
    weights: [
      for (final line in previewLines)
        double.tryParse('${line['line_total']}') ?? 0,
    ],
  );

  return {
    'subtotal': subtotal.toStringAsFixed(2),
    'discount_total': discountTotal.toStringAsFixed(2),
    'landed_cost_total': landedCostTotal.toStringAsFixed(2),
    'total': (subtotal - discountTotal + landedCostTotal).toStringAsFixed(2),
    'lines': [
      for (final (index, line) in previewLines.indexed)
        () {
          final quantity = double.tryParse('${line['quantity']}') ?? 0;
          final lineTotal = double.tryParse('${line['line_total']}') ?? 0;
          final discountAmount = discountAllocations[index];
          final netLineTotal = lineTotal - discountAmount;
          final allocatedLandedCost = landedAllocations[index];
          final landedUnitCost = quantity == 0
              ? 0.0
              : allocatedLandedCost / quantity;
          final effectiveUnitCost = quantity == 0
              ? 0.0
              : (netLineTotal + allocatedLandedCost) / quantity;
          return {
            ...line,
            'discount_amount': discountAmount.toStringAsFixed(2),
            'net_line_total': netLineTotal.toStringAsFixed(2),
            'net_unit_cost': quantity == 0
                ? '0.00'
                : (netLineTotal / quantity).toStringAsFixed(2),
            'allocated_landed_cost': allocatedLandedCost.toStringAsFixed(2),
            'landed_unit_cost': landedUnitCost.toStringAsFixed(2),
            'effective_unit_cost': effectiveUnitCost.toStringAsFixed(2),
            'effective_line_total': (netLineTotal + allocatedLandedCost)
                .toStringAsFixed(2),
          };
        }(),
    ],
    'applied_discounts': hasValidCode
        ? [
            {
              'rule_id': 10,
              'rule_name': 'خصم مورد',
              'coupon_code': 'SUPSAVE',
              'source': 'coupon_code',
              'scope': 'document',
              'value_type': 'fixed_amount',
              'value': '1.0000',
              'discount_amount': '1.00',
              'allocations': const [],
            },
          ]
        : const [],
    'unapplied_discount_codes': normalizedCode.isEmpty || hasValidCode
        ? const []
        : [normalizedCode],
  };
}

List<double> _allocatePreviewAmounts({
  required double amount,
  required List<double> weights,
}) {
  if (amount <= 0 || weights.isEmpty) {
    return List<double>.filled(weights.length, 0);
  }
  final totalWeight = weights.fold<double>(0, (sum, weight) => sum + weight);
  if (totalWeight <= 0) {
    return List<double>.filled(weights.length, 0);
  }
  final totalCents = (amount * 100).round();
  var allocatedCents = 0;
  return [
    for (final (index, weight) in weights.indexed)
      if (index == weights.length - 1)
        (totalCents - allocatedCents) / 100
      else
        () {
          final cents = (totalCents * weight / totalWeight).floor();
          allocatedCents += cents;
          return cents / 100;
        }(),
  ];
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

Map<String, Object?> _printAuditEventJson(Map<String, Object?> body) {
  final documentType = body['document_type']?.toString() ?? 'sale_order';
  final documentId =
      body['document_id'] ?? (documentType == 'sale_order' ? 100 : 77);
  return {
    'id': 701,
    'document_type': documentType,
    'action': body['action'] ?? 'print',
    'status': body['status'] ?? 'requested',
    'sale_order': documentType == 'sale_order' ? documentId : null,
    'purchase_order': documentType == 'purchase_order' ? documentId : null,
    'document_number': documentType == 'sale_order' ? 'R-100' : 'P-77',
    'print_job': body['print_job'],
    'user': 1,
    'username': 'admin',
    'agent': 1,
    'agent_identifier': body['agent_id'] ?? 'pointy-local-agent',
    'device_name': body['device_name'] ?? 'pointy-local-agent',
    'printer_name': body['printer_name'] ?? 'محاكاة الطابعة',
    'printer_endpoint': body['printer_endpoint'] ?? const <String, Object?>{},
    'message': body['message'] ?? '',
    'metadata': body['metadata'] ?? const <String, Object?>{},
    'created_at': '2026-05-15T09:11:00Z',
    'updated_at': '2026-05-15T09:12:00Z',
  };
}

/// Makes [config] this device's only printer, doing receipts and labels —
/// what the one printer did before printers had jobs.
Future<void> _saveOnlyPrinter(
  PrintingRepository repository,
  PrinterConfig config,
) async {
  final result = await repository.saveDevicePrinters(
    DevicePrinters([
      DevicePrinter(
        id: 'only-printer',
        config: config,
        roles: const {PrinterRole.posReceipt, PrinterRole.barcodeLabels},
      ),
    ]),
  );
  expect(result, isA<Ok<void>>());
}

void _setFakePrinterConfig() {
  installMemoryKeyValueStore({
    'default_printer_config': jsonEncode({
      'endpoint': {'kind': 'fake', 'name': 'محاكاة الطابعة', 'address': 'fake'},
      'is_enabled': true,
      'auto_claim_jobs': true,
      'agent_id': 'pointy-local-agent',
    }),
  });
}
