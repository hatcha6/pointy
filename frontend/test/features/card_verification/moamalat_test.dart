import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/moamalat.dart';
import 'package:pointy_frontend/src/data/repositories/moamalat_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/card_verification/view_models/moamalat_link_view_model.dart';
import 'package:pointy_frontend/src/features/card_verification/view_models/moamalat_live_watch.dart';
import 'package:pointy_frontend/src/features/card_verification/view_models/swipe_plan.dart';
import 'package:pointy_frontend/src/features/card_verification/views/moamalat_live_line.dart';
import 'package:pointy_frontend/src/features/card_verification/views/moamalat_page.dart';
import 'package:pointy_frontend/src/features/pos/views/payment/payment.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

class _FakeMoamalatRepository extends MoamalatRepository {
  _FakeMoamalatRepository() : super(PosApiService());

  MoamalatWatch answer = const MoamalatWatch(
    state: MoamalatLinkState.alive,
    watching: true,
  );
  bool failWatch = false;
  final watched = <double?>[];
  final lookbacks = <Duration?>[];

  MoamalatStatus status = const MoamalatStatus(canManage: true);
  Exception? linkFailure;
  String? sentPassword;

  @override
  Future<Result<MoamalatWatch>> watch({
    double? amount,
    Duration? lookback,
  }) async {
    watched.add(amount);
    lookbacks.add(lookback);
    if (failWatch) return Error(Exception('offline'));
    return Ok(answer);
  }

  @override
  Future<Result<MoamalatStatus>> loadStatus() async => Ok(status);

  @override
  Future<Result<String>> startLink({
    required String username,
    required String password,
  }) async {
    sentPassword = password;
    final failure = linkFailure;
    return failure == null ? const Ok('challenge') : Error(failure);
  }

  @override
  Future<Result<MoamalatLinked>> verifyLink({
    required String challengeId,
    required String code,
  }) async {
    final failure = linkFailure;
    if (failure != null) return Error(failure);
    status = const MoamalatStatus(
      state: MoamalatLinkState.alive,
      canManage: true,
      mid: '000000000145771',
      merchantName: 'CARD SHOP',
      username: 'shop-user',
    );
    return Ok(
      MoamalatLinked(
        status: status,
        merchants: const [
          MoamalatMerchant(mid: '000000000145771', name: 'CARD SHOP'),
        ],
      ),
    );
  }
}

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('ar'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  theme: PointyTheme.light(),
  home: Scaffold(body: child),
);

MoamalatSwipe _swipe(String rrn, double amount) => MoamalatSwipe(
  rrn: rrn,
  terminalId: '0JNSWZ11',
  amount: amount,
  at: DateTime(2026, 10, 14, 18, 50),
);

MoamalatWatch _seeing(List<MoamalatSwipe> swipes) => MoamalatWatch(
  state: MoamalatLinkState.alive,
  watching: true,
  swipes: swipes,
);

String _amount(WidgetTester tester, int index) => tester
    .widget<TextField>(find.byKey(ValueKey('payment_tender_amount_$index')))
    .controller!
    .text;

Future<void> _pumpSheet(
  WidgetTester tester,
  _FakeMoamalatRepository repository, {
  bool cash = false,
}) async {
  tester.view.physicalSize = const Size(1366, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    _app(
      SizedBox.expand(
        child: PaymentSheet(
          total: 25,
          enableCashPayments: cash,
          enableCardPayments: true,
          enableTransferPayments: false,
          requireCardReceipt: false,
          trustedCardTerminalIds: const [],
          showPrintInvoiceToggle: false,
          printInvoiceAfterPayment: false,
          onPrintInvoiceChanged: (_) {},
          showShareInvoiceToggle: false,
          shareInvoiceAfterPayment: false,
          onShareInvoiceChanged: (_) {},
          moamalatRepository: repository,
          onSubmit: (_) {},
          onCancel: () {},
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Closing the sheet disposes its watch, which ends the polling timer.
Future<void> _close(WidgetTester tester) =>
    tester.pumpWidget(_app(const SizedBox()));

void main() {
  group('MoamalatLiveWatch never keeps Moamalat busy', () {
    test('stops after the ceiling however long the sheet stays open', () async {
      var now = DateTime(2026, 10, 14, 10);
      final repository = _FakeMoamalatRepository();
      final watch = MoamalatLiveWatch(
        repository,
        interval: const Duration(milliseconds: 5),
        maxOpen: const Duration(minutes: 10),
        clock: () => now,
      );
      addTearDown(watch.dispose);
      watch.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(watch.isPolling, isTrue);
      now = now.add(const Duration(minutes: 10));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(watch.isPolling, isFalse);
      final polls = repository.watched.length;
      watch.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(repository.watched.length, polls, reason: 'never restarts');
    });

    test('asks for swipes from before the sheet opened', () async {
      final now = DateTime(2026, 10, 14, 10);
      final repository = _FakeMoamalatRepository();
      final watch = MoamalatLiveWatch(
        repository,
        interval: const Duration(minutes: 1),
        clock: () => now,
      );
      addTearDown(watch.dispose);
      watch.start();
      await Future<void>.delayed(Duration.zero);
      expect(repository.lookbacks.single, const Duration(minutes: 10));
      expect(repository.watched.single, isNull, reason: 'every amount');
    });

    test('stops after a few failed polls', () async {
      final repository = _FakeMoamalatRepository()..failWatch = true;
      final watch = MoamalatLiveWatch(
        repository,
        interval: const Duration(milliseconds: 2),
      );
      addTearDown(watch.dispose);
      watch.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(watch.isPolling, isFalse);
      expect(repository.watched.length, 3);
    });

    test('stops at once when there is no live link to watch', () async {
      final repository = _FakeMoamalatRepository()
        ..answer = const MoamalatWatch(state: MoamalatLinkState.unlinked);
      final watch = MoamalatLiveWatch(
        repository,
        interval: const Duration(milliseconds: 2),
      );
      addTearDown(watch.dispose);
      watch.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(watch.isPolling, isFalse);
      expect(repository.watched.length, 1);
    });

    test('disposing it (the sheet closing) stops it', () async {
      final repository = _FakeMoamalatRepository();
      final watch = MoamalatLiveWatch(
        repository,
        interval: const Duration(milliseconds: 2),
      );
      watch.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      watch.dispose();
      final polls = repository.watched.length;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(repository.watched.length, polls);
    });
  });

  group('planSwipes', () {
    SwipeTender card(int index, double amount) =>
        SwipeTender(index: index, isCard: true, amount: amount);
    SwipeTender cash(int index, double amount) =>
        SwipeTender(index: index, isCard: false, amount: amount);

    test('an exact swipe proves its line', () {
      final plan = planSwipes(
        tenders: [card(0, 25)],
        swipes: [_swipe('a', 25)],
      );
      expect(plan.seen[0]?.rrn, 'a');
      expect(plan.suggestions, isEmpty);
      expect(plan.automatic, isNull);
    });

    test('one smaller stray swipe for one waiting line is fixed by itself', () {
      final plan = planSwipes(
        tenders: [card(0, 25)],
        swipes: [_swipe('a', 20)],
      );
      expect(plan.automatic?.action, SwipeAction.splitShortfall);
      expect(plan.automatic?.tenderIndex, 0);
    });

    test('a bigger swipe is only ever a warning', () {
      final plan = planSwipes(
        tenders: [card(0, 25)],
        swipes: [_swipe('a', 30)],
      );
      expect(plan.automatic, isNull);
      expect(plan.suggestions.single.action, SwipeAction.overcharged);
    });

    test('two stray swipes are offered, never guessed between', () {
      final plan = planSwipes(
        tenders: [card(0, 25)],
        swipes: [_swipe('a', 20), _swipe('b', 18)],
      );
      expect(plan.automatic, isNull);
      expect(plan.suggestions.map((s) => s.swipe.rrn), ['b', 'a']);
    });

    test('a swipe taken before the sheet opened is offered on a cash line', () {
      final plan = planSwipes(
        tenders: [cash(0, 25)],
        swipes: [_swipe('a', 25)],
      );
      expect(plan.automatic, isNull);
      expect(plan.suggestions.single.action, SwipeAction.useAsCard);
    });

    test('a stray swipe beside a proven card line is left alone', () {
      final plan = planSwipes(
        tenders: [card(0, 25)],
        swipes: [_swipe('mine', 25), _swipe('other', 7)],
      );
      expect(plan.seen[0]?.rrn, 'mine');
      expect(plan.suggestions, isEmpty);
    });

    test('ignored swipes are left out', () {
      final plan = planSwipes(
        tenders: [card(0, 25)],
        swipes: [_swipe('a', 20)],
        ignored: {'a'},
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  testWidgets('the live line says when the swipe reached Moamalat', (
    tester,
  ) async {
    final repository = _FakeMoamalatRepository();
    final watch = MoamalatLiveWatch(repository);
    addTearDown(watch.dispose);
    await tester.pumpWidget(
      _app(
        ListenableBuilder(
          listenable: watch,
          builder: (context, _) => MoamalatLiveLine(
            watch: watch,
            swipe: watch.swipes.isEmpty ? null : watch.swipes.first,
          ),
        ),
      ),
    );
    watch.start();
    await tester.pump();
    expect(find.text('بانتظار عملية البطاقة من الجهاز…'), findsOneWidget);
    repository.answer = _seeing([_swipe('627416000329', 25)]);
    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining('وصلت عملية بطاقة'), findsOneWidget);
    watch.stop();
  });

  group('the payment sheet and the terminal', () {
    testWidgets('a short swipe splits the card line, and undo puts it back', (
      tester,
    ) async {
      final repository = _FakeMoamalatRepository()
        ..answer = _seeing([_swipe('r1', 20)]);
      await _pumpSheet(tester, repository);
      expect(_amount(tester, 0), '20.00');
      expect(_amount(tester, 1), '5.00');
      expect(
        find.byKey(const ValueKey('moamalat_correction_notice')),
        findsOneWidget,
      );
      expect(find.textContaining('وصلت عملية بطاقة'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('moamalat_correction_undo')));
      await tester.pump();
      expect(_amount(tester, 0), '25.00');
      expect(
        find.byKey(const ValueKey('payment_tender_amount_1')),
        findsNothing,
      );
      // Undone stays undone: offered, never re-applied by the next poll.
      await tester.pump(const Duration(seconds: 5));
      expect(_amount(tester, 0), '25.00');
      expect(find.byKey(const ValueKey('moamalat_use_r1')), findsOneWidget);
      await _close(tester);
    });

    testWidgets('a swipe taken before the sheet opened is offered on cash', (
      tester,
    ) async {
      final repository = _FakeMoamalatRepository()
        ..answer = _seeing([_swipe('early', 25)]);
      await _pumpSheet(tester, repository, cash: true);
      expect(_amount(tester, 0), '25.00');
      await tester.tap(find.byKey(const ValueKey('moamalat_use_early')));
      await tester.pump();
      expect(_amount(tester, 0), '25.00');
      expect(find.textContaining('وصلت عملية بطاقة'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('moamalat_swipe_suggestions')),
        findsNothing,
      );
      await _close(tester);
    });

    testWidgets('a smaller earlier swipe on cash leaves the rest on cash', (
      tester,
    ) async {
      final repository = _FakeMoamalatRepository()
        ..answer = _seeing([_swipe('early', 15)]);
      await _pumpSheet(tester, repository, cash: true);
      await tester.tap(find.byKey(const ValueKey('moamalat_use_early')));
      await tester.pump();
      expect(_amount(tester, 0), '15.00');
      expect(_amount(tester, 1), '10.00');
      await _close(tester);
    });

    testWidgets('an overcharge warns and changes nothing', (tester) async {
      final repository = _FakeMoamalatRepository()
        ..answer = _seeing([_swipe('big', 30)]);
      await _pumpSheet(tester, repository);
      expect(_amount(tester, 0), '25.00');
      expect(find.byKey(const ValueKey('moamalat_use_big')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('moamalat_ignore_big')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('moamalat_swipe_suggestions')),
        findsNothing,
      );
      await _close(tester);
    });

    testWidgets('closing the sheet stops the heartbeat', (tester) async {
      final repository = _FakeMoamalatRepository();
      await _pumpSheet(tester, repository);
      expect(find.byKey(const ValueKey('moamalat_live_line')), findsOneWidget);
      await _close(tester);
      final polls = repository.watched.length;
      await tester.pump(const Duration(seconds: 15));
      expect(repository.watched.length, polls);
    });
  });

  group('MoamalatLinkViewModel', () {
    test('links in two steps and never holds the password', () async {
      final repository = _FakeMoamalatRepository();
      final viewModel = MoamalatLinkViewModel(repository);
      await viewModel.load();
      expect(viewModel.status?.state, MoamalatLinkState.unlinked);
      expect(
        await viewModel.startLink(username: 'shop-user', password: 'secret'),
        isTrue,
      );
      expect(viewModel.step, MoamalatLinkStep.code);
      expect(await viewModel.verify('123456'), isTrue);
      expect(viewModel.status?.state, MoamalatLinkState.alive);
      expect(viewModel.step, MoamalatLinkStep.credentials);
      expect(viewModel.merchants.single.mid, '000000000145771');
    });

    test('an expired code sends the supervisor back to the start', () async {
      final repository = _FakeMoamalatRepository();
      final viewModel = MoamalatLinkViewModel(repository);
      await viewModel.startLink(username: 'u', password: 'p');
      repository.linkFailure = const MoamalatLinkFailure('challenge_expired');
      expect(await viewModel.verify('1'), isFalse);
      expect(viewModel.failure?.code, 'challenge_expired');
      expect(viewModel.step, MoamalatLinkStep.credentials);
    });
  });

  testWidgets('the page clears the password field the moment it is sent', (
    tester,
  ) async {
    final repository = _FakeMoamalatRepository();
    tester.view.physicalSize = const Size(1024, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(MoamalatPage(viewModel: MoamalatLinkViewModel(repository))),
    );
    await tester.pumpAndSettle();
    expect(find.text('غير مربوط'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'shop-user');
    await tester.enterText(fields.at(1), 'secret');
    await tester.tap(find.text('إرسال رمز التحقق'));
    await tester.pumpAndSettle();
    expect(repository.sentPassword, 'secret');
    expect(find.text('secret'), findsNothing);
    expect(find.text('رمز التحقق'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.tap(find.text('تأكيد الربط'));
    await tester.pumpAndSettle();
    expect(find.text('يعمل'), findsOneWidget);
    expect(find.text('CARD SHOP'), findsOneWidget);
  });
}
