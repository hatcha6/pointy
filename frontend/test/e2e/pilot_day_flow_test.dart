import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/app.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/dashboard.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/print_job.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/query.dart';
import 'package:pointy_frontend/src/data/models/register_cash_movement.dart';
import 'package:pointy_frontend/src/data/models/register_cash_movement_page.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/register_session_page.dart';
import 'package:pointy_frontend/src/data/models/report_run.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/sale_order_page.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/product_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'default_printer_config': jsonEncode({
        'endpoint': {
          'kind': 'fake',
          'name': 'محاكاة الطابعة',
          'address': 'fake',
        },
        'is_enabled': true,
        'auto_claim_jobs': true,
        'agent_id': 'pointy-local-agent',
      }),
    });
  });

  testWidgets(
    'pilot day flow sells, prints, moves cash, closes, and opens reports',
    (tester) async {
      _setDesktopSurface(tester);
      final apiService = _PilotDayApiService();

      await tester.pumpWidget(PointyApp(apiService: apiService));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('لوحة التحكم'), findsWidgets);

      await _openDrawerDestination(tester, 'شاشة البيع');
      expect(find.text('جلسة الدرج'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '20.00');
      await tester.tap(find.text('بدء الجلسة'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('البيع الحالي'), findsOneWidget);
      expect(find.text('جلسة RS-PILOT'), findsOneWidget);

      await tester.tap(find.text('عميل عابر'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.text('ليلى أحمد').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ProductTile).first);
      await tester.pump();
      await tester.tap(find.byType(ProductTile).first);
      await tester.pump();

      await tester.tap(find.text('طباعة الفاتورة بعد الدفع'));
      await tester.pump();
      await tester.tap(find.text('ادفع 7.00 د.ل'));
      await tester.pumpAndSettle(const Duration(seconds: 1));
      await tester.tap(find.text('إضافة دفعة'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('payment_tender_amount_0')),
        '5.00',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('تأكيد الدفع'));
      await tester.tap(find.text('تأكيد الدفع'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(apiService.checkoutDrafts, hasLength(1));
      expect(apiService.checkoutDrafts.single.customerId, 12);
      expect(apiService.checkoutDrafts.single.lines.single.quantity, 2);
      expect(
        apiService.checkoutDrafts.single.payments.map(
          (payment) => payment.amount,
        ),
        [5, 2],
      );
      expect(apiService.printReports, 1);
      expect(
        find.text(
          'تم تسجيل البيع. رقم الإيصال: R-PILOT-1 تم إرسال الفاتورة للطابعة.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('حركات نقدية للدرج'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('سحب نقدية'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, '3.00');
      await tester.enterText(find.byType(TextFormField).last, 'شراء أكياس');
      await tester.tap(find.text('سحب نقدية'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(apiService.cashMovementDrafts.single.amount, 3);
      expect(apiService.cashMovementDrafts.single.reason, 'شراء أكياس');

      await tester.tap(find.byTooltip('إغلاق جلسة الدرج'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), '24.00');
      await tester.enterText(find.byType(TextFormField).at(1), '0');
      await tester.enterText(find.byType(TextFormField).at(2), '0');
      await tester.enterText(find.byType(TextFormField).at(3), '0');
      await tester.enterText(find.byType(TextFormField).at(4), '24');
      await tester.tap(find.text('إغلاق الجلسة'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(apiService.closeDraft?.closingCash, 24);
      expect(apiService.sessionIsOpen, isFalse);
      expect(find.text('جلسة الدرج'), findsOneWidget);

      await _openDrawerDestination(tester, 'التقارير');
      expect(find.text('التقارير'), findsWidgets);
      expect(find.text('أنواع التقارير'), findsOneWidget);
      expect(find.text('ملخص المبيعات'), findsWidgets);
    },
  );
}

void _setDesktopSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openDrawerDestination(WidgetTester tester, String label) async {
  Finder destination() => find.text(label);

  if (!tester.any(destination())) {
    await _expandNavigationGroups(tester, destination);
  }
  if (!tester.any(destination())) {
    final expandRail = find.byTooltip('توسيع التنقل');
    await tester.tap(
      tester.any(expandRail) ? expandRail : find.byTooltip('فتح القائمة'),
    );
    await tester.pumpAndSettle();
    await _expandNavigationGroups(tester, destination);
  }
  expect(destination(), findsWidgets);
  await tester.tap(destination().last);
  await tester.pumpAndSettle(const Duration(seconds: 1));
}

Future<void> _expandNavigationGroups(
  WidgetTester tester,
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
    final group = find.text(groupLabel);
    if (!tester.any(group)) {
      continue;
    }
    await tester.ensureVisible(group.first);
    await tester.pumpAndSettle();
    if (tester.any(destination())) {
      return;
    }
    await tester.tap(group.first);
    await tester.pumpAndSettle();
  }
}

class _PilotDayApiService extends PosApiService {
  _PilotDayApiService() : super();

  bool _sessionOpen = false;
  int _nextOrderId = 100;
  int printReports = 0;
  RegisterSessionCloseDraft? closeDraft;
  final checkoutDrafts = <SaleCheckoutDraft>[];
  final cashMovementDrafts = <RegisterCashMovementDraft>[];
  final orders = <SaleOrder>[];

  bool get sessionIsOpen => _sessionOpen;

  @override
  Future<PosUser?> fetchCurrentUser() async => _manager;

  @override
  Future<AnalyticsIngestResult> ingestAnalyticsEvents(
    List<AnalyticsEventDraft> events,
  ) async {
    return AnalyticsIngestResult(accepted: events.length, duplicates: 0);
  }

  @override
  Future<DashboardSnapshot> fetchDashboard({required int days}) async {
    return DashboardSnapshot.fromJson({
      'generated_at': '2026-05-23T09:00:00Z',
      'period': {
        'days': days,
        'start': '2026-05-01T00:00:00Z',
        'end': '2026-05-23T00:00:00Z',
        'previous_start': '2026-04-01T00:00:00Z',
        'previous_end': '2026-05-01T00:00:00Z',
      },
      'sections': <String, Object?>{},
    });
  }

  @override
  Future<ShopSettings> fetchShopSettings() async => ShopSettings.fromJson({
    'shop_name': 'متجر نقطة البيع',
    'receipt_header': 'أهلا بكم',
    'receipt_footer': 'شكرا لزيارتكم',
    'require_opening_cash': true,
    'auto_print_receipts': false,
    'allow_overselling': false,
    'low_stock_threshold': 5,
    'cashier_return_window_hours': 42,
    'enable_cash_payments': true,
    'enable_card_payments': true,
    'enable_transfer_payments': true,
    'require_card_payment_receipt': false,
    'trusted_card_terminal_ids': const [],
    'card_commission_percent': '1.00',
    'transfer_commission_percent': '0.00',
  });

  @override
  Future<RegisterSession?> fetchCurrentRegisterSession() async {
    return _sessionOpen ? _registerSession(openingCash: 20) : null;
  }

  @override
  Future<RegisterSession> startRegisterSession({
    required double openingCash,
  }) async {
    _sessionOpen = true;
    return _registerSession(openingCash: openingCash);
  }

  @override
  Future<RegisterSession> closeRegisterSession({
    required int sessionId,
    required RegisterSessionCloseDraft draft,
  }) async {
    closeDraft = draft;
    _sessionOpen = false;
    return _registerSession(
      status: 'closed',
      openingCash: 20,
      closingCash: draft.closingCash,
    );
  }

  @override
  Future<RegisterCashMovement> createRegisterCashMovement({
    required int sessionId,
    required RegisterCashMovementType movementType,
    required RegisterCashMovementDraft draft,
  }) async {
    cashMovementDrafts.add(draft);
    return RegisterCashMovement(
      id: cashMovementDrafts.length,
      registerSession: sessionId,
      movementType: movementType,
      amount: draft.amount,
      reason: draft.reason,
      sessionNumber: 'RS-PILOT',
      createdByUsername: 'manager',
      createdAt: DateTime.utc(2026, 5, 23, 9, 30),
    );
  }

  @override
  Future<RegisterCashMovementPage> fetchRegisterSessionCashMovements(
    int sessionId, {
    int page = 1,
  }) async {
    return const RegisterCashMovementPage(movements: [], hasMore: false);
  }

  @override
  Future<ProductPage> fetchProducts({
    required ModelQuery query,
    int page = 1,
  }) async {
    return const ProductPage(
      products: [_coffeeProduct, _teaProduct],
      hasMore: false,
    );
  }

  @override
  Future<CustomerPage> fetchCustomers({
    required ContactQuery query,
    int page = 1,
  }) async {
    return const CustomerPage(customers: [_customer], hasMore: false);
  }

  @override
  Future<SaleDiscountPreview> previewSaleDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    final subtotal = _draftSubtotal(draft.lines);
    return SaleDiscountPreview(
      subtotal: subtotal,
      discountTotal: 0,
      total: subtotal,
    );
  }

  @override
  Future<SaleOrder> checkout(SaleCheckoutDraft draft) async {
    checkoutDrafts.add(draft);
    final subtotal = _draftSubtotal(draft.lines);
    final order = SaleOrder(
      id: _nextOrderId++,
      receiptNumber: 'R-PILOT-1',
      status: 'paid',
      registerSession: 1,
      registerSessionNumber: 'RS-PILOT',
      customer: draft.customerId,
      customerName: draft.customerId == _customer.id
          ? _customer.fullName
          : null,
      lines: [
        for (var index = 0; index < draft.lines.length; index += 1)
          _orderLine(index: index, draft: draft.lines[index]),
      ],
      payments: [
        for (var index = 0; index < draft.payments.length; index += 1)
          SalePayment(
            id: index + 1,
            method: draft.payments[index].method,
            amount: draft.payments[index].amount,
            commissionPercent: 0,
            commissionAmount: 0,
          ),
      ],
      subtotal: subtotal,
      total: subtotal,
      canReturn: true,
      canVoid: true,
      invoicePrintJob: draft.invoicePrinterConfig == null
          ? null
          : _printJob(status: PrintJobStatus.claimed),
      createdAt: DateTime.utc(2026, 5, 23, 9, 20),
    );
    orders.insert(0, order);
    return order;
  }

  @override
  Future<PrintJob> reportPrintJob({
    required int jobId,
    required PrintJobReportDraft report,
  }) async {
    printReports += 1;
    return _printJob(status: report.status);
  }

  @override
  Future<RegisterSessionPage> fetchRegisterSessionHistory({
    int page = 1,
  }) async {
    return RegisterSessionPage(
      sessions: [
        _registerSession(status: 'closed', openingCash: 20, closingCash: 24),
      ],
      hasMore: false,
    );
  }

  @override
  Future<SaleOrderPage> fetchRegisterSessionOrders(
    int sessionId, {
    SaleOrderQuery query = const SaleOrderQuery(),
    int page = 1,
  }) async {
    return SaleOrderPage(orders: orders, hasMore: false);
  }

  @override
  Future<ReportRun> createReportRun(ReportRunDraft draft) async {
    return ReportRun(
      id: 1,
      reportType: draft.reportType,
      params: draft.params,
      outputFormat: draft.outputFormat,
      status: ReportRunStatus.success,
      payload: {
        'summary': {'net_sales': '7.00', 'order_count': 1},
        'sections': const [],
      },
      rowCount: 1,
      checksum: 'pilot',
      createdAt: DateTime.utc(2026, 5, 23, 9, 35),
      completedAt: DateTime.utc(2026, 5, 23, 9, 35),
    );
  }
}

const _manager = PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير النظام',
  role: UserRole.manager,
  isActive: true,
);

const _customer = Customer(
  id: 12,
  customerNumber: 'C-PILOT-12',
  fullName: 'ليلى أحمد',
  phone: '0910000000',
  email: '',
  gender: CustomerGender.female,
  marketingConsent: true,
  notes: '',
  isActive: true,
);

const _coffeeProduct = Product(
  id: 1,
  name: 'قهوة البيت',
  quantityOnHand: 30,
  defaultVariant: _coffeeVariant,
  variants: [_coffeeVariant],
);

const _coffeeVariant = ProductVariant(
  id: 1,
  productId: 1,
  productName: 'قهوة البيت',
  displayName: 'قهوة البيت',
  fullName: 'قهوة البيت',
  sku: 'COF-PILOT',
  barcode: '100000000001',
  unitPrice: 3.50,
  quantityOnHand: 30,
  isDefault: true,
);

const _teaProduct = Product(
  id: 2,
  name: 'شاي بالنعناع',
  quantityOnHand: 20,
  defaultVariant: _teaVariant,
  variants: [_teaVariant],
);

const _teaVariant = ProductVariant(
  id: 2,
  productId: 2,
  productName: 'شاي بالنعناع',
  displayName: 'شاي بالنعناع',
  fullName: 'شاي بالنعناع',
  sku: 'TEA-PILOT',
  barcode: '100000000002',
  unitPrice: 2.75,
  quantityOnHand: 20,
  isDefault: true,
);

RegisterSession _registerSession({
  String status = 'open',
  required double openingCash,
  double? closingCash,
}) {
  return RegisterSession(
    id: 1,
    sessionNumber: 'RS-PILOT',
    status: status,
    openingCash: openingCash,
    closingCash: closingCash,
    cashSalesTotal: 7,
    payOutTotal: 3,
    expectedCash: 24,
    openedAt: DateTime.utc(2026, 5, 23, 9),
    closedAt: status == 'closed' ? DateTime.utc(2026, 5, 23, 9, 40) : null,
    createdAt: DateTime.utc(2026, 5, 23, 9),
    updatedAt: DateTime.utc(2026, 5, 23, 9, 40),
  );
}

SaleOrderLine _orderLine({
  required int index,
  required SaleCheckoutLineDraft draft,
}) {
  final variant = draft.variantId == _coffeeVariant.id
      ? _coffeeVariant
      : _teaVariant;
  final subtotal = variant.unitPrice * draft.quantity;
  return SaleOrderLine(
    id: index + 1,
    productId: variant.productId,
    variantId: variant.id,
    productName: variant.productName,
    variantName: variant.displayName,
    quantity: draft.quantity,
    returnedQuantity: 0,
    returnableQuantity: draft.quantity,
    unitPrice: variant.unitPrice,
    subtotal: subtotal,
    total: subtotal,
  );
}

double _draftSubtotal(List<SaleCheckoutLineDraft> lines) {
  return lines.fold(0, (total, line) {
    final unitPrice = line.variantId == _coffeeVariant.id
        ? _coffeeVariant.unitPrice
        : _teaVariant.unitPrice;
    return total + unitPrice * line.quantity;
  });
}

PrintJob _printJob({required PrintJobStatus status}) {
  return PrintJob(
    id: 501,
    status: status,
    jobType: 'receipt',
    payload: const {'receipt_number': 'R-PILOT-1'},
    saleOrderId: 100,
    receiptNumber: 'R-PILOT-1',
    createdAt: DateTime.utc(2026, 5, 23, 9, 20),
    updatedAt: DateTime.utc(2026, 5, 23, 9, 20),
  );
}
