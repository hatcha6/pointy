// Dev-only preview harness for the redesigned purchase-order details screen
// and the flattened navigation drawer / rail.
//
// Renders the surfaces full-viewport with in-memory fakes and no backend/auth.
// Pick the surface with a `?screen=` query param and resize the browser to test
// responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/purchasing_preview.dart
//
// Screens:
//   po-draft | po-submitted | po-partial | po-received-due | po-complete |
//   po-cancelled | nav-drawer | nav-rail | nav-rail-collapsed
//
// Not part of the shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_order_list_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_order_details_screen.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_order_list_screen.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: _isDark() ? PointyTheme.dark() : PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _Router(),
    );
  }
}

bool _isDark() => Uri.base.queryParameters['theme'] == 'dark';

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'po-received-due';
}

class _Router extends StatelessWidget {
  const _Router();

  @override
  Widget build(BuildContext context) {
    switch (_screen()) {
      case 'po-draft':
        return _po(_draftOrder);
      case 'po-submitted':
        return _po(_submittedOrder);
      case 'po-partial':
        return _po(_partialOrder);
      case 'po-complete':
        return _po(_completeOrder);
      case 'po-cancelled':
        return _po(_cancelledOrder);
      case 'po-list':
        return _poList();
      case 'nav-drawer':
        return _navDrawer();
      case 'nav-rail':
        return _navRail(extended: true);
      case 'nav-rail-collapsed':
        return _navRail(extended: false);
      case 'po-received-due':
      default:
        return _po(_receivedDueOrder);
    }
  }
}

// ---------------------------------------------------------------------------
// Purchase-order details
// ---------------------------------------------------------------------------

Widget _po(PurchaseOrder order) {
  return PurchaseOrderDetailsScreen(
    purchaseRepository: _FakePurchaseRepository(order),
    printingRepository: PrintingRepository(PosApiService()),
    shopSettingsRepository: ShopSettingsRepository(PosApiService()),
    initialOrder: order,
    capabilities: _managerCaps,
  );
}

Widget _poList() {
  final repo = _FakeListPurchaseRepository(
    all: _allOrders,
    outstanding: _outstandingOrders,
  );
  return PurchaseOrderListScreen(
    viewModel: PurchaseOrderListViewModel(
      repo,
      PrintingRepository(PosApiService()),
      ShopSettingsRepository(PosApiService()),
    ),
    contactRepository: ContactRepository(PosApiService()),
    capabilities: _managerCaps,
    navigation: _FakeNavigation(),
    onCreatePurchaseOrder: () {},
    onOpenPurchaseOrder: (_) {},
    onEditPurchaseOrder: (_) {},
  );
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

Widget _navDrawer() {
  return Scaffold(
    backgroundColor: PointyColors.page,
    body: Row(
      children: [
        SizedBox(
          width: 320,
          child: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.purchasing,
            navigation: _FakeNavigation(),
          ),
        ),
        const Expanded(child: Center(child: Text('المحتوى'))),
      ],
    ),
  );
}

Widget _navRail({required bool extended}) {
  return PointyNavigationRailScope(
    isActive: true,
    controller: PointyNavigationRailController(isExpanded: extended),
    child: PointyScaffold(
      drawer: AppNavigationDrawer(
        selectedDestination: AppNavigationDestination.purchasing,
        navigation: _FakeNavigation(),
      ),
      appBar: PointyAppBar(
        leading: const PointyNavigationMenuButton(),
        title: const Text('المشتريات'),
      ),
      body: const Center(child: Text('المحتوى')),
    ),
  );
}

// ---------------------------------------------------------------------------
// Fakes & fixtures
// ---------------------------------------------------------------------------

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);

class _FakeNavigation implements AppNavigation {
  _FakeNavigation();

  @override
  final AuthorizationCapabilities capabilities = _managerCaps;
  @override
  final PosUser currentUser = _managerUser;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository(this._order) : super(PosApiService());

  final PurchaseOrder _order;

  @override
  Future<Result<PurchaseOrder>> loadPurchaseOrder(int purchaseOrderId) async {
    return Ok(_order);
  }
}

class _FakeListPurchaseRepository extends PurchaseRepository {
  _FakeListPurchaseRepository({required this.all, required this.outstanding})
    : super(PosApiService());

  final List<PurchaseOrder> all;
  final List<PurchaseOrder> outstanding;

  @override
  Future<Result<PurchaseOrderPage>> loadPurchaseOrders({
    required PurchaseOrderQuery query,
    int page = 1,
  }) async {
    final status = switch (query.status) {
      PurchaseOrderStatusFilter.draft => 'draft',
      PurchaseOrderStatusFilter.submitted => 'submitted',
      PurchaseOrderStatusFilter.received => 'received',
      PurchaseOrderStatusFilter.cancelled => 'cancelled',
      PurchaseOrderStatusFilter.all => null,
    };
    final filtered = status == null
        ? all
        : all.where((o) => o.status == status).toList();
    return Ok(PurchaseOrderPage(orders: filtered, hasMore: false));
  }

  @override
  Future<Result<PurchaseOrderPage>> loadOutstandingReceivedNotPaid({
    int page = 1,
  }) async {
    return Ok(PurchaseOrderPage(orders: outstanding, hasMore: false));
  }

  @override
  Future<Result<PurchaseOrder>> loadPurchaseOrder(int purchaseOrderId) async {
    return Ok(all.firstWhere((o) => o.id == purchaseOrderId));
  }
}

PurchaseOrderLine _line({
  required int id,
  required String name,
  String? sku,
  required double quantity,
  double received = 0,
  double damaged = 0,
  required double unitCost,
}) {
  final open = quantity - received - damaged;
  return PurchaseOrderLine(
    id: id,
    productId: id,
    variantId: 0,
    quantity: quantity,
    adjustedQuantity: 0,
    adjustableQuantity: received,
    receivedQuantity: received,
    damagedQuantity: damaged,
    rejectedQuantity: 0,
    openQuantity: open < 0 ? 0 : open,
    hasReceivingTotals: received > 0 || damaged > 0,
    unitCost: unitCost,
    total: quantity * unitCost,
    productName: name,
    variantSku: sku,
  );
}

PurchaseOrder _order({
  required int id,
  required String number,
  required String status,
  required List<PurchaseOrderLine> lines,
  double paid = 0,
  bool paidInFull = false,
  String paymentStatus = '',
  DateTime? dueDate,
  bool isOverdue = false,
  bool canReturn = false,
  bool canRefund = false,
  bool canExchange = false,
  DateTime? createdAt,
  DateTime? submittedAt,
  DateTime? receivedAt,
  String supplierInvoiceNumber = '',
}) {
  final subtotal = lines.fold<double>(0, (sum, l) => sum + l.total);
  final paidTotal = paidInFull ? subtotal : paid;
  return PurchaseOrder(
    id: id,
    orderNumber: number,
    status: status,
    lineCount: lines.length,
    total: subtotal,
    subtotal: subtotal,
    lines: lines,
    adjustments: const [],
    receipts: const [],
    canReturn: canReturn,
    canRefund: canRefund,
    canExchange: canExchange,
    supplierId: 1,
    supplierName: 'مؤسسة النور للتوريدات',
    paidTotal: paidTotal,
    balanceDue: subtotal - paidTotal,
    paymentStatus: paymentStatus,
    dueDate: dueDate,
    isOverdue: isOverdue,
    createdAt: createdAt,
    submittedAt: submittedAt,
    receivedAt: receivedAt,
    supplierInvoiceNumber: supplierInvoiceNumber,
  );
}

final List<PurchaseOrderLine> _sampleLines = [
  _line(
    id: 1,
    name: 'قهوة عربية محمصة',
    sku: 'COF-001',
    quantity: 24,
    unitCost: 18.5,
  ),
  _line(
    id: 2,
    name: 'أكواب ورقية مزدوجة',
    sku: 'CUP-220',
    quantity: 50,
    unitCost: 2.25,
  ),
  _line(id: 3, name: 'حليب مكثف', sku: 'MLK-010', quantity: 12, unitCost: 6.75),
];

List<PurchaseOrderLine> _receivedLines({required bool full}) => [
  _line(
    id: 1,
    name: 'قهوة عربية محمصة',
    sku: 'COF-001',
    quantity: 24,
    received: full ? 24 : 18,
    unitCost: 18.5,
  ),
  _line(
    id: 2,
    name: 'أكواب ورقية مزدوجة',
    sku: 'CUP-220',
    quantity: 50,
    received: full ? 50 : 30,
    damaged: full ? 0 : 2,
    unitCost: 2.25,
  ),
  _line(
    id: 3,
    name: 'حليب مكثف',
    sku: 'MLK-010',
    quantity: 12,
    received: 12,
    unitCost: 6.75,
  ),
];

final PurchaseOrder _draftOrder = _order(
  id: 1041,
  number: 'PO-1041',
  status: 'draft',
  lines: _sampleLines,
  createdAt: DateTime(2026, 6, 20, 10, 15),
);

final PurchaseOrder _submittedOrder = _order(
  id: 1042,
  number: 'PO-1042',
  status: 'submitted',
  lines: _sampleLines,
  paid: 200,
  paymentStatus: 'partial',
  dueDate: DateTime(2026, 7, 5),
  createdAt: DateTime(2026, 6, 18, 9, 0),
  submittedAt: DateTime(2026, 6, 18, 11, 30),
  supplierInvoiceNumber: 'INV-5521',
);

final PurchaseOrder _partialOrder = _order(
  id: 1043,
  number: 'PO-1043',
  status: 'partial',
  lines: _receivedLines(full: false),
  paid: 300,
  paymentStatus: 'partial',
  dueDate: DateTime(2026, 6, 28),
  canReturn: true,
  createdAt: DateTime(2026, 6, 15, 8, 0),
  submittedAt: DateTime(2026, 6, 15, 12, 0),
  supplierInvoiceNumber: 'INV-5522',
);

final PurchaseOrder _receivedDueOrder = _order(
  id: 1044,
  number: 'PO-1044',
  status: 'received',
  lines: _receivedLines(full: true),
  paid: 250,
  paymentStatus: 'partial',
  dueDate: DateTime(2026, 6, 19),
  isOverdue: true,
  canReturn: true,
  canRefund: true,
  canExchange: true,
  createdAt: DateTime(2026, 6, 12, 8, 0),
  submittedAt: DateTime(2026, 6, 12, 12, 0),
  receivedAt: DateTime(2026, 6, 17, 14, 20),
  supplierInvoiceNumber: 'INV-5523',
);

final PurchaseOrder _completeOrder = _order(
  id: 1045,
  number: 'PO-1045',
  status: 'received',
  lines: _receivedLines(full: true),
  paymentStatus: 'paid',
  paidInFull: true,
  createdAt: DateTime(2026, 6, 10, 8, 0),
  submittedAt: DateTime(2026, 6, 10, 12, 0),
  receivedAt: DateTime(2026, 6, 14, 14, 20),
  supplierInvoiceNumber: 'INV-5524',
);

final PurchaseOrder _cancelledOrder = _order(
  id: 1046,
  number: 'PO-1046',
  status: 'cancelled',
  lines: _sampleLines,
  createdAt: DateTime(2026, 6, 9, 8, 0),
);

final PurchaseOrder _receivedDueOrder2 = _order(
  id: 1047,
  number: 'PO-1047',
  status: 'received',
  lines: _receivedLines(full: true),
  paid: 100,
  paymentStatus: 'partial',
  dueDate: DateTime(2026, 7, 2),
  receivedAt: DateTime(2026, 6, 16, 9, 30),
  supplierInvoiceNumber: 'INV-5530',
);

final PurchaseOrder _receivedDueOrder3 = _order(
  id: 1048,
  number: 'PO-1048',
  status: 'received',
  lines: _sampleLines,
  dueDate: DateTime(2026, 6, 17),
  isOverdue: true,
  receivedAt: DateTime(2026, 6, 13, 16, 0),
  supplierInvoiceNumber: 'INV-5531',
);

final List<PurchaseOrder> _allOrders = [
  _draftOrder,
  _submittedOrder,
  _partialOrder,
  _receivedDueOrder,
  _receivedDueOrder2,
  _receivedDueOrder3,
  _completeOrder,
  _cancelledOrder,
];

final List<PurchaseOrder> _outstandingOrders = [
  _receivedDueOrder3,
  _receivedDueOrder,
  _receivedDueOrder2,
];
