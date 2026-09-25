// Dev-only preview harness for the register-session summary panel + Z-Report.
//
// Renders the real `SessionOrders` widget (manager view: summary / sales / cash
// tabs) against fake repositories that return a canned all-payment-methods
// summary — no backend, no auth. The first tab shows the new breakdown (sales
// totals, per-method, by-category, cash reconciliation) and the Z-Report print
// actions.
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/register_session_preview.dart
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the shipping
// app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/register_cash_movement_page.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/register_session_page.dart';
import 'package:pointy_frontend/src/data/models/register_session_summary.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/sale_order_page.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/register_sessions/view_models/register_session_history_view_model.dart';
import 'package:pointy_frontend/src/features/register_sessions/views/session_orders.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

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
      theme: PointyTheme.light(),
      home: const _SummarySurface(),
    );
  }
}

class _SummarySurface extends StatefulWidget {
  const _SummarySurface();

  @override
  State<_SummarySurface> createState() => _SummarySurfaceState();
}

class _SummarySurfaceState extends State<_SummarySurface> {
  late final RegisterSessionHistoryViewModel _viewModel;
  final ContactRepository _contacts = _FakeContactRepository();

  @override
  void initState() {
    super.initState();
    _viewModel = RegisterSessionHistoryViewModel(
      _FakeRegisterSessionRepository(),
      _FakeSaleRepository(),
      printingRepository: PrintingRepository(PosApiService()),
      shopSettingsRepository: _FakeShopSettingsRepository(),
    );
    // Select the demo session so the summary tab is populated immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewModel.selectSession(_demoSession);
    });
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.registerSessionHistoryTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListenableBuilder(
            listenable: _viewModel,
            builder: (context, _) {
              return SessionOrders(
                viewModel: _viewModel,
                contactRepository: _contacts,
                capabilities: _managerCaps,
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Demo data
// ---------------------------------------------------------------------------

const RegisterSession _demoSession = RegisterSession(
  id: 7,
  sessionNumber: 'RS-7',
  status: 'closed',
  openingCash: 50,
  closingCash: 104,
  expectedCash: 105,
  cashVariance: -1,
  hasCashVariance: true,
);

final RegisterSessionSummary _demoSummary = RegisterSessionSummary(
  sessionId: 7,
  sessionNumber: 'RS-7',
  status: 'closed',
  ownerName: 'منى',
  openedAt: DateTime(2026, 6, 24, 8),
  closedAt: DateTime(2026, 6, 24, 20),
  sales: const SessionSalesTotals(
    grossSales: 120,
    discountTotal: 5,
    netSales: 110,
    orderCount: 8,
    voidCount: 1,
    itemsSold: '23',
  ),
  refunds: const SessionRefundTotals(
    refundTotal: 5,
    returnCount: 1,
    cashRefundTotal: 5,
  ),
  paymentMethods: const [
    PaymentMethodBreakdown(
      method: 'cash',
      gross: 60,
      commission: 0,
      refund: 5,
      net: 55,
      count: 5,
    ),
    PaymentMethodBreakdown(
      method: 'card',
      gross: 40,
      commission: 1.2,
      refund: 0,
      net: 40,
      count: 2,
    ),
    PaymentMethodBreakdown(
      method: 'transfer',
      gross: 15,
      commission: 0,
      refund: 0,
      net: 15,
      count: 1,
    ),
  ],
  paymentTotals: const PaymentMethodTotals(
    gross: 115,
    commission: 1.2,
    refund: 5,
    net: 110,
    count: 8,
  ),
  cardReceipts: const CardReceiptTotals(
    gross: 4000,
    verified: 2000,
    pending: 1000,
    flagged: 500,
    unavailable: 0,
    noReceipt: 500,
    pendingCount: 2,
    flaggedCount: 1,
  ),
  categories: const [
    CategoryBreakdown(category: 'مشروبات', quantity: '12', net: 60),
    CategoryBreakdown(category: 'وجبات', quantity: '5', net: 38),
    CategoryBreakdown(category: null, quantity: '2', net: 12),
  ],
  cash: const SessionCashSummary(
    openingCash: 50,
    cashSalesTotal: 60,
    payInTotal: 0,
    payOutTotal: 0,
    cashRefundTotal: 5,
    expectedCash: 105,
    closingCash: 104,
    cashVariance: -1,
    hasCashVariance: true,
    denominationTotal: 4,
    denominations: [
      DenominationCount(value: '0.25', count: 4),
      DenominationCount(value: '0.50', count: 2),
      DenominationCount(value: '0.75', count: 0),
      DenominationCount(value: '1.00', count: 2),
    ],
  ),
  expenses: const SessionExpenseTotals(total: 12.5, count: 2),
  drawerPurchases: const SessionExpenseTotals(total: 21, count: 1),
  integrations: _demoIntegrations,
);

// A shift at an agency that resells all three providers, with one of every
// way provider money goes astray: an HD Box renewal refused for an empty
// float, an LNET top-up sent with no answer, and an HD Box renewal refunded
// after HD Box had performed it.
final SessionIntegrations _demoIntegrations = SessionIntegrations(
  providers: const [
    SessionIntegrationFigures(
      provider: 'hdbox',
      count: 3,
      sold: 350,
      cost: 310,
      margin: 40,
      delivered: SessionIntegrationBucketTotals(
        count: 2,
        amount: 270,
        cost: 245,
      ),
      awaiting: SessionIntegrationBucketTotals(count: 1, amount: 80, cost: 65),
      unknown: SessionIntegrationBucketTotals.empty,
      refunded: SessionIntegrationBucketTotals(count: 1, amount: 30, cost: 25),
      refundedAfterDelivery: SessionIntegrationBucketTotals(
        count: 1,
        amount: 0,
        cost: 25,
      ),
    ),
    SessionIntegrationFigures(
      provider: 'lnet',
      count: 3,
      sold: 120,
      cost: 114,
      margin: 6,
      delivered: SessionIntegrationBucketTotals(
        count: 2,
        amount: 75,
        cost: 71.25,
      ),
      awaiting: SessionIntegrationBucketTotals.empty,
      unknown: SessionIntegrationBucketTotals(
        count: 1,
        amount: 45,
        cost: 42.75,
      ),
      refunded: SessionIntegrationBucketTotals.empty,
      refundedAfterDelivery: SessionIntegrationBucketTotals.empty,
    ),
    SessionIntegrationFigures(
      provider: 'qareeb',
      count: 2,
      sold: 30,
      cost: 29.1,
      margin: 0.9,
      delivered: SessionIntegrationBucketTotals(
        count: 2,
        amount: 30,
        cost: 29.1,
      ),
      awaiting: SessionIntegrationBucketTotals.empty,
      unknown: SessionIntegrationBucketTotals.empty,
      refunded: SessionIntegrationBucketTotals.empty,
      refundedAfterDelivery: SessionIntegrationBucketTotals.empty,
    ),
  ],
  totals: const SessionIntegrationFigures(
    count: 8,
    sold: 500,
    cost: 453.1,
    margin: 46.9,
    delivered: SessionIntegrationBucketTotals(
      count: 6,
      amount: 375,
      cost: 345.35,
    ),
    awaiting: SessionIntegrationBucketTotals(count: 1, amount: 80, cost: 65),
    unknown: SessionIntegrationBucketTotals(count: 1, amount: 45, cost: 42.75),
    refunded: SessionIntegrationBucketTotals(count: 1, amount: 30, cost: 25),
    refundedAfterDelivery: SessionIntegrationBucketTotals(
      count: 1,
      amount: 0,
      cost: 25,
    ),
  ),
  transactions: [
    _demoTransaction(
      1,
      'hdbox',
      '09:12',
      'R-00041',
      '210906803499',
      'تجديد 12 شهر',
      240,
      220,
      'confirmed',
      SessionIntegrationBucket.delivered,
      label: 'أحمد الورفلي',
      reference: '558032',
    ),
    _demoTransaction(
      2,
      'lnet',
      '09:40',
      'R-00042',
      'basheir',
      'شحن 30 د.ل',
      30,
      28.5,
      'confirmed',
      SessionIntegrationBucket.delivered,
    ),
    _demoTransaction(
      3,
      'qareeb',
      '10:05',
      'R-00043',
      '',
      'ليبيانا 10 دينار',
      10,
      9.7,
      'confirmed',
      SessionIntegrationBucket.delivered,
    ),
    _demoTransaction(
      4,
      'hdbox',
      '11:30',
      'R-00046',
      '210906801122',
      'تجديد 3 أشهر',
      80,
      65,
      'pending',
      SessionIntegrationBucket.awaiting,
      errorCode: 'insufficient_float',
    ),
    _demoTransaction(
      5,
      'lnet',
      '12:02',
      'R-00047',
      'salem.shop',
      'شحن 45 د.ل',
      45,
      42.75,
      'submitted',
      SessionIntegrationBucket.unknown,
    ),
    _demoTransaction(
      6,
      'hdbox',
      '13:15',
      'R-00049',
      '210906807788',
      'تجديد شهر',
      30,
      25,
      'confirmed',
      SessionIntegrationBucket.refunded,
      refunded: 30,
    ),
    _demoTransaction(
      7,
      'hdbox',
      '14:40',
      'R-00052',
      '210906809900',
      'تجديد شهر',
      30,
      25,
      'confirmed',
      SessionIntegrationBucket.delivered,
    ),
    _demoTransaction(
      8,
      'lnet',
      '15:20',
      'R-00055',
      'omar77',
      'شحن 45 د.ل',
      45,
      42.75,
      'confirmed',
      SessionIntegrationBucket.delivered,
    ),
    _demoTransaction(
      9,
      'qareeb',
      '16:45',
      'R-00058',
      '',
      'المدار 20 دينار',
      20,
      19.4,
      'confirmed',
      SessionIntegrationBucket.delivered,
    ),
  ],
);

SessionIntegrationTransaction _demoTransaction(
  int id,
  String provider,
  String time,
  String receipt,
  String ref,
  String option,
  double price,
  double cost,
  String status,
  SessionIntegrationBucket bucket, {
  String label = '',
  String reference = '',
  String errorCode = '',
  double refunded = 0,
}) {
  final parts = time.split(':');
  return SessionIntegrationTransaction(
    id: id,
    provider: provider,
    kind: provider == 'qareeb' ? 'voucher' : 'recharge',
    orderId: 100 + id,
    receiptNumber: receipt,
    soldAt: DateTime(2026, 6, 24, int.parse(parts[0]), int.parse(parts[1])),
    subscriberRef: ref,
    subscriberLabel: label,
    optionLabel: option,
    price: price,
    cost: cost,
    refundedAmount: refunded,
    status: status,
    bucket: bucket,
    errorCode: errorCode,
    providerReference: reference,
  );
}

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeRegisterSessionRepository extends RegisterSessionRepository {
  _FakeRegisterSessionRepository() : super(PosApiService());

  @override
  Future<Result<RegisterSessionPage>> loadSessionHistory({
    String? cursor,
  }) async {
    return Ok(
      RegisterSessionPage(sessions: const [_demoSession], hasMore: false),
    );
  }

  @override
  Future<Result<RegisterSessionSummary>> loadSessionSummary(
    int sessionId,
  ) async {
    return Ok(_demoSummary);
  }

  @override
  Future<Result<RegisterCashMovementPage>> loadCashMovementsForSession(
    int sessionId, {
    String? cursor,
  }) async {
    return const Ok(RegisterCashMovementPage(movements: [], hasMore: false));
  }
}

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository() : super(PosApiService());

  @override
  Future<Result<SaleOrderPage>> loadOrdersForSession(
    int sessionId, {
    SaleOrderQuery query = const SaleOrderQuery(),
    String? cursor,
  }) async {
    return const Ok(SaleOrderPage(orders: [], hasMore: false));
  }
}

class _FakeShopSettingsRepository extends ShopSettingsRepository {
  _FakeShopSettingsRepository() : super(PosApiService());
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository() : super(PosApiService());
}
