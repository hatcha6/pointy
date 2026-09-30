import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';
import 'package:pointy_frontend/src/data/repositories/wallet_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/wallet_view_model.dart';

WalletTopUp topUp({
  WalletTopUpStatus status = WalletTopUpStatus.pending,
  String errorCode = '',
  String? checkoutUrl = 'https://checkout.plutus.test/pay/abc',
  int? expenseId,
}) {
  return WalletTopUp(
    id: 'topup-1',
    invoiceNo: 'DFW-ABCDEFGH23',
    method: WalletTopUpMethod.localBankCards,
    amount: 100,
    status: status,
    testMode: false,
    createdAt: DateTime(2026, 9, 30, 10),
    errorCode: errorCode,
    checkoutUrl: status == WalletTopUpStatus.pending ? checkoutUrl : null,
    expenseId: expenseId,
  );
}

WalletOverview overview({
  double balance = 50,
  bool recordExpenses = true,
  Duration ttl = const Duration(minutes: 30),
}) {
  return WalletOverview(
    available: true,
    balance: balance,
    currency: 'LYD',
    testMode: false,
    topUpOptions: WalletTopUpOptions(
      available: true,
      methods: const [
        WalletTopUpMethod(
          key: WalletTopUpMethod.localBankCards,
          gateway: 'plutu',
          kind: 'hosted_checkout',
        ),
      ],
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
  );
}

class FakeWalletRepository extends WalletRepository {
  FakeWalletRepository() : super(PosApiService());

  Result<WalletOverview> walletResult = Ok(overview());
  Result<WalletTopUpStart> startResult = Ok(
    WalletTopUpStart(
      topUp: topUp(),
      checkoutUrl: 'https://checkout.plutus.test/pay/abc',
      replayed: false,
    ),
  );
  Result<WalletTopUp> topUpResult = Ok(topUp());
  Result<WalletSettings> settingsResult = const Ok(
    WalletSettings(recordTopUpsAsExpenses: false),
  );
  final List<Result<WalletPage<WalletTopUp>>> topUpPages = [];
  final List<Result<WalletPage<WalletEntry>>> entryPages = [];

  int walletLoads = 0;
  int topUpLoads = 0;
  final List<Map<String, Object?>> starts = [];
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
  }) async {
    starts.add({
      'amount': amount,
      'method': method,
      'key': idempotencyKey,
      'record': recordAsExpense,
    });
    return startResult;
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
  Future<Result<WalletPage<WalletEntry>>> loadEntries({String? before}) async =>
      entryPages.removeAt(0);
}

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
      'amount': '100.00',
      'method': WalletTopUpMethod.localBankCards,
      'key': 'key-1',
      'record': true,
    });
    expect(opened.single.toString(), 'https://checkout.plutus.test/pay/abc');
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
