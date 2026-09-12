// Dev-only preview harness for the owner dashboard.
// Safe to delete — never imported by lib/main.dart.
//
// Run: flutter run -d web-server --web-port 8080 -t lib/dev/dashboard_preview.dart
// (or `make frontend-dashboard-preview`). Reload the browser once after the
// server reports "is being served at" so Flutter paints.
//
// Screens (?screen=…):
//   dashboard   the whole dashboard, full viewport (default)
//   board       phone + wide frames side by side, for one overview screenshot
//   dark        the whole dashboard in the dark palette
//   fx          the exchange-rate band alone, in its interesting states
//   payments    the payment-mix card alone, both metrics
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/dashboard.dart';
import 'package:pointy_frontend/src/data/models/dashboard_ai_digest.dart';
import 'package:pointy_frontend/src/data/models/exchange_rate.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/dashboard_repository.dart';
import 'package:pointy_frontend/src/data/repositories/fx_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/dashboard/view_models/dashboard_fx_view_model.dart';
import 'package:pointy_frontend/src/features/dashboard/view_models/dashboard_view_model.dart';
import 'package:pointy_frontend/src/features/dashboard/views/dashboard_fx_band.dart';
import 'package:pointy_frontend/src/features/dashboard/views/dashboard_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() {
  configureCurrencySymbol('د.ل', code: 'LYD');
  configureForeignCurrencySymbols(const {'USD': r'$', 'EUR': '€', 'GBP': '£'});
  runApp(const _PreviewApp());
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final screen = Uri.base.queryParameters['screen'] ?? 'dashboard';
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
      theme: screen == 'dark' ? PointyTheme.dark() : PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: switch (screen) {
        'board' => const _Board(),
        'fx' => const _FxSurfaces(),
        'payments' => const _PaymentSurfaces(),
        _ => _dashboard(),
      },
    );
  }
}

Widget _dashboard({
  DashboardFxViewModel? fx,
  Map<String, Object?>? snapshotJson,
}) {
  final navigation = _PreviewNavigation();
  return DashboardScreen(
    viewModel: DashboardViewModel(
      _FakeDashboardRepository(snapshotJson ?? _snapshotJson()),
      canRequestAiDigest: () => false,
    ),
    capabilities: navigation.capabilities,
    navigation: navigation,
    fxViewModel: fx ?? _fxViewModel(),
    onOpenExchangeRates: () {},
  );
}

/// Phone and wide side by side, for a single overview screenshot.
class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.pointyColors.page,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Frame(
              label: 'هاتف · 390×1800',
              width: 390,
              height: 1800,
              child: _dashboard(),
            ),
            const SizedBox(width: 16),
            _Frame(
              label: 'عريض · 1100×1800',
              width: 1100,
              height: 1800,
              child: _dashboard(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rates band on its own, in the states worth eyeballing.
class _FxSurfaces extends StatelessWidget {
  const _FxSurfaces();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pointyColors.page,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Labelled(
              label: 'ثلاث عملات · اتجاه كامل',
              child: DashboardFxBand(
                viewModel: _fxViewModel(),
                onOpenRates: () {},
              ),
            ),
            _Labelled(
              label: 'بدون اتجاه (لا يوجد تاريخ بعد)',
              child: DashboardFxBand(viewModel: _fxViewModel(withTrend: false)),
            ),
            _Labelled(
              label: 'سعر قديم + سلسلة بديلة',
              child: DashboardFxBand(viewModel: _fxViewModel(stale: true)),
            ),
            _Labelled(
              label: 'عملة واحدة فقط',
              child: DashboardFxBand(viewModel: _fxViewModel(codes: ['USD'])),
            ),
            _Labelled(
              label: 'ضيّق · ٣٦٠ بكسل',
              child: SizedBox(
                width: 360,
                child: DashboardFxBand(viewModel: _fxViewModel()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The payment-mix card alone, so the value/volume switch is easy to drive.
class _PaymentSurfaces extends StatelessWidget {
  const _PaymentSurfaces();

  @override
  Widget build(BuildContext context) {
    final navigation = _PreviewNavigation();
    return Scaffold(
      backgroundColor: context.pointyColors.page,
      body: Center(
        child: SizedBox(
          width: 420,
          child: DashboardScreen(
            viewModel: DashboardViewModel(
              _FakeDashboardRepository(_paymentsOnlyJson()),
              canRequestAiDigest: () => false,
            ),
            capabilities: navigation.capabilities,
            navigation: navigation,
          ),
        ),
      ),
    );
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({
    required this.label,
    required this.width,
    required this.height,
    required this.child,
  });

  final String label;
  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        SizedBox(
          width: width,
          height: height,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: Size(width, height),
              padding: EdgeInsets.zero,
              viewInsets: EdgeInsets.zero,
            ),
            child: child,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _PreviewNavigation implements AppNavigation {
  @override
  final PosUser currentUser = PosUser.fromJson(const {
    'id': 1,
    'username': 'owner',
    'display_name': 'صاحب المحل',
    'email': '',
    'role': 'manager',
    'permissions': <String>[],
    'is_active': true,
    'ai_available': false,
    'surveillance_enabled': false,
  });

  @override
  late final AuthorizationCapabilities capabilities =
      AuthorizationCapabilities.forUser(currentUser);

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

class _FakeDashboardRepository extends DashboardRepository {
  _FakeDashboardRepository(this.json) : super(PosApiService());

  final Map<String, Object?> json;

  @override
  Future<Result<DashboardSnapshot>> loadDashboard({required int days}) async {
    return Ok(DashboardSnapshot.fromJson(json));
  }

  @override
  Future<Result<DashboardAiDigest>> loadAiDigest({required int days}) async {
    return const Ok(DashboardAiDigest.empty);
  }
}

class _FakeFxRepository extends FxRepository {
  _FakeFxRepository({
    required this.codes,
    required this.stale,
    required this.withTrend,
  }) : super(PosApiService());

  final List<String> codes;
  final bool stale;
  final bool withTrend;

  static const _rates = {'USD': 6.85, 'EUR': 7.42, 'GBP': 8.63};

  @override
  Future<Result<CurrentRates>> loadCurrentRates() async {
    return Ok(
      CurrentRates(
        baseCode: 'LYD',
        instrument: SettlementInstrument.cash,
        bankCode: '',
        stalenessHours: 24,
        fxEnabled: true,
        rates: [
          for (final code in codes)
            ResolvedRate(
              fromCode: code,
              toCode: 'LYD',
              rate: _rates[code] ?? 1,
              effectiveAt: DateTime.now().subtract(
                Duration(hours: stale ? 76 : 3),
              ),
              source: RateSource.relay,
              instrument: SettlementInstrument.cash,
              bankCode: '',
              requestedInstrument: stale
                  ? SettlementInstrument.bank
                  : SettlementInstrument.cash,
              requestedBankCode: '',
              isStale: stale,
              isSubstituted: stale,
              ageHours: stale ? 76 : 3,
            ),
        ],
      ),
    );
  }

  /// USD drifting up, EUR drifting down, GBP flat — one of each tone.
  @override
  Future<Result<List<ExchangeRate>>> loadRateHistory({
    String? fromCode,
    int pageSize = 100,
  }) async {
    if (!withTrend) {
      return const Ok(<ExchangeRate>[]);
    }
    final code = fromCode ?? 'USD';
    final end = _rates[code] ?? 1;
    final drift = switch (code) {
      'USD' => 0.09,
      'EUR' => -0.11,
      _ => 0.0,
    };
    final wobble = [0.0, 0.012, -0.008, 0.004, -0.014, 0.006, 0.0, -0.004];
    return Ok([
      for (var index = 0; index < 8; index += 1)
        ExchangeRate(
          id: index,
          fromCode: code,
          toCode: 'LYD',
          rate:
              end -
              drift * (7 - index) / 7 +
              (index == 7 ? 0 : wobble[index] * end / 10),
          instrument: SettlementInstrument.cash,
          bankCode: '',
          source: RateSource.relay,
          effectiveAt: DateTime.now().subtract(
            Duration(hours: (7 - index) * 9),
          ),
        ),
    ]);
  }
}

DashboardFxViewModel _fxViewModel({
  List<String> codes = const ['USD', 'EUR', 'GBP'],
  bool stale = false,
  bool withTrend = true,
}) {
  return DashboardFxViewModel(
    _FakeFxRepository(codes: codes, stale: stale, withTrend: withTrend),
  );
}

// ---------------------------------------------------------------------------
// Fake payload: a believable Libyan grocery, one month in.
// ---------------------------------------------------------------------------

Map<String, Object?> _paymentsJson() => {
  'summary': {
    'total': '41820.00',
    'commission_total': '386.40',
    'payment_count': 613,
  },
  'methods': [
    {'method': 'cash', 'total': '30180.00', 'commission': '0', 'count': 502},
    {'method': 'card', 'total': '9260.00', 'commission': '324.10', 'count': 96},
    {
      'method': 'transfer',
      'total': '2380.00',
      'commission': '62.30',
      'count': 15,
    },
  ],
};

Map<String, Object?> _paymentsOnlyJson() => {
  'generated_at': '2026-09-12T08:10:00Z',
  'period': {'days': 30},
  'sections': {'payments': _paymentsJson()},
};

Map<String, Object?> _snapshotJson() => {
  'generated_at': '2026-09-12T08:10:00Z',
  'period': {'days': 30},
  'sections': {
    'sales': {
      'summary': {
        'gross_sales': '46310.00',
        'discount_total': '1240.00',
        'refund_total': '820.00',
        'net_sales': '44250.00',
        'gross_profit': '9860.00',
        'profit_margin_percent': '22.28',
        'net_sales_change_percent': '8.40',
        'order_count': 613,
        'order_count_change_percent': '4.10',
        'average_order_value': '72.18',
        'items_sold': 2914,
        'void_count': 3,
        'return_count': 11,
      },
      'registers': {
        'open_count': 1,
        'closed_count': 29,
        'variance_count': 2,
        'variance_total': '-14.50',
      },
      'trend': [
        for (var day = 0; day < 30; day += 1)
          {
            'date': '2026-08-${(day + 13).toString().padLeft(2, '0')}',
            'net_sales': (1100 + (day % 7) * 240 + (day * 17) % 390).toString(),
            'order_count': 15 + day % 9,
          },
      ],
      'hourly_sales': [
        for (var hour = 8; hour < 23; hour += 1)
          {
            'hour': hour,
            'net_sales':
                (hour < 11
                        ? 900
                        : hour < 14
                        ? 4200
                        : hour < 18
                        ? 2600
                        : 5100)
                    .toString(),
          },
      ],
      'top_products': [
        {
          'product_name': 'زيت ذرة ٣ لتر',
          'sku': 'OIL-3L',
          'quantity': 218,
          'revenue': '5232.00',
          'profit': '742.00',
        },
        {
          'product_name': 'أرز بسمتي ٥ كجم',
          'sku': 'RICE-5',
          'quantity': 164,
          'revenue': '4920.00',
          'profit': '688.00',
        },
        {
          'product_name': 'سكر ناعم ١ كجم',
          'sku': 'SUG-1',
          'quantity': 412,
          'revenue': '2472.00',
          'profit': '412.00',
        },
        {
          'product_name': 'معجون طماطم',
          'sku': 'TOM-400',
          'quantity': 305,
          'revenue': '1830.00',
          'profit': '366.00',
        },
      ],
      'top_categories': [
        {'category_name': 'مواد غذائية', 'quantity': 1840, 'revenue': '21400'},
        {'category_name': 'منظفات', 'quantity': 512, 'revenue': '8600'},
        {'category_name': 'مشروبات', 'quantity': 402, 'revenue': '6240'},
      ],
      'recent_orders': [
        {
          'receipt_number': 'INV-004182',
          'customer_name': 'محمد الصغير',
          'status': 'paid',
          'total': '212.50',
        },
        {
          'receipt_number': 'INV-004181',
          'customer_name': '',
          'status': 'paid',
          'total': '46.00',
        },
        {
          'receipt_number': 'INV-004180',
          'customer_name': 'مخبز النور',
          'status': 'open',
          'total': '880.00',
        },
      ],
      'reports': {
        'products': {
          'profit': [
            {
              'product_name': 'زيت ذرة ٣ لتر',
              'sku': 'OIL-3L',
              'quantity': 218,
              'revenue': '5232.00',
              'profit': '742.00',
            },
            {
              'product_name': 'أرز بسمتي ٥ كجم',
              'sku': 'RICE-5',
              'quantity': 164,
              'revenue': '4920.00',
              'profit': '688.00',
            },
          ],
        },
      },
    },
    'payments': _paymentsJson(),
    'profitability': {
      'summary': {
        'gross_profit': '9860.00',
        'payroll_paid_total': '3200.00',
        'payroll_accrued_total': '800.00',
        'payment_commission_total': '386.40',
        'ad_hoc_expense_total': '1140.00',
        'purchase_spend_total': '28400.00',
        'operating_expense_total': '5526.40',
        'net_operating_profit': '4333.60',
      },
    },
    'inventory': {
      'summary': {
        'product_count': 842,
        'active_product_count': 806,
        'stock_item_count': 1204,
        'low_stock_count': 17,
        'out_of_stock_count': 4,
        'committed_units': 38,
        'expected_units': 620,
        'retail_stock_value': '96400.00',
      },
      'low_stock_items': [
        {
          'product_name': 'حليب مجفف ٩٠٠ جم',
          'variant_name': '',
          'sku': 'MLK-900',
          'quantity_on_hand': 3,
          'reorder_level': 24,
        },
        {
          'product_name': 'شاي أخضر',
          'variant_name': 'علبة كبيرة',
          'sku': 'TEA-L',
          'quantity_on_hand': 6,
          'reorder_level': 20,
        },
      ],
      'dusty_items': [
        {
          'product_name': 'مكنسة يدوية',
          'variant_name': '',
          'sku': 'BRM-1',
          'quantity_on_hand': 41,
          'reorder_level': 5,
        },
      ],
    },
    'customers': {
      'summary': {
        'active_customer_count': 318,
        'new_customer_count': 24,
        'customers_with_sales_count': 186,
        'repeat_customer_count': 94,
        'marketing_consent_count': 61,
      },
      'top_customers': [
        {
          'customer_name': 'مخبز النور',
          'sales_total': '4820.00',
          'order_count': 22,
        },
        {
          'customer_name': 'مقهى البحر',
          'sales_total': '3140.00',
          'order_count': 17,
        },
      ],
    },
    'purchasing': {
      'summary': {
        'purchase_total': '28400.00',
        'open_order_count': 5,
        'received_order_count': 18,
        'due_total': '9600.00',
        'overdue_order_count': 2,
        'supplier_count': 21,
      },
      'overdue_orders': [
        {
          'order_number': 'PO-00318',
          'supplier_name': 'شركة الوفاء للتوريدات',
          'due_date': '2026-09-02',
          'balance_due': '4200.00',
        },
      ],
      'top_supplier_balances': [
        {'supplier_name': 'شركة الوفاء للتوريدات', 'net_balance': '4200.00'},
        {'supplier_name': 'مؤسسة الساحل', 'net_balance': '2380.00'},
      ],
    },
    'discounts': {
      'summary': {'active_rule_count': 4, 'coupon_rule_count': 1},
      'top_rules': [
        {
          'rule_name': 'خصم نهاية الأسبوع',
          'channel': 'sales',
          'discount_total': '820.00',
          'redemption_count': 96,
        },
      ],
    },
    'fraud': {
      'summary': {
        'active_count': 2,
        'critical_count': 0,
        'top_risk_score': '46',
      },
      'recent_findings': [
        {
          'headline': 'إلغاء متكرر على صندوق واحد',
          'severity': 'medium',
          'risk_score': '46',
        },
      ],
    },
  },
};
