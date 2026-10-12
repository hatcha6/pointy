// Renders the invoices and purchase-order lists to PNG, headlessly.
//
// Skipped by an ordinary `flutter test`. Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/document_lists_capture_test.dart --update-goldens
//
// The PNGs land in test/screens/goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/register_cash_movement.dart';
import 'package:pointy_frontend/src/data/models/register_cash_movement_page.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/register_session_page.dart';
import 'package:pointy_frontend/src/data/models/register_session_summary.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/sale_order_page.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/invoices/view_models/invoice_list_view_model.dart';
import 'package:pointy_frontend/src/features/invoices/views/invoice_list_screen.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_order_list_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_order_list_screen.dart';
import 'package:pointy_frontend/src/features/register_sessions/view_models/register_session_history_view_model.dart';
import 'package:pointy_frontend/src/features/register_sessions/views/register_session_history_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import '../shared/fake_app_navigation.dart';

final bool _capture = Platform.environment['POINTY_CAPTURE_SCREENS'] == '1';

const Size kPhone = Size(430, 1200);
const Size kWide = Size(1280, 1000);

final PosUser _user = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'display_name': 'مدير النظام',
  'email': '',
  'role': 'manager',
  'permissions': <String>[],
  'is_active': true,
});

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
  });

  Future<void> shoot(
    WidgetTester tester, {
    required Size size,
    required Widget child,
    required String name,
    bool dark = false,
    Future<void> Function(WidgetTester tester)? after,
  }) async {
    debugDisableShadows = false;
    const ratio = 2.0;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = size * ratio;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: dark ? PointyTheme.dark() : PointyTheme.light(),
        builder: (context, inner) => PointyNavigationRailScope(
          isActive: false,
          controller: PointyNavigationRailController(),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: child,
      ),
    );
    await tester.pumpAndSettle();
    if (after != null) {
      await after(tester);
      await tester.pumpAndSettle();
    }
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/$name.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  Widget invoices() {
    final caps = AuthorizationCapabilities.forUser(_user);
    return InvoiceListScreen(
      viewModel: InvoiceListViewModel(
        _FakeSaleRepository(),
        PrintingRepository(PosApiService()),
        ShopSettingsRepository(PosApiService()),
      ),
      contactRepository: ContactRepository(PosApiService()),
      userRepository: UserRepository(PosApiService()),
      capabilities: caps,
      onOpenInvoice: (_) {},
      navigation: FakeAppNavigation(currentUser: _user),
    );
  }

  Widget purchaseOrders() {
    final caps = AuthorizationCapabilities.forUser(_user);
    return PurchaseOrderListScreen(
      viewModel: PurchaseOrderListViewModel(
        _FakePurchaseRepository(),
        PrintingRepository(PosApiService()),
        ShopSettingsRepository(PosApiService()),
      ),
      contactRepository: ContactRepository(PosApiService()),
      capabilities: caps,
      navigation: FakeAppNavigation(currentUser: _user),
      onCreatePurchaseOrder: () {},
      onOpenPurchaseOrder: (_) {},
      onEditPurchaseOrder: (_) {},
    );
  }

  Widget registerSessions({bool select = false}) {
    final viewModel = RegisterSessionHistoryViewModel(
      _FakeRegisterSessionRepository(),
      _FakeSaleRepository(),
      printingRepository: PrintingRepository(PosApiService()),
      shopSettingsRepository: ShopSettingsRepository(PosApiService()),
    );
    if (select) {
      viewModel.selectSession(_sessions.first);
    }
    return RegisterSessionHistoryScreen(
      viewModel: viewModel,
      contactRepository: ContactRepository(PosApiService()),
      capabilities: AuthorizationCapabilities.forUser(_user),
      navigation: FakeAppNavigation(currentUser: _user),
    );
  }

  testWidgets('register sessions', (tester) async {
    await shoot(
      tester,
      size: kPhone,
      child: registerSessions(),
      name: 'register_sessions_phone',
    );
    await shoot(
      tester,
      size: kWide,
      child: registerSessions(select: true),
      name: 'register_sessions_wide_sales',
      after: (tester) => tester.tap(find.text('المبيعات').last),
    );
    await shoot(
      tester,
      size: kWide,
      child: registerSessions(select: true),
      name: 'register_sessions_wide_cash',
      after: (tester) => tester.tap(find.text('حركات النقد').last),
    );
  }, skip: !_capture);

  testWidgets('invoices list', (tester) async {
    await shoot(
      tester,
      size: kPhone,
      child: invoices(),
      name: 'invoices_phone',
    );
    await shoot(tester, size: kWide, child: invoices(), name: 'invoices_wide');
  }, skip: !_capture);

  testWidgets('purchase orders list', (tester) async {
    await shoot(
      tester,
      size: kPhone,
      child: purchaseOrders(),
      name: 'purchase_orders_phone',
    );
    await shoot(
      tester,
      size: kWide,
      child: purchaseOrders(),
      name: 'purchase_orders_wide',
    );
    await shoot(
      tester,
      size: kWide,
      child: purchaseOrders(),
      name: 'purchase_orders_wide_dark',
      dark: true,
    );
  }, skip: !_capture);
}

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository() : super(PosApiService());

  @override
  Future<Result<SaleOrderPage>> loadOrdersForSession(
    int sessionId, {
    SaleOrderQuery query = const SaleOrderQuery(),
    String? cursor,
  }) async {
    return Ok(
      SaleOrderPage(orders: _invoices.take(4).toList(), hasMore: false),
    );
  }

  @override
  Future<Result<SaleOrderPage>> loadOrders({
    SaleOrderQuery query = const SaleOrderQuery(),
    int page = 1,
  }) async {
    return Ok(SaleOrderPage(orders: _invoices, hasMore: false));
  }
}

SaleOrder _invoice({
  required int id,
  required String number,
  required String status,
  required String total,
  String? customer,
  String balance = '0.00',
  String? profit,
  int lines = 3,
  String cashier = 'بحر',
  String session = 'S-0142',
  String? dueDate,
  bool overdue = false,
  int daysOverdue = 0,
  String saleType = 'standard',
  required String createdAt,
}) {
  return SaleOrder.fromJson({
    'id': id,
    'receipt_number': number,
    'status': status,
    'sale_type': saleType,
    'subtotal': total,
    'total': total,
    'balance_due': balance,
    'payment_status': status == 'paid' ? 'paid' : 'unpaid',
    'payments': const <Object?>[],
    'line_count': lines,
    'customer_name': ?customer,
    'cashier_name': cashier,
    'register_session_number': session,
    'total_profit': ?profit,
    'due_date': ?dueDate,
    'is_overdue': overdue,
    'days_overdue': daysOverdue,
    'created_at': createdAt,
  });
}

final List<SaleOrder> _invoices = [
  _invoice(
    id: 1,
    number: 'R20261012000231',
    status: 'paid',
    total: '245.50',
    customer: 'أحمد محمد الفيتوري',
    profit: '48.20',
    lines: 6,
    createdAt: '2026-10-12T14:32:00',
  ),
  _invoice(
    id: 2,
    number: 'R20261012000230',
    status: 'paid',
    total: '18.00',
    profit: '4.50',
    lines: 1,
    createdAt: '2026-10-12T14:05:00',
  ),
  _invoice(
    id: 3,
    number: 'R20261011000219',
    status: 'open',
    saleType: 'credit',
    total: '1250.00',
    balance: '750.00',
    customer: 'سوبر ماركت الواحة',
    profit: '210.00',
    lines: 14,
    dueDate: '2026-10-05',
    overdue: true,
    daysOverdue: 7,
    createdAt: '2026-10-11T11:20:00',
  ),
  _invoice(
    id: 4,
    number: 'R20261011000214',
    status: 'open',
    saleType: 'credit',
    total: '480.00',
    balance: '480.00',
    customer: 'مقهى البحر',
    lines: 4,
    dueDate: '2026-10-25',
    cashier: 'سالم',
    createdAt: '2026-10-11T09:47:00',
  ),
  _invoice(
    id: 5,
    number: 'R20261010000198',
    status: 'void',
    total: '62.00',
    customer: 'خالد عمر',
    lines: 2,
    createdAt: '2026-10-10T18:12:00',
  ),
  _invoice(
    id: 6,
    number: 'R20261010000197',
    status: 'paid',
    total: '3120.75',
    customer: 'شركة الأفق للتجارة العامة والتوريدات',
    profit: '402.10',
    lines: 22,
    cashier: 'سالم',
    createdAt: '2026-10-10T16:01:00',
  ),
];

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  @override
  Future<Result<PurchaseOrderPage>> loadPurchaseOrders({
    required PurchaseOrderQuery query,
    int page = 1,
  }) async {
    return Ok(PurchaseOrderPage(orders: _orders, hasMore: false));
  }

  @override
  Future<Result<PurchaseOrderPage>> loadOutstandingReceivedNotPaid({
    int page = 1,
  }) async {
    return Ok(
      PurchaseOrderPage(
        orders: _orders
            .where((o) => o.balanceDue > 0 && o.status == 'received')
            .toList(),
        hasMore: false,
      ),
    );
  }
}

PurchaseOrder _po({
  required int id,
  required String number,
  required String status,
  required double total,
  required String supplier,
  double paid = 0,
  String paymentStatus = '',
  int lines = 5,
  DateTime? dueDate,
  bool overdue = false,
  String supplierInvoice = '',
  DateTime? supplierInvoiceDate,
  required DateTime createdAt,
  DateTime? receivedAt,
}) {
  return PurchaseOrder(
    id: id,
    orderNumber: number,
    status: status,
    lineCount: lines,
    total: total,
    subtotal: total,
    lines: const [],
    adjustments: const [],
    receipts: const [],
    canReturn: false,
    canRefund: false,
    canExchange: false,
    supplierId: id,
    supplierName: supplier,
    paidTotal: paid,
    balanceDue: total - paid,
    paymentStatus: paymentStatus,
    dueDate: dueDate,
    isOverdue: overdue,
    createdAt: createdAt,
    receivedAt: receivedAt,
    supplierInvoiceNumber: supplierInvoice,
    supplierInvoiceDate: supplierInvoiceDate,
  );
}

final List<PurchaseOrder> _orders = [
  _po(
    id: 1,
    number: 'PO-2026-0412',
    status: 'draft',
    total: 860,
    supplier: 'مؤسسة النور للتوريدات',
    lines: 8,
    createdAt: DateTime(2026, 10, 12, 10, 15),
  ),
  _po(
    id: 2,
    number: 'PO-2026-0411',
    status: 'submitted',
    total: 2340,
    supplier: 'شركة المدار للمواد الغذائية',
    paymentStatus: 'unpaid',
    lines: 15,
    createdAt: DateTime(2026, 10, 11, 13, 40),
  ),
  _po(
    id: 3,
    number: 'PO-2026-0408',
    status: 'received',
    total: 4180.5,
    paid: 1500,
    supplier: 'الوطنية للمشروبات',
    paymentStatus: 'partial',
    lines: 11,
    dueDate: DateTime(2026, 10, 1),
    overdue: true,
    supplierInvoice: 'INV-5531',
    supplierInvoiceDate: DateTime(2026, 9, 24),
    createdAt: DateTime(2026, 9, 22),
    receivedAt: DateTime(2026, 9, 24, 16, 0),
  ),
  _po(
    id: 4,
    number: 'PO-2026-0405',
    status: 'received',
    total: 975,
    supplier: 'مخابز الأصيل',
    paymentStatus: 'unpaid',
    lines: 3,
    dueDate: DateTime(2026, 10, 20),
    supplierInvoice: 'A-2207',
    createdAt: DateTime(2026, 10, 2),
    receivedAt: DateTime(2026, 10, 3, 9, 30),
  ),
  _po(
    id: 5,
    number: 'PO-2026-0399',
    status: 'received',
    total: 1620,
    paid: 1620,
    supplier: 'مؤسسة النور للتوريدات',
    paymentStatus: 'paid',
    lines: 9,
    supplierInvoice: 'INV-5488',
    createdAt: DateTime(2026, 9, 18),
    receivedAt: DateTime(2026, 9, 19, 11, 0),
  ),
  _po(
    id: 6,
    number: 'PO-2026-0395',
    status: 'cancelled',
    total: 300,
    supplier: 'شركة المدار للمواد الغذائية',
    lines: 2,
    createdAt: DateTime(2026, 9, 15),
  ),
];

class _FakeRegisterSessionRepository extends RegisterSessionRepository {
  _FakeRegisterSessionRepository() : super(PosApiService());

  @override
  Future<Result<RegisterSessionPage>> loadSessionHistory({
    String? cursor,
  }) async {
    return Ok(RegisterSessionPage(sessions: _sessions, hasMore: false));
  }

  @override
  Future<Result<RegisterSessionSummary>> loadSessionSummary(
    int sessionId,
  ) async {
    return Error(Exception('not in this capture'));
  }

  @override
  Future<Result<RegisterCashMovementPage>> loadCashMovementsForSession(
    int sessionId, {
    String? cursor,
  }) async {
    return Ok(
      RegisterCashMovementPage(
        movements: [
          RegisterCashMovement(
            id: 1,
            registerSession: sessionId,
            movementType: RegisterCashMovementType.payOut,
            amount: 35,
            reason: 'شراء ماء للمحل',
            createdAt: DateTime(2026, 10, 12, 11, 5),
          ),
          RegisterCashMovement(
            id: 2,
            registerSession: sessionId,
            movementType: RegisterCashMovementType.payIn,
            amount: 100,
            reason: 'فكة من الخزينة',
            createdAt: DateTime(2026, 10, 12, 9, 40),
          ),
        ],
        hasMore: false,
      ),
    );
  }
}

final List<RegisterSession> _sessions = [
  RegisterSession.fromJson(const {
    'id': 1,
    'session_number': 'S-0143',
    'status': 'open',
    'owner_name': 'بحر',
    'opening_cash': '150.00',
    'opened_at': '2026-10-12T08:02:00',
  }),
  RegisterSession.fromJson(const {
    'id': 2,
    'session_number': 'S-0142',
    'status': 'closed',
    'owner_name': 'سالم',
    'opening_cash': '150.00',
    'closing_cash': '1838.50',
    'cash_variance': '-12.00',
    'has_cash_variance': true,
    'opened_at': '2026-10-11T08:00:00',
    'closed_at': '2026-10-11T22:14:00',
  }),
  RegisterSession.fromJson(const {
    'id': 3,
    'session_number': 'S-0141',
    'status': 'closed',
    'owner_name': 'بحر',
    'opening_cash': '150.00',
    'closing_cash': '2104.00',
    'cash_variance': '0.00',
    'has_cash_variance': false,
    'opened_at': '2026-10-10T08:05:00',
    'closed_at': '2026-10-10T21:50:00',
  }),
  RegisterSession.fromJson(const {
    'id': 4,
    'session_number': 'S-0140',
    'status': 'closed',
    'owner_name': 'منى',
    'opening_cash': '100.00',
    'closing_cash': '965.25',
    'cash_variance': '5.25',
    'has_cash_variance': true,
    'opened_at': '2026-10-09T15:00:00',
    'closed_at': '2026-10-10T01:30:00',
  }),
];
