// Dev-only preview harness for the Daftar wallet (Shop Settings > الاشتراك).
//
// Renders the subscription page with its wallet section, the top-up sheet in
// each of its stages, the spending sheets (money into the SMS balance, a plan
// paid from the wallet) and the history page, backed by in-memory fakes (no
// backend, no relay, no payment gateway — the "browser" never opens). Pick the
// scenario with `?screen=` and resize the browser to test responsiveness:
//
//   make frontend-wallet-preview
//
// Scenarios: page | test_mode | empty | unavailable | sheet | sheet_sadad |
//            payer_dialog | payer_dialog_card | sheet_error | code |
//            code_error | code_test | waiting | paid | declined | canceled |
//            unconfirmed | history | sms_empty | sms_sheet | sms_sheet_poor |
//            plan_sheet | renew_sheet | vouchers | vouchers_sheet |
//            transfer | transfer_onepay | transfer_receipt | transfer_review |
//            transfer_rejected
//
// The `transfer*` scenarios are the bank transfer: our account (a made-up
// one), the payer's saved account, the receipt, then the team's verdict.
//
// `vouchers` is the page with «كروت دفتر» switched on, so the voucher balance
// sits under the SMS one; `vouchers_sheet` opens the transfer into it, and
// `history` then carries the voucher statement tab too.
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'dart:convert';

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
import 'package:pointy_frontend/src/features/settings/views/wallet_payer_dialog.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_plan_sheet.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_sms_sheet.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_top_up_sheet.dart';
import 'package:pointy_frontend/src/features/settings/views/wallet_vouchers_sheet.dart';
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
    final repository = _FakeWalletRepository(screen);
    final wallet = WalletViewModel(
      repository,
      launchCheckout: (_) async => true,
      fastPollInterval: const Duration(milliseconds: 900),
    );
    final page = SubscriptionStatusPage(
      viewModel: SubscriptionStatusViewModel(
        _FakeSubscriptionRepository(repository),
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
        'sheet_sadad' ||
        'payer_dialog' ||
        'payer_dialog_card' ||
        'sheet_error' ||
        'code' ||
        'code_error' ||
        'code_test' ||
        'waiting' ||
        'paid' ||
        'declined' ||
        'canceled' ||
        'unconfirmed' ||
        'transfer' ||
        'transfer_onepay' ||
        'transfer_receipt' ||
        'transfer_review' ||
        'transfer_rejected' => _SheetHost(
          wallet: wallet,
          page: page,
          screen: screen,
        ),
        'sms_sheet' ||
        'sms_sheet_poor' ||
        'plan_sheet' ||
        'renew_sheet' ||
        'vouchers_sheet' => _SpendHost(
          wallet: wallet,
          page: page,
          screen: screen,
        ),
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
      final wallet = widget.wallet;
      switch (widget.screen) {
        case 'sheet_sadad':
          wallet.selectMethod('dafa_sadad');
        case 'payer_dialog' || 'payer_dialog_card':
          wallet.selectMethod(
            widget.screen == 'payer_dialog' ? 'dafa_sadad' : 'dafa_yussor_pay',
          );
          final method = wallet.selectedMethod;
          if (mounted && method != null) {
            await showWalletPayerDialog(
              context: context,
              viewModel: wallet,
              method: method,
              amount: 100,
              draft: WalletPayerDraft(),
            );
          }
        case 'sheet_error':
          // A refusal about the method closes the payer dialog; the form
          // says why.
          wallet.selectMethod('dafa_edfali');
          await wallet.startTopUp(100, userIdentifier: '0912345678');
        case 'code' || 'code_error' || 'code_test' || 'paid' || 'declined':
          wallet.selectMethod('dafa_sadad');
          await wallet.startTopUp(
            100,
            userIdentifier: '0912345678',
            birthYear: '1990',
          );
          switch (widget.screen) {
            case 'code_error':
              await wallet.confirmCode('123456');
            case 'paid':
              await wallet.confirmCode('111111');
            case 'declined':
              await wallet.confirmCode('222222');
          }
        case 'waiting' || 'canceled' || 'unconfirmed':
          wallet.selectMethod('dafa_moamalat');
          await wallet.startTopUp(100);
        case 'transfer' ||
            'transfer_onepay' ||
            'transfer_receipt' ||
            'transfer_review' ||
            'transfer_rejected':
          wallet.selectMethod(WalletTopUpMethod.bankTransfer);
          wallet.beginBankTransfer(150);
          if (widget.screen == 'transfer_onepay') {
            wallet.transfer.selectChannel(WalletTransferChannel.onePay);
          }
          if (widget.screen != 'transfer' &&
              widget.screen != 'transfer_onepay') {
            wallet.transfer.attachReceipt(
              WalletTransferReceipt.file(
                bytes: _receiptPng,
                name: 'Screenshot_2026-10-09.png',
                contentType: 'image/png',
              ),
            );
          }
          if (widget.screen == 'transfer_review' ||
              widget.screen == 'transfer_rejected') {
            await wallet.transfer.send(amount: '150', recordAsExpense: true);
            if (widget.screen == 'transfer_rejected') {
              await wallet.checkActiveTopUp();
            }
          }
      }
      await sheet;
    });
  }

  @override
  Widget build(BuildContext context) => widget.page;
}

/// Opens a spending sheet on load: money into the SMS balance, or a plan.
class _SpendHost extends StatefulWidget {
  const _SpendHost({
    required this.wallet,
    required this.page,
    required this.screen,
  });

  final WalletViewModel wallet;
  final Widget page;
  final String screen;

  @override
  State<_SpendHost> createState() => _SpendHostState();
}

class _SpendHostState extends State<_SpendHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.wallet.load();
      if (!mounted) {
        return;
      }
      switch (widget.screen) {
        case 'sms_sheet' || 'sms_sheet_poor':
          await showSmsAllocationSheet(context: context, wallet: widget.wallet);
        case 'plan_sheet':
          await showWalletPlanSheet(
            context: context,
            wallet: widget.wallet,
            planKey: WalletPlan.ai,
          );
        case 'renew_sheet':
          await showWalletPlanSheet(
            context: context,
            wallet: widget.wallet,
            planKey: WalletPlan.remoteAccess,
          );
        case 'vouchers_sheet':
          await showVoucherAllocationSheet(
            context: context,
            wallet: widget.wallet,
          );
      }
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
  String method = WalletTopUpMethod.bankCards,
  String payerHint = '',
  Duration ago = Duration.zero,
  bool booked = false,
  bool testMode = false,
  String expenseError = '',
  String errorCode = '',
}) {
  final hostedPage = method == WalletTopUpMethod.bankCards;
  return WalletTopUp(
    id: id,
    invoiceNo: 'DFW-${id.toUpperCase().padRight(10, 'Q').substring(0, 10)}',
    method: method,
    kind: hostedPage
        ? WalletTopUpMethod.kindHostedPage
        : WalletTopUpMethod.kindOtp,
    payerHint: payerHint,
    amount: amount,
    status: status,
    testMode: testMode,
    createdAt: _now.subtract(ago),
    paidAt: status == WalletTopUpStatus.paid ? _now.subtract(ago) : null,
    requestedBy: 'حاتم',
    errorCode: errorCode,
    recordAsExpense: true,
    expenseId: booked ? 41 : null,
    expenseError: expenseError,
    checkoutUrl: status == WalletTopUpStatus.pending && hostedPage
        ? 'https://pay.dafa.test/preview'
        : null,
    otpAttemptsLeft: status == WalletTopUpStatus.pending && !hostedPage
        ? 5
        : null,
  );
}

WalletTopUp _transfer(
  WalletTopUpStatus status, {
  Duration ago = Duration.zero,
}) {
  return WalletTopUp(
    id: 'bt-${status.name}',
    invoiceNo: 'DFW-TRANSFER0${status.index}',
    method: WalletTopUpMethod.bankTransfer,
    kind: WalletTopUpMethod.kindBankTransfer,
    amount: 150,
    status: status,
    testMode: false,
    createdAt: _now.subtract(ago),
    requestedBy: 'حاتم',
    errorCode: status == WalletTopUpStatus.rejected ? 'rejected' : '',
    errorDetail: status == WalletTopUpStatus.rejected
        ? 'لم يصل المبلغ إلى حسابنا. تأكد من رقم IBAN وأرسل الإيصال من جديد.'
        : '',
    transfer: const WalletTransferDetails(
      channel: WalletTransferChannel.lyPay,
      payerBank: 'jbank',
      payerAccount: '000011122233344',
      payerIban: 'LY75001002000011122233344',
    ),
  );
}

/// A small PNG standing in for a transfer receipt.
final _receiptPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAHgAAADICAIAAACszLLwAAAB3klEQVR42u3cMW7CQBCG0R+L'
  'OgdJmcpHQVQ5EIegzFGoKDkKQlS0kVIgbBONd99XIgr0NFqhWcPmY3+I3t+AADRogQYNWqBB'
  'CzRo0AINWqBBgxZo0AINGrRAgxZo0KAFGrRAgwYt0KAFumCb6+1OwUSDFmjQoAUatECDBi3Q'
  'oAUadMdtV/RZx5/vvy+edsfYR7+VeF3c1aGfEq+Fe2hGecL7QU9XK2s9tKRc2drXu46h549k'
  'waE20b1CLzWM1YbaRIMGLdCgQSPoFHqpDVy1TZ6J7hh6/jAWXEyb6L6h54xkzXuWuhM9zavs'
  'bVbpo+NVtcp3hm7BQXuuQ77egQaNADRogQYNWqBBKwv/huV0vjD63fj1aaIdHQINGrRi8W+i'
  'BRo0aIGOXUca2FeYaEeHQIMGrdh1mGiBBg1aoEELNGjQAg1aiadJ8193Nyba0QFaoEHHDYsb'
  'FhMNWqBBg1bsOtLMs6Ym2tEBWqBBx67DrsNEgxZo0KAVu440sxgx0Y4O0AINOnYddh0mGrRA'
  'gwat2HVkRf8DZqJBgxZo0Ipdh4kGLdCgBRo0aIEGLdCg44Yl8TRp/EuYo0OgQYNW3LCYaIEG'
  'DVqgQQs0aNACDVqgQYMWaNACDRq0QIMWaNBN9wCLVGpPMsAwEQAAAABJRU5ErkJggg==',
);

const _methods = [
  WalletTopUpMethod(
    key: 'dafa_moamalat',
    gateway: 'dafa',
    provider: 'moamalat',
    kind: WalletTopUpMethod.kindHostedPage,
  ),
  WalletTopUpMethod(
    key: 'dafa_sadad',
    gateway: 'dafa',
    provider: 'sadad',
    kind: WalletTopUpMethod.kindOtp,
    payer: WalletPayer.phone,
    needsBirthYear: true,
  ),
  WalletTopUpMethod(
    key: 'dafa_edfali',
    gateway: 'dafa',
    provider: 'edfali',
    kind: WalletTopUpMethod.kindOtp,
    payer: WalletPayer.phone,
  ),
  WalletTopUpMethod(
    key: 'dafa_mobicash',
    gateway: 'dafa',
    provider: 'mobicash',
    kind: WalletTopUpMethod.kindOtp,
    payer: WalletPayer.card,
  ),
  WalletTopUpMethod(
    key: 'dafa_yussor_pay',
    gateway: 'dafa',
    provider: 'yussor-pay',
    kind: WalletTopUpMethod.kindOtp,
    payer: WalletPayer.card,
  ),
  WalletTopUpMethod(
    key: 'dafa_masrafi_pay',
    gateway: 'dafa',
    provider: 'masrafi-pay',
    kind: WalletTopUpMethod.kindOtp,
    payer: WalletPayer.card,
  ),
  WalletTopUpMethod(
    key: 'dafa_sahara_pay',
    gateway: 'dafa',
    provider: 'sahara-pay',
    kind: WalletTopUpMethod.kindOtp,
    payer: WalletPayer.card,
  ),
];

class _FakeWalletRepository extends WalletRepository {
  _FakeWalletRepository(this.scenario) : super(PosApiService());

  final String scenario;
  int _polls = 0;

  bool get _testMode => scenario == 'test_mode' || scenario == 'code_test';

  List<WalletTopUp> get _recent => scenario == 'empty'
      ? const []
      : [
          _topUp(
            'paid7wq2x4pk',
            200,
            WalletTopUpStatus.paid,
            method: 'dafa_sadad',
            payerHint: '091•••678',
            ago: const Duration(hours: 3),
            booked: true,
            testMode: _testMode,
          ),
          _transfer(WalletTopUpStatus.review, ago: const Duration(minutes: 8)),
          _transfer(WalletTopUpStatus.rejected, ago: const Duration(hours: 6)),
          _topUp(
            'dcln3m9q2x4',
            50,
            WalletTopUpStatus.failed,
            method: 'dafa_edfali',
            payerHint: '092•••114',
            errorCode: 'declined',
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
            method: 'dafa_yussor_pay',
            payerHint: '•••• 0860',
            ago: const Duration(days: 20),
          ),
        ];

  WalletTopUpOptions get _options => const WalletTopUpOptions(
    available: true,
    methods: [..._methods, WalletTopUpMethod.bankTransferMethod],
    minAmount: 10,
    maxAmount: 5000,
    maxDecimals: 2,
    quickAmounts: [50, 100, 200, 500],
    pendingTtl: Duration(minutes: 30),
    bankTransfer: WalletBankTransferOffer(
      // Made up: the real account is set in the operator console.
      accounts: [
        WalletBankAccount(
          id: 'acc-1',
          bank: 'nab',
          bankName: 'مصرف شمال أفريقيا',
          holder: 'شركة دفتر للتقنية',
          accountNumber: '000020100120361',
          iban: 'LY83002048000020100120361',
        ),
      ],
      savedPayers: [
        WalletPayerAccount(
          bank: 'jbank',
          accountNumber: '000011122233344',
          iban: 'LY75001002000011122233344',
        ),
      ],
    ),
  );

  @override
  Future<Result<WalletTopUpStart>> startBankTransfer(
    WalletBankTransferRequest request, {
    void Function(int sent, int total)? onProgress,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return Ok(
      WalletTopUpStart(
        topUp: _transfer(WalletTopUpStatus.review),
        checkoutUrl: '',
        nextAction: 'bank_transfer',
        replayed: false,
      ),
    );
  }

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
    final poor = scenario == 'empty' || scenario == 'sms_sheet_poor';
    return Ok(
      WalletOverview(
        available: true,
        balance: poor ? 0.1 : (paid ? 345.5 : _balance),
        currency: 'LYD',
        testMode: _testMode,
        topUpOptions: _options,
        recentTopUps: _recent,
        recentEntries: const [],
        settings: const WalletSettings(
          recordTopUpsAsExpenses: true,
          defaultExpenseCategoryName: 'خدمات دفتر',
        ),
        sms: SmsWallet(
          balance: _sms,
          price: 0.15,
          messagesLeft: (_sms * 1000).round() ~/ 150,
        ),
        // «كروت دفتر» switched on only where the voucher balance is the point
        // of the screen; elsewhere the page stays as a shop without cards
        // sees it.
        vouchers: _showsVouchers
            ? VoucherWallet(balance: _vouchers, enabled: true)
            : const VoucherWallet(balance: 0),
        plans: [
          WalletPlan(
            key: WalletPlan.remoteAccess,
            available: true,
            active: true,
            price: 50,
            until: _now.add(const Duration(days: 18)),
          ),
          WalletPlan(
            key: WalletPlan.ai,
            available: true,
            active: _aiUntil != null,
            price: 30,
            until: _aiUntil,
          ),
        ],
      ),
    );
  }

  bool get _showsVouchers =>
      scenario == 'vouchers' ||
      scenario == 'vouchers_sheet' ||
      scenario == 'history';

  // What the spending sheets move, so the page shows it after them.
  double _balance = 245.5;
  double _vouchers = 122;
  late double _sms = scenario == 'sms_empty' || scenario == 'empty' ? 0 : 4.5;
  DateTime? _aiUntil;

  @override
  Future<Result<WalletSmsAllocation>> allocateToSms({
    required String amount,
    required String idempotencyKey,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final value = double.parse(amount);
    _balance -= value;
    _sms += value;
    return Ok(
      WalletSmsAllocation(
        balance: _balance,
        sms: SmsWallet(
          balance: _sms,
          price: 0.15,
          messagesLeft: (_sms * 1000).round() ~/ 150,
        ),
        replayed: false,
      ),
    );
  }

  @override
  Future<Result<WalletVoucherAllocation>> allocateToVouchers({
    required String amount,
    required String idempotencyKey,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final value = double.parse(amount);
    _balance -= value;
    _vouchers += value;
    return Ok(
      WalletVoucherAllocation(
        balance: _balance,
        vouchers: VoucherWallet(balance: _vouchers, enabled: true),
        replayed: false,
      ),
    );
  }

  @override
  Future<Result<WalletPlanPurchase>> purchasePlan({
    required String plan,
    required int periods,
    required String idempotencyKey,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final price = plan == WalletPlan.ai ? 30.0 : 50.0;
    _balance -= price * periods;
    final until = _now.add(Duration(days: 30 * periods));
    if (plan == WalletPlan.ai) {
      _aiUntil = until;
    }
    return Ok(
      WalletPlanPurchase(
        plan: WalletPlan(
          key: plan,
          available: true,
          active: true,
          price: price,
          until: until,
        ),
        balance: _balance,
        replayed: false,
      ),
    );
  }

  @override
  Future<Result<WalletTopUpStart>> startTopUp({
    required String amount,
    required String method,
    required String idempotencyKey,
    bool? recordAsExpense,
    String userIdentifier = '',
    String birthYear = '',
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (scenario == 'sheet_error') {
      return Error(
        const WalletException(
          code: 'method_unavailable',
          message: '',
          statusCode: 422,
        ),
      );
    }
    final hostedPage = method == WalletTopUpMethod.bankCards;
    return Ok(
      WalletTopUpStart(
        topUp: _topUp(
          'new8k2m4q7x',
          double.parse(amount),
          WalletTopUpStatus.pending,
          method: method,
          payerHint: hostedPage ? '' : '091•••678',
          testMode: _testMode,
        ),
        checkoutUrl: hostedPage ? 'https://pay.dafa.test/preview' : '',
        nextAction: hostedPage
            ? WalletTopUpMethod.kindHostedPage
            : WalletTopUpMethod.kindOtp,
        replayed: false,
      ),
    );
  }

  @override
  Future<Result<WalletTopUpConfirmation>> confirmTopUp({
    required String id,
    required String otp,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    WalletTopUp topUp(WalletTopUpStatus status, {String errorCode = ''}) =>
        _topUp(
          id,
          100,
          status,
          method: 'dafa_sadad',
          payerHint: '091•••678',
          booked: status == WalletTopUpStatus.paid,
          errorCode: errorCode,
          testMode: _testMode,
        );
    switch (otp) {
      case '111111':
        _polls++;
        return Ok(
          WalletTopUpConfirmation(
            topUp: topUp(WalletTopUpStatus.paid),
            awaitingGateway: false,
          ),
        );
      case '222222':
        return Error(
          WalletException(
            code: 'declined',
            message: '',
            statusCode: 422,
            gatewayCode: 'PAYER_INSUFFICIENT_FUNDS',
            gatewayMessage: 'تعذّر إتمام العملية، يرجى مراجعة المصرف.',
            topUp: topUp(WalletTopUpStatus.failed, errorCode: 'declined'),
          ),
        );
      default:
        return Error(
          WalletException(
            code: 'otp_rejected',
            message: '',
            statusCode: 422,
            attemptsLeft: 4,
            topUp: topUp(WalletTopUpStatus.pending),
          ),
        );
    }
  }

  @override
  Future<Result<WalletTopUp>> cancelTopUp(String id) async =>
      Ok(_topUp(id, 100, WalletTopUpStatus.canceled, method: 'dafa_sadad'));

  @override
  Future<Result<WalletTopUp>> loadTopUp(String id) async {
    _polls++;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (scenario.startsWith('transfer')) {
      return Ok(
        _transfer(
          scenario == 'transfer_rejected'
              ? WalletTopUpStatus.rejected
              : WalletTopUpStatus.review,
        ),
      );
    }
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
  Future<Result<WalletPage<WalletEntry>>> loadEntries({
    String? before,
    WalletAccount account = WalletAccount.main,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (before != null) {
      return const Ok(WalletPage(items: [], hasMore: false));
    }
    if (account == WalletAccount.vouchers) {
      // Newest first, each balance following from the one before it: money
      // moved in, a card bought, a card the supplier could not deliver given
      // back, another card bought.
      return Ok(
        WalletPage(
          items: [
            WalletEntry(
              id: 'v4',
              account: WalletAccount.vouchers,
              kind: WalletEntryKind.charge,
              service: 'vouchers',
              amount: -128,
              balanceAfter: 122,
              createdAt: _now.subtract(const Duration(minutes: 35)),
              description: 'آيتونز · الولايات المتحدة · 25 دولار',
            ),
            WalletEntry(
              id: 'v3',
              account: WalletAccount.vouchers,
              kind: WalletEntryKind.refund,
              service: 'vouchers',
              amount: 9.7,
              balanceAfter: 250,
              createdAt: _now.subtract(const Duration(hours: 4)),
              description: 'استرداد: ليبيانا · ليبيا · 10 دينار',
            ),
            WalletEntry(
              id: 'v2',
              account: WalletAccount.vouchers,
              kind: WalletEntryKind.charge,
              service: 'vouchers',
              amount: -9.7,
              balanceAfter: 240.3,
              createdAt: _now.subtract(const Duration(hours: 4, minutes: 1)),
              description: 'ليبيانا · ليبيا · 10 دينار',
            ),
            WalletEntry(
              id: 'v1',
              account: WalletAccount.vouchers,
              kind: WalletEntryKind.transfer,
              amount: 250,
              balanceAfter: 250,
              createdAt: _now.subtract(const Duration(days: 1)),
              description: 'تحويل من المحفظة',
            ),
          ],
          hasMore: false,
        ),
      );
    }
    if (account == WalletAccount.sms) {
      return Ok(
        WalletPage(
          items: [
            WalletEntry(
              id: 's3',
              account: WalletAccount.sms,
              kind: WalletEntryKind.charge,
              service: 'sms',
              amount: -0.15,
              balanceAfter: 4.5,
              createdAt: _now.subtract(const Duration(minutes: 20)),
              description: 'رسالة: فاتورة بيع',
            ),
            WalletEntry(
              id: 's2',
              account: WalletAccount.sms,
              kind: WalletEntryKind.refund,
              service: 'sms',
              amount: 0.15,
              balanceAfter: 4.65,
              createdAt: _now.subtract(const Duration(hours: 2)),
              description: 'استرداد رسالة لم تُرسل',
            ),
            WalletEntry(
              id: 's1',
              account: WalletAccount.sms,
              kind: WalletEntryKind.transfer,
              amount: 5,
              balanceAfter: 5,
              createdAt: _now.subtract(const Duration(days: 2)),
              description: 'تحويل من المحفظة',
            ),
          ],
          hasMore: false,
        ),
      );
    }
    return Ok(
      WalletPage(
        items: [
          WalletEntry(
            id: 'e4',
            kind: WalletEntryKind.transfer,
            amount: -5,
            balanceAfter: 245.5,
            createdAt: _now.subtract(const Duration(days: 2)),
            description: 'تحويل إلى رصيد الرسائل',
          ),
          WalletEntry(
            id: 'e3',
            kind: WalletEntryKind.topUp,
            amount: 200,
            balanceAfter: 250,
            createdAt: _now.subtract(const Duration(hours: 3)),
            description: 'شحن عبر سداد DFW-PAID7WQ2X4',
          ),
          WalletEntry(
            id: 'e2',
            kind: WalletEntryKind.charge,
            service: 'remote_access',
            amount: -50,
            balanceAfter: 50,
            createdAt: _now.subtract(const Duration(days: 12)),
            description: 'اشتراك الوصول عن بُعد حتى 2026-10-20',
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
  _FakeSubscriptionRepository(this.wallet) : super(PosApiService());

  /// Read for what the spending sheets bought, so the page follows them.
  final _FakeWalletRepository wallet;

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
        relayEnabled: false,
        subscriptionActive: false,
        aiEnabled: false,
        remoteAccessUntil: _now.add(const Duration(days: 18)),
        aiUntil: wallet._aiUntil,
        aiAvailable: wallet._aiUntil != null,
        smsAvailable: wallet._sms >= 0.15,
        lastSyncedAt: _now.subtract(const Duration(minutes: 5)),
        connectorLastSeenAt: _now.subtract(const Duration(seconds: 40)),
        connectorVersion: '1.4.0',
      ),
    );
  }
}
