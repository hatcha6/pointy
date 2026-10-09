import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/data/repositories/wallet_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';

WalletTopUp topUp({
  WalletTopUpStatus status = WalletTopUpStatus.pending,
  String errorCode = '',
  String method = WalletTopUpMethod.bankCards,
  String? checkoutUrl = 'https://pay.dafa.test/pay-1',
  int? expenseId,
}) {
  final hostedPage = method == WalletTopUpMethod.bankCards;
  return WalletTopUp(
    id: 'topup-1',
    invoiceNo: 'DFW-ABCDEFGH23',
    method: method,
    kind: hostedPage
        ? WalletTopUpMethod.kindHostedPage
        : WalletTopUpMethod.kindOtp,
    payerHint: hostedPage ? '' : '091•••678',
    amount: 100,
    status: status,
    testMode: false,
    createdAt: DateTime(2026, 9, 30, 10),
    errorCode: errorCode,
    checkoutUrl: status == WalletTopUpStatus.pending && hostedPage
        ? checkoutUrl
        : null,
    expenseId: expenseId,
  );
}

WalletTopUp sadadTopUp({
  WalletTopUpStatus status = WalletTopUpStatus.pending,
  String errorCode = '',
  int? expenseId,
}) => topUp(
  status: status,
  errorCode: errorCode,
  method: 'dafa_sadad',
  expenseId: expenseId,
);

const bankCards = WalletTopUpMethod(
  key: WalletTopUpMethod.bankCards,
  gateway: 'dafa',
  provider: 'moamalat',
  kind: WalletTopUpMethod.kindHostedPage,
);
const sadad = WalletTopUpMethod(
  key: 'dafa_sadad',
  gateway: 'dafa',
  provider: 'sadad',
  kind: WalletTopUpMethod.kindOtp,
  payer: WalletPayer.phone,
  needsBirthYear: true,
);
const yussor = WalletTopUpMethod(
  key: 'dafa_yussor_pay',
  gateway: 'dafa',
  provider: 'yussor-pay',
  kind: WalletTopUpMethod.kindOtp,
  payer: WalletPayer.card,
);

WalletOverview overview({
  double balance = 50,
  bool recordExpenses = true,
  Duration ttl = const Duration(minutes: 30),
  List<WalletTopUpMethod> methods = const [bankCards, sadad, yussor],
  SmsWallet? sms,
  VoucherWallet? vouchers,
  List<WalletPlan> plans = const [],
}) {
  return WalletOverview(
    available: true,
    balance: balance,
    currency: 'LYD',
    testMode: false,
    topUpOptions: WalletTopUpOptions(
      available: true,
      methods: methods,
      minAmount: 10,
      maxAmount: 5000,
      maxDecimals: 2,
      quickAmounts: const [50, 100],
      pendingTtl: ttl,
    ),
    recentTopUps: const [],
    recentEntries: const [],
    settings: WalletSettings(
      recordTopUpsAsExpenses: recordExpenses,
      defaultExpenseCategoryName: 'خدمات دفتر',
    ),
    sms: sms,
    vouchers: vouchers,
    plans: plans,
  );
}

class FakeWalletRepository extends WalletRepository {
  FakeWalletRepository() : super(PosApiService());

  Result<WalletOverview> walletResult = Ok(overview());
  Result<WalletTopUpStart> startResult = Ok(
    WalletTopUpStart(
      topUp: topUp(),
      checkoutUrl: 'https://pay.dafa.test/pay-1',
      nextAction: WalletTopUpMethod.kindHostedPage,
      replayed: false,
    ),
  );
  Result<WalletTopUp> topUpResult = Ok(topUp());
  Result<WalletTopUpConfirmation> confirmResult = Ok(
    WalletTopUpConfirmation(
      topUp: sadadTopUp(status: WalletTopUpStatus.paid, expenseId: 9),
      awaitingGateway: false,
    ),
  );
  Result<WalletSettings> settingsResult = const Ok(
    WalletSettings(recordTopUpsAsExpenses: false),
  );
  final List<Result<WalletPage<WalletTopUp>>> topUpPages = [];
  final List<Result<WalletPage<WalletEntry>>> entryPages = [];

  int walletLoads = 0;
  int topUpLoads = 0;
  final List<Map<String, Object?>> starts = [];
  final List<String> codes = [];
  final List<String> cancels = [];
  final List<String?> topUpPageCursors = [];

  @override
  Future<Result<WalletOverview>> loadWallet() async {
    walletLoads++;
    return walletResult;
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
    starts.add({
      'amount': amount,
      'method': method,
      'key': idempotencyKey,
      'record': recordAsExpense,
      'payer': userIdentifier,
      'birth': birthYear,
    });
    return startResult;
  }

  @override
  Future<Result<WalletTopUpConfirmation>> confirmTopUp({
    required String id,
    required String otp,
  }) async {
    codes.add(otp);
    return confirmResult;
  }

  @override
  Future<Result<WalletTopUp>> cancelTopUp(String id) async {
    cancels.add(id);
    return Ok(sadadTopUp(status: WalletTopUpStatus.canceled));
  }

  @override
  Future<Result<WalletTopUp>> loadTopUp(String id) async {
    topUpLoads++;
    return topUpResult;
  }

  @override
  Future<Result<WalletSettings>> updateSettings({
    required bool recordTopUpsAsExpenses,
  }) async => settingsResult;

  @override
  Future<Result<WalletPage<WalletTopUp>>> loadTopUps({String? before}) async {
    topUpPageCursors.add(before);
    return topUpPages.removeAt(0);
  }

  @override
  Future<Result<WalletPage<WalletEntry>>> loadEntries({
    String? before,
    WalletAccount account = WalletAccount.main,
  }) async {
    entryAccounts.add(account);
    return entryPages.removeAt(0);
  }

  final List<WalletAccount> entryAccounts = [];
  final List<Map<String, Object?>> allocations = [];
  final List<Map<String, Object?>> purchases = [];
  final List<Map<String, Object?>> voucherAllocations = [];
  Result<WalletVoucherAllocation> voucherAllocationResult = const Ok(
    WalletVoucherAllocation(
      balance: 50,
      vouchers: VoucherWallet(balance: 150, enabled: true),
      replayed: false,
    ),
  );
  Result<WalletSmsAllocation> allocationResult = const Ok(
    WalletSmsAllocation(
      balance: 85,
      sms: SmsWallet(balance: 15, price: 0.15, messagesLeft: 100),
      replayed: false,
    ),
  );
  Result<WalletPlanPurchase> purchaseResult = Ok(
    WalletPlanPurchase(
      plan: WalletPlan(
        key: WalletPlan.ai,
        available: true,
        active: true,
        price: 30,
        until: DateTime(2026, 11, 1),
      ),
      balance: 70,
      replayed: false,
    ),
  );

  @override
  Future<Result<WalletSmsAllocation>> allocateToSms({
    required String amount,
    required String idempotencyKey,
  }) async {
    allocations.add({'amount': amount, 'key': idempotencyKey});
    return allocationResult;
  }

  @override
  Future<Result<WalletVoucherAllocation>> allocateToVouchers({
    required String amount,
    required String idempotencyKey,
  }) async {
    voucherAllocations.add({'amount': amount, 'key': idempotencyKey});
    return voucherAllocationResult;
  }

  @override
  Future<Result<WalletPlanPurchase>> purchasePlan({
    required String plan,
    required int periods,
    required String idempotencyKey,
  }) async {
    purchases.add({'plan': plan, 'periods': periods, 'key': idempotencyKey});
    return purchaseResult;
  }
}

/// A code-confirmed start: the provider texted the payer a code.
Result<WalletTopUpStart> codeStart() => Ok(
  WalletTopUpStart(
    topUp: sadadTopUp(),
    checkoutUrl: '',
    nextAction: WalletTopUpMethod.kindOtp,
    replayed: false,
  ),
);

void main() {
  late FakeWalletRepository repo;
  late List<Uri> opened;
  late DateTime now;
  late int keys;
  late bool browserOpens;

  WalletViewModel build() => WalletViewModel(
    repo,
    launchCheckout: (uri) async {
      opened.add(uri);
      return browserOpens;
    },
    clock: () => now,
    newAttemptKey: () => 'key-${++keys}',
    // Long enough that the timer never fires inside a test: every poll here
    // is an explicit checkActiveTopUp().
    fastPollInterval: const Duration(hours: 1),
    slowPollInterval: const Duration(hours: 2),
  );

  setUp(() {
    repo = FakeWalletRepository();
    opened = [];
    now = DateTime(2026, 9, 30, 10);
    keys = 0;
    browserOpens = true;
  });

  test('load keeps the overview, or says it failed', () async {
    final vm = build();
    await vm.load();
    expect(vm.overview?.balance, 50);
    expect(vm.hasLoadError, isFalse);

    repo.walletResult = Error(Exception('offline'));
    final failing = build();
    await failing.load();
    expect(failing.overview, isNull);
    expect(failing.hasLoadError, isTrue);
  });

  test('a top-up opens the checkout, polls, and lands on paid', () async {
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    await vm.startTopUp(100);

    expect(repo.starts.single, {
      'amount': '100',
      'method': WalletTopUpMethod.bankCards,
      'key': 'key-1',
      'record': true,
      'payer': '',
      'birth': '',
    });
    expect(opened.single.toString(), 'https://pay.dafa.test/pay-1');
    expect(vm.awaitingHostedPage, isTrue);
    expect(vm.topUpStage, WalletTopUpStage.awaitingPayment);
    expect(vm.isPolling, isTrue);

    // Still pending: keep waiting.
    await vm.checkActiveTopUp();
    expect(vm.topUpStage, WalletTopUpStage.awaitingPayment);

    repo.topUpResult = Ok(topUp(status: WalletTopUpStatus.paid, expenseId: 7));
    final loadsBefore = repo.walletLoads;
    await vm.checkActiveTopUp();
    expect(vm.topUpStage, WalletTopUpStage.paid);
    expect(vm.activeTopUp?.isBookedAsExpense, isTrue);
    expect(vm.isPolling, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(repo.walletLoads, loadsBefore + 1, reason: 'the balance moved');
    vm.dispose();
  });

  test('each verdict has its own stage', () async {
    for (final (status, stage) in [
      (WalletTopUpStatus.canceled, WalletTopUpStage.canceled),
      (WalletTopUpStatus.failed, WalletTopUpStage.failed),
      (WalletTopUpStatus.expired, WalletTopUpStage.unconfirmed),
    ]) {
      final vm = build();
      await vm.load();
      vm.beginTopUp();
      await vm.startTopUp(100);
      repo.topUpResult = Ok(topUp(status: status));
      await vm.checkActiveTopUp();
      expect(vm.topUpStage, stage, reason: '$status');
      expect(vm.isPolling, isFalse);
      vm.dispose();
      repo.topUpResult = Ok(topUp());
    }
  });

  test('a failed poll is not a verdict', () async {
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    await vm.startTopUp(100);
    repo.topUpResult = Error(Exception('blip'));
    await vm.checkActiveTopUp();
    expect(vm.topUpStage, WalletTopUpStage.awaitingPayment);
    expect(vm.isPolling, isTrue);
    vm.dispose();
  });

  test(
    'no verdict after the checkout window: unconfirmed, and stop asking',
    () async {
      final vm = build();
      await vm.load();
      vm.beginTopUp();
      await vm.startTopUp(100);
      now = now.add(const Duration(minutes: 33));
      await vm.checkActiveTopUp();
      expect(vm.topUpStage, WalletTopUpStage.unconfirmed);
      expect(vm.isPolling, isFalse);
    },
  );

  test('a refused amount goes back to the form with the reason', () async {
    repo.startResult = Error(
      const WalletException(
        code: 'invalid_amount',
        message: '',
        minAmount: 10,
        maxAmount: 5000,
      ),
    );
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    await vm.startTopUp(7);
    expect(vm.topUpStage, WalletTopUpStage.form);
    expect(vm.topUpError?.code, 'invalid_amount');
    expect(opened, isEmpty);
    // A definitive refusal ends the attempt: the next try is a new key.
    await vm.startTopUp(7);
    expect(repo.starts.map((s) => s['key']), ['key-1', 'key-2']);
  });

  test(
    'a dropped response retries the SAME attempt; a new amount is a new one',
    () async {
      repo.startResult = Error(Exception('socket closed'));
      final vm = build();
      await vm.load();
      vm.beginTopUp();
      await vm.startTopUp(100);
      expect(vm.topUpError?.code, 'network');
      await vm.startTopUp(100);
      await vm.startTopUp(200);
      expect(repo.starts.map((s) => s['key']), ['key-1', 'key-1', 'key-2']);
    },
  );

  test(
    'a replayed top-up that already has a verdict does not reopen the browser',
    () async {
      repo.startResult = Ok(
        WalletTopUpStart(
          topUp: topUp(status: WalletTopUpStatus.paid),
          checkoutUrl: '',
          replayed: true,
        ),
      );
      final vm = build();
      await vm.load();
      vm.beginTopUp();
      await vm.startTopUp(100);
      expect(vm.topUpStage, WalletTopUpStage.paid);
      expect(opened, isEmpty);
      expect(vm.isPolling, isFalse);
    },
  );

  test('a browser that will not open offers the link instead', () async {
    browserOpens = false;
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    await vm.startTopUp(100);
    expect(vm.checkoutOpenFailed, isTrue);
    expect(vm.topUpStage, WalletTopUpStage.awaitingPayment);
    vm.dispose();
  });

  test('only an https checkout is ever opened', () async {
    repo.startResult = Ok(
      WalletTopUpStart(
        topUp: topUp(checkoutUrl: null),
        checkoutUrl: 'http://evil.example/pay',
        replayed: false,
      ),
    );
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    await vm.startTopUp(100);
    expect(opened, isEmpty);
    expect(vm.checkoutOpenFailed, isTrue);
    vm.dispose();
  });

  test('closing the sheet stops asking', () async {
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    await vm.startTopUp(100);
    vm.endTopUp();
    expect(vm.isPolling, isFalse);
    expect(vm.topUpStage, WalletTopUpStage.form);
    final polls = repo.topUpLoads;
    await vm.checkActiveTopUp();
    expect(repo.topUpLoads, polls);
  });

  test(
    'the sheet switch starts at the setting and is sent with the top-up',
    () async {
      repo.walletResult = Ok(overview(recordExpenses: false));
      final vm = build();
      await vm.load();
      vm.beginTopUp();
      expect(vm.recordAsExpense, isFalse);
      vm.setRecordAsExpense(true);
      await vm.startTopUp(100);
      expect(repo.starts.single['record'], isTrue);
      expect(vm.recordTopUpsAsExpenses, isTrue, reason: 'saved as the default');
      vm.dispose();
    },
  );

  test(
    'the books switch saves, and puts itself back when saving fails',
    () async {
      final vm = build();
      await vm.load();
      expect(await vm.setRecordTopUpsAsExpenses(false), isTrue);
      expect(vm.recordTopUpsAsExpenses, isFalse);

      repo.settingsResult = Error(Exception('offline'));
      expect(await vm.setRecordTopUpsAsExpenses(true), isFalse);
      expect(vm.recordTopUpsAsExpenses, isFalse);
      expect(vm.settingsSaveFailed, isTrue);
    },
  );

  test(
    'the form starts on the first method offered and keeps the pick',
    () async {
      final vm = build();
      await vm.load();
      vm.beginTopUp();
      expect(vm.selectedMethod?.key, WalletTopUpMethod.bankCards);
      vm.selectMethod('dafa_sadad');
      expect(vm.selectedMethod?.key, 'dafa_sadad');
      vm.beginTopUp();
      expect(vm.selectedMethod?.key, 'dafa_sadad', reason: 'kept next time');
      // Withdrawn by the company: back to the first one offered.
      repo.walletResult = Ok(overview(methods: const [yussor, bankCards]));
      await vm.load();
      expect(vm.selectedMethod?.key, 'dafa_yussor_pay');
    },
  );

  test('a code method asks for the code, then lands on paid', () async {
    repo.startResult = codeStart();
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    vm.selectMethod('dafa_sadad');
    await vm.startTopUp(
      10.5,
      userIdentifier: ' 0912345678 ',
      birthYear: '1990',
    );
    expect(repo.starts.single, {
      'amount': '10.5',
      'method': 'dafa_sadad',
      'key': 'key-1',
      'record': true,
      'payer': '0912345678',
      'birth': '1990',
    });
    expect(vm.topUpStage, WalletTopUpStage.awaitingCode);
    expect(opened, isEmpty, reason: 'nothing to open for a texted code');
    expect(vm.isPolling, isFalse);

    final loadsBefore = repo.walletLoads;
    await vm.confirmCode('111111');
    expect(repo.codes, ['111111']);
    expect(vm.topUpStage, WalletTopUpStage.paid);
    expect(vm.activeTopUp?.isBookedAsExpense, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(repo.walletLoads, loadsBefore + 1, reason: 'the balance moved');
  });

  test('a wrong code stays on the code step with the tries left', () async {
    repo.startResult = codeStart();
    repo.confirmResult = Error(
      WalletException(
        code: 'otp_rejected',
        message: '',
        attemptsLeft: 4,
        topUp: sadadTopUp(),
      ),
    );
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    vm.selectMethod('dafa_sadad');
    await vm.startTopUp(100, userIdentifier: '0912345678', birthYear: '1990');
    await vm.confirmCode('123456');
    expect(vm.topUpStage, WalletTopUpStage.awaitingCode);
    expect(vm.codeError?.code, 'otp_rejected');
    expect(vm.codeError?.attemptsLeft, 4);
    await Future<void>.delayed(Duration.zero);
    expect(repo.topUpLoads, 0, reason: 'a wrong code is a verdict on the code');

    // The next code clears the old complaint.
    repo.confirmResult = Ok(
      WalletTopUpConfirmation(
        topUp: sadadTopUp(status: WalletTopUpStatus.paid),
        awaitingGateway: false,
      ),
    );
    await vm.confirmCode('111111');
    expect(vm.codeError, isNull);
    expect(vm.topUpStage, WalletTopUpStage.paid);
  });

  test('a decline ends the top-up with the gateway\'s own words', () async {
    repo.startResult = codeStart();
    repo.confirmResult = Error(
      WalletException(
        code: 'declined',
        message: '',
        gatewayCode: 'PAYER_INSUFFICIENT_FUNDS',
        gatewayMessage: 'تعذّر إتمام العملية، يرجى مراجعة المصرف.',
        topUp: sadadTopUp(
          status: WalletTopUpStatus.failed,
          errorCode: 'declined',
        ),
      ),
    );
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    vm.selectMethod('dafa_sadad');
    await vm.startTopUp(100, userIdentifier: '0912345678', birthYear: '1990');
    await vm.confirmCode('222222');
    expect(vm.topUpStage, WalletTopUpStage.failed);
    expect(vm.verdictError?.gatewayMessage, contains('المصرف'));
    expect(vm.codeError, isNull);
  });

  test('a lost answer is checked before the code is asked again', () async {
    repo.startResult = codeStart();
    repo.confirmResult = Error(
      WalletException(
        code: 'confirm_unknown',
        message: '',
        topUp: sadadTopUp(),
      ),
    );
    repo.topUpResult = Ok(sadadTopUp(status: WalletTopUpStatus.paid));
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    vm.selectMethod('dafa_sadad');
    await vm.startTopUp(100, userIdentifier: '0912345678', birthYear: '1990');
    await vm.confirmCode('111111');
    expect(vm.codeError?.code, 'confirm_unknown');
    await Future<void>.delayed(Duration.zero);
    expect(repo.topUpLoads, 1);
    expect(vm.topUpStage, WalletTopUpStage.paid, reason: 'it went through');
    expect(vm.codeError, isNull);
  });

  test(
    'a code taken without a verdict is followed like a card payment',
    () async {
      repo.startResult = codeStart();
      repo.confirmResult = Ok(
        WalletTopUpConfirmation(topUp: sadadTopUp(), awaitingGateway: true),
      );
      final vm = build();
      await vm.load();
      vm.beginTopUp();
      vm.selectMethod('dafa_sadad');
      await vm.startTopUp(100, userIdentifier: '0912345678', birthYear: '1990');
      await vm.confirmCode('111111');
      expect(vm.topUpStage, WalletTopUpStage.awaitingPayment);
      expect(vm.awaitingHostedPage, isFalse, reason: 'no page to reopen');
      expect(vm.isPolling, isTrue);
      repo.topUpResult = Ok(sadadTopUp(status: WalletTopUpStatus.paid));
      await vm.checkActiveTopUp();
      expect(vm.topUpStage, WalletTopUpStage.paid);
      expect(opened, isEmpty);
      vm.dispose();
    },
  );

  test(
    'changing the details calls the waiting payment off; the next is new',
    () async {
      repo.startResult = codeStart();
      final vm = build();
      await vm.load();
      vm.beginTopUp();
      vm.selectMethod('dafa_sadad');
      await vm.startTopUp(100, userIdentifier: '0912345678', birthYear: '1990');
      vm.changeDetails();
      expect(repo.cancels, ['topup-1']);
      expect(vm.topUpStage, WalletTopUpStage.form);
      expect(vm.activeTopUp, isNull);
      await vm.startTopUp(100, userIdentifier: '0912345678', birthYear: '1990');
      expect(repo.starts.map((start) => start['key']), ['key-1', 'key-2']);
    },
  );

  test('closing the sheet on the code step calls the payment off', () async {
    repo.startResult = codeStart();
    final vm = build();
    await vm.load();
    vm.beginTopUp();
    vm.selectMethod('dafa_sadad');
    await vm.startTopUp(100, userIdentifier: '0912345678', birthYear: '1990');
    vm.endTopUp();
    expect(repo.cancels, ['topup-1']);
    // A card payment is never called off: the payer may be on the page.
    repo.startResult = Ok(
      WalletTopUpStart(
        topUp: topUp(),
        checkoutUrl: 'https://pay.dafa.test/pay-1',
        nextAction: WalletTopUpMethod.kindHostedPage,
        replayed: false,
      ),
    );
    vm.beginTopUp();
    vm.selectMethod(WalletTopUpMethod.bankCards);
    await vm.startTopUp(100);
    vm.endTopUp();
    expect(repo.cancels, ['topup-1']);
  });

  test('the amount goes out without trailing zeros, at most three places', () {
    expect(walletAmountText(100, 3), '100');
    expect(walletAmountText(10.5, 3), '10.5');
    expect(walletAmountText(10.125, 3), '10.125');
    expect(walletAmountText(10.5, 2), '10.5');
    expect(walletAmountText(25, 0), '25');
  });

  test(
    'a failed history page keeps "more" so the next scroll retries it',
    () async {
      repo.topUpPages.addAll([
        Ok(
          WalletPage(
            items: [topUp(status: WalletTopUpStatus.paid)],
            hasMore: true,
          ),
        ),
        Error(Exception('offline')),
        const Ok(WalletPage(items: [], hasMore: false)),
      ]);
      final vm = build();
      await vm.loadHistoryTopUps(reset: true);
      expect(vm.historyTopUps, hasLength(1));
      await vm.loadHistoryTopUps();
      expect(vm.historyTopUpsFailed, isTrue);
      expect(vm.historyTopUpsHasMore, isTrue);
      await vm.loadHistoryTopUps();
      expect(vm.historyTopUpsHasMore, isFalse);
      expect(repo.topUpPageCursors, [null, 'topup-1', 'topup-1']);
    },
  );
}
