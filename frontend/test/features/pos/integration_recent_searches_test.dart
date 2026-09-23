import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/models/integration_recent_search.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/integration_recent_searches_view_model.dart';
import 'package:pointy_frontend/src/features/pos/view_models/integration_recharge_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/integration_recharge_screen.dart';

/// The top-up screen opens on the searches that worked before, not on an
/// empty box: most of an agency's trade is the same customers every month.
void main() {
  group('the recent searches list', () {
    test('reads the first page, and knows when there is more', () async {
      final repo = _Repo(searches: _cards(45));
      final list = _list(repo);
      await list.load();

      expect(list.searches, hasLength(20));
      expect(list.hasMore, isTrue);
      expect(repo.pages.single, (search: '', cursor: null));
    });

    test('the next page follows the cursor it was handed', () async {
      final repo = _Repo(searches: _cards(45));
      final list = _list(repo);
      await list.load();
      await list.loadMore();
      await list.loadMore();

      expect(list.searches, hasLength(45));
      expect(list.hasMore, isFalse);
      expect(repo.pages.map((p) => p.cursor), [null, '20', '40']);
    });

    test('a page that fails leaves the way to the rest open', () async {
      // Clearing hasMore on a failed page would freeze the list at the rows
      // it already had, for as long as the screen stays open.
      final repo = _Repo(searches: _cards(45))..failNextPage = true;
      final list = _list(repo);
      await list.load();
      await list.loadMore();

      expect(list.loadMoreFailed, isTrue);
      expect(list.hasMore, isTrue);
      expect(list.searches, hasLength(20));

      await list.loadMore();
      expect(list.loadMoreFailed, isFalse);
      expect(list.searches, hasLength(40));
      expect(repo.pages.map((p) => p.cursor), [null, '20', '20']);
    });

    test('narrowing asks again, but only when the text changed', () async {
      final repo = _Repo(searches: _cards(3));
      final list = _list(repo);
      await list.load();

      list.setQuery('0001');
      list.setQuery('0001 ');
      await _settle();

      expect(repo.pages.map((p) => p.search), ['', '0001']);
      expect(list.searches.single.term, '210900000001');
    });

    test('an answer to an older query never replaces a newer one', () async {
      final repo = _Repo(searches: _cards(3));
      final list = _list(repo);
      final slow = Completer<void>();
      repo.hold['21'] = slow;

      list.setQuery('21');
      list.setQuery('0002');
      await _settle();
      slow.complete();
      await _settle();

      expect(list.query, '0002');
      expect(list.searches.map((s) => s.term), ['210900000002']);
    });

    test('starting over re-reads even when nothing was typed', () async {
      // The search just run belongs at the top. A list that skipped reading
      // because its query was already empty would not show it there.
      final repo = _Repo(searches: _cards(1));
      final list = _list(repo);
      await list.load();
      await list.reset();

      expect(repo.pages, hasLength(2));
    });
  });

  group('running a search again', () {
    test('asks the provider with the mode it was asked in', () async {
      final repo = _Repo();
      final viewModel = _recharge(repo, IntegrationProviderKey.lnet);
      await viewModel.runRecentSearch(
        const IntegrationRecentSearch(
          id: 1,
          term: 'basheir.home',
          searchBy: 'username',
          cardNo: 'basheir.home',
        ),
      );

      // Letters must fit in the box it puts them in.
      expect(viewModel.searchMode, IntegrationSearchMode.username);
      expect(viewModel.allowsLetters, isTrue);
      expect(viewModel.searchText, 'basheir.home');
      expect(repo.lookups.single, (
        cardNo: 'basheir.home',
        searchBy: 'username',
      ));
    });

    test('choosing one of several lines searches it as a username', () async {
      // So the list remembers it as one, and running it from there opens a
      // box that can hold its letters.
      final repo = _Repo();
      final viewModel = _recharge(repo, IntegrationProviderKey.lnet);
      await viewModel.selectLine(
        const IntegrationCardInfo(cardNo: 'basheir.shop', providerId: '214740'),
      );

      expect(repo.lookups.single.searchBy, 'username');
      expect(
        viewModel.searchMode,
        IntegrationSearchMode.phone,
        reason: 'the picker is the cashier\'s and stays where they left it',
      );
    });

    test(
      'typing over a card on screen does not reload a hidden list',
      () async {
        final repo = _Repo(searches: _cards(2));
        final viewModel = _recharge(repo, IntegrationProviderKey.hdbox);
        await viewModel.recentSearches.load();
        await viewModel.lookup('210900000001');
        viewModel.setSearchText('2109000000');
        await _settle();

        expect(repo.pages, hasLength(1));
      },
    );

    test('starting over goes back to a freshly read list', () async {
      final repo = _Repo(searches: _cards(2));
      final viewModel = _recharge(repo, IntegrationProviderKey.hdbox);
      await viewModel.recentSearches.load();
      await viewModel.lookup('210900000001');
      viewModel.reset();
      await _settle();

      expect(viewModel.searchText, isEmpty);
      expect(viewModel.lookupState, RechargeLookupState.idle);
      expect(repo.pages, hasLength(2));
    });
  });

  group('the screen', () {
    testWidgets('opens on what was searched before', (tester) async {
      final repo = _Repo(searches: _cards(3));
      await tester.pumpWidget(_harness(_recharge(repo)));
      await tester.pumpAndSettle();

      expect(find.text('عمليات البحث السابقة'), findsOneWidget);
      expect(find.textContaining('210900000000'), findsOneWidget);
      expect(find.textContaining('210900000002'), findsOneWidget);
    });

    testWidgets('typing narrows the list once the cashier pauses', (
      tester,
    ) async {
      final repo = _Repo(searches: _cards(3));
      await tester.pumpWidget(_harness(_recharge(repo)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(EditableText), '0002');
      await tester.pump(const Duration(milliseconds: 100));
      expect(repo.pages, hasLength(1), reason: 'not on every keystroke');

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(repo.pages.last.search, '0002');
      expect(find.textContaining('210900000002'), findsOneWidget);
      expect(find.textContaining('210900000000'), findsNothing);
      expect(repo.lookups, isEmpty, reason: 'a filter never asks the provider');
    });

    testWidgets('the search key asks the provider, not the list', (
      tester,
    ) async {
      final repo = _Repo(searches: _cards(3));
      await tester.pumpWidget(_harness(_recharge(repo)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(EditableText), '555500001111');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(repo.lookups.single.cardNo, '555500001111');
    });

    testWidgets('tapping a past search runs it', (tester) async {
      final repo = _Repo(searches: _cards(3));
      await tester.pumpWidget(_harness(_recharge(repo)));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('210900000001'));
      await tester.pumpAndSettle();

      expect(repo.lookups.single.cardNo, '210900000001');
      expect(find.text('عمليات البحث السابقة'), findsNothing);
    });

    testWidgets('a name the shop gave the card is what the row shows', (
      tester,
    ) async {
      final repo = _Repo(
        searches: const [
          IntegrationRecentSearch(
            id: 1,
            term: '210906803499',
            cardNo: '210906803499',
            subscriberLabel: 'أحمد الورفلي',
            packageName: 'HDBOX Full package',
          ),
        ],
      );
      await tester.pumpWidget(_harness(_recharge(repo)));
      await tester.pumpAndSettle();

      expect(find.text('أحمد الورفلي'), findsOneWidget);
      expect(find.textContaining('HDBOX Full package'), findsOneWidget);
    });

    testWidgets('a household search says how many lines it found', (
      tester,
    ) async {
      final repo = _Repo(
        searches: const [
          IntegrationRecentSearch(
            id: 1,
            term: '0910682854',
            searchBy: 'mobile',
            matchCount: 3,
          ),
        ],
      );
      await tester.pumpWidget(
        _harness(_recharge(repo, IntegrationProviderKey.lnet)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('3 خطوط'), findsOneWidget);
    });

    testWidgets('nothing matching is not a dead end', (tester) async {
      // The list only holds what was found before. A number it does not
      // know has to be one tap from the provider, not a blank screen.
      final repo = _Repo(searches: _cards(3));
      await tester.pumpWidget(_harness(_recharge(repo)));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(EditableText), '7777');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.textContaining('لا يوجد بحث سابق يطابق'), findsOneWidget);
      await tester.tap(find.text('ابحث لدى المزوّد'));
      await tester.pumpAndSettle();
      expect(repo.lookups.single.cardNo, '7777');
    });

    testWidgets('with nothing searched yet it still says what to do', (
      tester,
    ) async {
      final repo = _Repo();
      await tester.pumpWidget(_harness(_recharge(repo)));
      await tester.pumpAndSettle();

      expect(
        find.text('أدخل رقم بطاقة المشترك للاطّلاع على اشتراكه وأسعار التجديد'),
        findsOneWidget,
      );
    });

    testWidgets('scrolling to the end brings the next page', (tester) async {
      final repo = _Repo(searches: _cards(45));
      await tester.pumpWidget(_harness(_recharge(repo)));
      await tester.pumpAndSettle();
      expect(repo.pages, hasLength(1));

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -4000));
      await tester.pumpAndSettle();

      expect(repo.pages.map((p) => p.cursor), contains('20'));
    });

    testWidgets('another card goes back to the list, re-read', (tester) async {
      final repo = _Repo(searches: _cards(3));
      await tester.pumpWidget(_harness(_recharge(repo)));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('210900000001'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('بطاقة أخرى'));
      await tester.pumpAndSettle();

      expect(find.text('عمليات البحث السابقة'), findsOneWidget);
      expect(repo.pages, hasLength(2));
      expect(repo.pages.last.search, isEmpty);
    });
  });
}

/// Lets queued microtasks and zero-length timers run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

List<IntegrationRecentSearch> _cards(int count) => [
  for (var index = 0; index < count; index++)
    IntegrationRecentSearch(
      id: index + 1,
      term: '2109${index.toString().padLeft(8, '0')}',
      cardNo: '2109${index.toString().padLeft(8, '0')}',
      packageName: 'HDBOX Full package',
      lastSearchedAt: DateTime(
        2026,
        9,
        20,
        10,
      ).subtract(Duration(hours: index)),
    ),
];

IntegrationRecentSearchesViewModel _list(_Repo repo) =>
    IntegrationRecentSearchesViewModel(repository: repo, providerKey: 'hdbox');

IntegrationRechargeViewModel _recharge(
  _Repo repo, [
  IntegrationProviderKey provider = IntegrationProviderKey.hdbox,
]) => IntegrationRechargeViewModel(repository: repo, provider: provider);

Widget _harness(IntegrationRechargeViewModel viewModel) {
  return MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: IntegrationRechargeScreen(viewModel: viewModel),
  );
}

/// Pages the fixture 20 at a time by an offset cursor, the way the server
/// pages by a keyset one: the till only ever hands back what it was given.
class _Repo extends IntegrationsRepository {
  _Repo({this.searches = const []}) : super(PosApiService());

  final List<IntegrationRecentSearch> searches;
  final pages = <({String search, String? cursor})>[];
  final lookups = <({String cardNo, String searchBy})>[];

  /// Answers for these queries wait until the completer is released.
  final hold = <String, Completer<void>>{};

  /// The next page after the first fails once.
  bool failNextPage = false;

  static const _pageSize = 20;

  @override
  Future<Result<IntegrationRecentSearchPage>> loadRecentSearches({
    required String providerKey,
    String search = '',
    String? cursor,
  }) async {
    pages.add((search: search, cursor: cursor));
    await hold[search]?.future;
    if (cursor != null && failNextPage) {
      failNextPage = false;
      return Error(Exception('offline'));
    }
    final matching = [
      for (final entry in searches)
        if (search.isEmpty ||
            entry.term.contains(search) ||
            entry.subscriberLabel.contains(search))
          entry,
    ];
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + _pageSize).clamp(0, matching.length);
    final next = end < matching.length ? '$end' : null;
    return Ok(
      IntegrationRecentSearchPage(
        searches: matching.sublist(start, end),
        hasMore: next != null,
        nextCursor: next,
      ),
    );
  }

  @override
  Future<Result<IntegrationCardSnapshot>> lookupCard({
    required String providerKey,
    required String cardNo,
    String searchBy = '',
  }) async {
    lookups.add((cardNo: cardNo, searchBy: searchBy));
    return Ok(
      IntegrationCardSnapshot(
        card: IntegrationCardInfo(
          cardNo: cardNo,
          status: 'Active',
          expireAt: DateTime(2026, 12, 1),
        ),
        offers: const [
          IntegrationOffer(
            code: 'renew:1',
            kind: 'renew',
            label: '1 month',
            cost: 25,
            price: 30,
            months: 1,
          ),
        ],
        serviceVariant: const IntegrationServiceVariant(
          id: 9001,
          productId: 4001,
          sku: 'INTEG-HDBOX',
        ),
      ),
    );
  }

  @override
  Future<Result<IntegrationHistoryPage>> loadHistory({
    required String providerKey,
    required String cardNo,
    required IntegrationHistoryKind kind,
    int limit = 10,
    int offset = 0,
  }) async => Ok(IntegrationHistoryPage(ok: true, kind: kind, limit: limit));
}
