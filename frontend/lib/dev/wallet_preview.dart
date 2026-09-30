// Dev-only preview harness for the Daftar wallet (Shop Settings > الاشتراك).
//
// Renders the subscription page with its wallet section, the top-up sheet in
// each of its stages, and the history page, backed by in-memory fakes (no
// backend, no relay, no payment gateway — the "browser" never opens). Pick the
// scenario with `?screen=` and resize the browser to test responsiveness:
//
//   make frontend-wallet-preview
//
// Scenarios: page | test_mode | empty | unavailable | sheet | sheet_error |
//            waiting | paid | canceled | unconfirmed | history
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/relay_installation_status.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/data/repositories/subscription_repository.dart';
import 'package:pointy_frontend/src/data/repositories/wallet_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/subscription_status_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/subscription_status_page.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_history_page.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_top_up_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

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
  return parsed?.queryParameters['screen'] ?? 'page';
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final screen = _screen();
    final wallet = WalletViewModel(
      _FakeWalletRepository(screen),
      launchCheckout: (_) async => true,
      fastPollInterval: const Duration(milliseconds: 900),
    );
    final page = SubscriptionStatusPage(
      viewModel: SubscriptionStatusViewModel(
        _FakeSubscriptionRepository(),
        wallet: wallet,
      ),
    );
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
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: switch (screen) {
        'history' => _HistoryHost(wallet: wallet),
        'sheet' ||
        'sheet_error' ||
        'waiting' ||
        'paid' ||
        'canceled' ||
        'unconfirmed' => _SheetHost(wallet: wallet, page: page, screen: screen),
        _ => page,
      },
    );
  }
}

/// Opens the top-up sheet on load and, for the later stages, starts a top-up
/// so the fake gateway can walk it to its verdict.
class _SheetHost extends StatefulWidget {
  const _SheetHost({
    required this.wallet,
    required this.page,
    required this.screen,
  });

  final WalletViewModel wallet;
  final Widget page;
  final String screen;

  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.wallet.load();
      if (!mounted) {
        return;
      }
      final sheet = showWalletTopUpSheet(
        context: context,
        viewModel: widget.wallet,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      switch (widget.screen) {
        case 'sheet_error':
          await widget.wallet.startTopUp(7);
        case 'waiting' || 'paid' || 'canceled' || 'unconfirmed':
          await widget.wallet.startTopUp(100);
      }
      await sheet;
    });
  }

  @override
  Widget build(BuildContext context) => widget.page;
}

class _HistoryHost extends StatelessWidget {
  const _HistoryHost({required this.wallet});

  final WalletViewModel wallet;

  @override
  Widget build(BuildContext context) => WalletHistoryPage(viewModel: wallet);
}

final _now = DateTime.now();

WalletTopUp _topUp(
  String id,
  double amount,
  WalletTopUpStatus status, {
  Duration ago = Duration.zero,
  bool booked = false,
  bool testMode = false,
  String expenseError = '',
}) {
  return WalletTopUp(
    id: id,
    invoiceNo: 'DFW-${id.toUpperCase().padRight(10, 'Q').substring(0, 10)}',
    method: WalletTopUpMethod.localBankCards,
    amount: amount,
    status: status,
    testMode: testMode,
    createdAt: _now.subtract(ago),
    paidAt: status == WalletTopUpStatus.paid ? _now.subtract(ago) : null,
    requestedBy: 'حاتم',
    recordAsExpense: true,
    expenseId: booked ? 41 : null,
    expenseError: expenseError,
    checkoutUrl: status == WalletTopUpStatus.pending
        ? 'https://checkout.plutus.test/pay/preview'
        : null,
  );
}

class _FakeWalletRepository extends WalletRepository {
  _FakeWalletRepository(this.scenario) : super(PosApiService());

  final String scenario;
  int _polls = 0;

  bool get _testMode => scenario == 'test_mode';

  List<WalletTopUp> get _recent => scenario == 'empty'
      ? const []
      : [
          _topUp(
            'paid7wq2x4pk',
            200,
            WalletTopUpStatus.paid,
            ago: const Duration(hours: 3),
            booked: true,
            testMode: _testMode,
          ),
          _topUp(
            'cncl3m9q2x4',
            50,
            WalletTopUpStatus.canceled,
            ago: const Duration(days: 1),
          ),
          _topUp(
            'paid2k7m3n8',
            100,
            WalletTopUpStatus.paid,
            ago: const Duration(days: 12),
            expenseError: 'period_locked',
          ),
          _topUp(
            'exp9x4p2k7m',
            500,
            WalletTopUpStatus.expired,
            ago: const Duration(days: 20),
          ),
        ];

  WalletTopUpOptions get _options => WalletTopUpOptions(
    available: true,
    methods: const [
      WalletTopUpMethod(
        key: WalletTopUpMethod.localBankCards,
        gateway: 'plutu',
        kind: 'hosted_checkout',
      ),
    ],
    minAmount: 10,
    maxAmount: _testMode ? 500 : 5000,
    maxDecimals: 2,
    quickAmounts: const [50, 100, 200, 500],
    pendingTtl: const Duration(minutes: 30),
  );

  @override
  Future<Result<WalletOverview>> loadWallet() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (scenario == 'unavailable') {
      return Ok(
        WalletOverview(
          available: false,
          balance: null,
          currency: 'LYD',
          testMode: false,
          topUpOptions: null,
          recentTopUps: _recent.take(2).toList(),
          recentEntries: const [],
          settings: const WalletSettings(
            recordTopUpsAsExpenses: true,
            defaultExpenseCategoryName: 'خدمات دفتر',
          ),
          error: const WalletError(code: 'relay_unreachable', message: ''),
        ),
      );
    }
    final paid = scenario == 'paid' && _polls > 0;
    return Ok(
      WalletOverview(
        available: true,
        balance: scenario == 'empty' ? 0 : (paid ? 345.5 : 245.5),
        currency: 'LYD',
        testMode: _testMode,
        topUpOptions: _options,
        recentTopUps: _recent,
        recentEntries: const [],
        settings: const WalletSettings(
          recordTopUpsAsExpenses: true,
          defaultExpenseCategoryName: 'خدمات دفتر',
        ),
      ),
    );
  }

  @override
  Future<Result<WalletTopUpStart>> startTopUp({
    required String amount,
    required String method,
    required String idempotencyKey,
    bool? recordAsExpense,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (scenario == 'sheet_error') {
      return Error(
        const WalletException(
          code: 'invalid_amount',
          message: '',
          statusCode: 422,
          minAmount: 10,
          maxAmount: 5000,
        ),
      );
    }
    return Ok(
      WalletTopUpStart(
        topUp: _topUp(
          'new8k2m4q7x',
          double.parse(amount),
          WalletTopUpStatus.pending,
        ),
        checkoutUrl: 'https://checkout.plutus.test/pay/preview',
        replayed: false,
      ),
    );
  }

  @override
  Future<Result<WalletTopUp>> loadTopUp(String id) async {
    _polls++;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final status = switch (scenario) {
      'paid' => WalletTopUpStatus.paid,
      'canceled' => WalletTopUpStatus.canceled,
      'unconfirmed' => WalletTopUpStatus.expired,
      _ => WalletTopUpStatus.pending,
    };
    return Ok(
      _topUp(id, 100, status, booked: status == WalletTopUpStatus.paid),
    );
  }

  @override
  Future<Result<WalletPage<WalletTopUp>>> loadTopUps({String? before}) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return Ok(
      WalletPage(
        items: before == null ? _recent : const [],
        hasMore: before == null,
      ),
    );
  }

  @override
  Future<Result<WalletPage<WalletEntry>>> loadEntries({String? before}) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (before != null) {
      return const Ok(WalletPage(items: [], hasMore: false));
    }
    return Ok(
      WalletPage(
        items: [
          WalletEntry(
            id: 'e4',
            kind: WalletEntryKind.charge,
            service: 'sms',
            amount: -4.5,
            balanceAfter: 245.5,
            createdAt: _now.subtract(const Duration(hours: 1)),
            description: 'رسائل سبتمبر (100 رسالة)',
          ),
          WalletEntry(
            id: 'e3',
            kind: WalletEntryKind.topUp,
            amount: 200,
            balanceAfter: 250,
            createdAt: _now.subtract(const Duration(hours: 3)),
            description: 'Plutu local bank card DFW-PAID7WQ2X4',
          ),
          WalletEntry(
            id: 'e2',
            kind: WalletEntryKind.charge,
            service: 'subscription',
            amount: -150,
            balanceAfter: 50,
            createdAt: _now.subtract(const Duration(days: 5)),
            description: 'اشتراك أكتوبر',
          ),
          WalletEntry(
            id: 'e1',
            kind: WalletEntryKind.adjustment,
            amount: 100,
            balanceAfter: 200,
            createdAt: _now.subtract(const Duration(days: 30)),
            description: 'رصيد ترحيبي',
          ),
        ],
        hasMore: true,
      ),
    );
  }

  @override
  Future<Result<WalletSettings>> updateSettings({
    required bool recordTopUpsAsExpenses,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return Ok(
      WalletSettings(
        recordTopUpsAsExpenses: recordTopUpsAsExpenses,
        defaultExpenseCategoryName: 'خدمات دفتر',
      ),
    );
  }
}

class _FakeSubscriptionRepository extends SubscriptionRepository {
  _FakeSubscriptionRepository() : super(PosApiService());

  @override
  Future<Result<RelayInstallationStatus>> loadStatus({
    bool sync = false,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return Ok(
      RelayInstallationStatus(
        configured: true,
        remoteAccessSupported: true,
        installationId: 'POS-LY-7F3A-9K21',
        shopName: 'سوبر ماركت الوفاء',
        relayPublicApiUrl: 'https://relay.pointy.ly',
        relayConnectorAddress: 'relay.pointy.ly:8443',
        relayEnabled: true,
        subscriptionActive: true,
        aiEnabled: false,
        smsEnabled: true,
        subscriptionEndsAt: _now.add(const Duration(days: 318)),
        lastSyncedAt: _now.subtract(const Duration(minutes: 5)),
        connectorLastSeenAt: _now.subtract(const Duration(seconds: 40)),
        connectorVersion: '1.4.0',
      ),
    );
  }
}
