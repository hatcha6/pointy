import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/search_miss.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/search_misses_view_model.dart';

import '../search_miss_test_support.dart';

List<String> _terms(SearchMissesViewModel viewModel) => [
  for (final row in viewModel.misses) row.term,
];

Future<SearchMissesViewModel> _loaded(
  FakeSearchMissRepository repository,
) async {
  final viewModel = SearchMissesViewModel(repository);
  await pumpEventQueue();
  return viewModel;
}

void main() {
  test('loads the open words, most typed first', () async {
    final repository = FakeSearchMissRepository([
      miss(1, 'ارز', count: 3),
      miss(2, 'كاتشب575', count: 12),
      miss(3, 'بيبسي', count: 5),
      miss(4, 'قديمة', count: 40, status: SearchMissStatus.dismissed),
    ]);
    final viewModel = await _loaded(repository);

    expect(_terms(viewModel), ['كاتشب575', 'بيبسي', 'ارز']);
    expect(repository.pageRequests.single, (
      page: 1,
      filter: SearchMissFilter.open,
    ));
    expect(viewModel.isLoading, isFalse);
    expect(viewModel.hasError, isFalse);
    expect(viewModel.hasMore, isFalse);
  });

  test('a failed first page is an error with nothing to show', () async {
    final repository = FakeSearchMissRepository([miss(1, 'ارز')])
      ..failingPages.add(1);
    final viewModel = await _loaded(repository);

    expect(viewModel.hasError, isTrue);
    expect(viewModel.misses, isEmpty);

    repository.failingPages.clear();
    await viewModel.load();
    expect(viewModel.hasError, isFalse);
    expect(_terms(viewModel), ['ارز']);
  });

  test('resolving a word teaches it and takes the row off the list', () async {
    final repository = FakeSearchMissRepository([
      miss(1, 'ارز', count: 3),
      miss(2, 'كاتشب575', count: 12),
    ]);
    final viewModel = await _loaded(repository);

    final outcome = await viewModel.resolve(
      viewModel.misses.first,
      productId: 42,
    );

    expect(outcome, SearchMissActionOutcome.done);
    expect(repository.actions, ['resolve 2 -> 42']);
    expect(_terms(viewModel), ['ارز']);
    expect(viewModel.isBusy(miss(2, 'كاتشب575')), isFalse);
  });

  test(
    'dismissing takes the row off; reopening puts it back in place',
    () async {
      final repository = FakeSearchMissRepository([
        miss(1, 'ارز', count: 3),
        miss(2, 'كاتشب575', count: 12),
        miss(3, 'بيبسي', count: 5),
      ]);
      final viewModel = await _loaded(repository);
      final pepsi = viewModel.misses[1];

      expect(await viewModel.dismiss(pepsi), SearchMissActionOutcome.done);
      expect(_terms(viewModel), ['كاتشب575', 'ارز']);

      // What the snackbar's undo does.
      expect(await viewModel.reopen(pepsi), SearchMissActionOutcome.done);
      expect(_terms(viewModel), ['كاتشب575', 'بيبسي', 'ارز']);
      expect(repository.actions, ['dismiss 3', 'reopen 3']);
    },
  );

  test('a failed action keeps the row where it was', () async {
    final repository = FakeSearchMissRepository([
      miss(1, 'ارز', count: 3),
      miss(2, 'كاتشب575', count: 12),
    ])..actionError = Exception('offline');
    final viewModel = await _loaded(repository);
    final ketchup = viewModel.misses.first;

    expect(await viewModel.dismiss(ketchup), SearchMissActionOutcome.failed);
    expect(
      await viewModel.resolve(ketchup, productId: 7),
      SearchMissActionOutcome.failed,
    );
    expect(_terms(viewModel), ['كاتشب575', 'ارز']);
    expect(viewModel.isBusy(ketchup), isFalse);
  });

  test('a product the server refuses is told apart from a failure', () async {
    final repository = FakeSearchMissRepository([miss(1, 'ارز')])
      ..actionError = PosApiException(
        message: 'Search miss resolve failed 400',
        statusCode: 400,
        responseBody: jsonEncode({
          'product': ['A product a feature owns keeps the names it was given.'],
        }),
      );
    final viewModel = await _loaded(repository);

    final outcome = await viewModel.resolve(
      viewModel.misses.single,
      productId: 9,
    );

    expect(outcome, SearchMissActionOutcome.productRefused);
    expect(_terms(viewModel), ['ارز']);
  });

  test('a second action on a row in flight sends nothing', () async {
    final repository = FakeSearchMissRepository([miss(1, 'ارز')]);
    final viewModel = await _loaded(repository);
    final rice = viewModel.misses.single;

    final first = viewModel.dismiss(rice);
    expect(viewModel.isBusy(rice), isTrue);
    expect(await viewModel.dismiss(rice), SearchMissActionOutcome.busy);
    expect(await first, SearchMissActionOutcome.done);
    expect(repository.actions, ['dismiss 1']);
  });

  test('a failed page keeps hasMore and the retry asks for it again', () async {
    final repository = FakeSearchMissRepository([
      for (var id = 1; id <= 60; id++) miss(id, 'كلمة $id', count: 100 - id),
    ])..failingPages.add(2);
    final viewModel = await _loaded(repository);
    expect(viewModel.misses, hasLength(50));
    expect(viewModel.hasMore, isTrue);

    await viewModel.loadMore();

    expect(viewModel.loadMoreFailed, isTrue);
    expect(viewModel.hasMore, isTrue, reason: 'a dropped page is no end');
    expect(viewModel.misses, hasLength(50));

    repository.failingPages.clear();
    await viewModel.loadMore();

    expect(repository.pageRequests.map((request) => request.page), [1, 2, 2]);
    expect(viewModel.loadMoreFailed, isFalse);
    expect(viewModel.misses, hasLength(60));
    expect(viewModel.hasMore, isFalse);
  });

  test(
    'after rows go, the next page starts at the first row not shown',
    () async {
      final repository = FakeSearchMissRepository([
        for (var id = 1; id <= 60; id++) miss(id, 'كلمة $id', count: 100 - id),
      ]);
      final viewModel = await _loaded(repository);

      // Three words handled from the first page move rows 51-53 into it on the
      // server; a page counter would ask for page 2 and never show them.
      for (final row in viewModel.misses.take(3).toList()) {
        await viewModel.dismiss(row);
      }
      expect(viewModel.misses, hasLength(47));

      await viewModel.loadMore();
      await viewModel.loadMore();

      expect(repository.pageRequests.map((request) => request.page), [1, 1, 2]);
      final open = [for (var id = 4; id <= 60; id++) 'كلمة $id'];
      expect(_terms(viewModel), open);
      expect(viewModel.hasMore, isFalse);
    },
  );

  test('handling the last row shown fetches the rows after it', () async {
    final repository = FakeSearchMissRepository([
      miss(1, 'ارز', count: 9),
      miss(2, 'بيبسي', count: 8),
      miss(3, 'شاي', count: 7),
    ], pageSize: 2);
    final viewModel = await _loaded(repository);
    expect(_terms(viewModel), ['ارز', 'بيبسي']);

    await viewModel.dismiss(viewModel.misses.first);
    await viewModel.resolve(viewModel.misses.first, productId: 5);
    await pumpEventQueue();

    expect(_terms(viewModel), ['شاي']);
    expect(viewModel.hasMore, isFalse);
  });

  test('in the all view an action changes the row in place', () async {
    final repository = FakeSearchMissRepository([
      miss(1, 'ارز', count: 3),
      miss(2, 'بيبسي', count: 5),
    ]);
    final viewModel = await _loaded(repository);
    viewModel.setFilter(SearchMissFilter.all);
    await pumpEventQueue();

    await viewModel.dismiss(viewModel.misses.first);

    expect(_terms(viewModel), ['بيبسي', 'ارز']);
    expect(viewModel.misses.first.status, SearchMissStatus.dismissed);
  });

  test('reopening from the dismissed view takes the row off it', () async {
    final repository = FakeSearchMissRepository([
      miss(1, 'ارز', status: SearchMissStatus.dismissed),
      miss(2, 'بيبسي'),
    ]);
    final viewModel = await _loaded(repository);
    viewModel.setFilter(SearchMissFilter.dismissed);
    await pumpEventQueue();
    expect(_terms(viewModel), ['ارز']);

    await viewModel.reopen(viewModel.misses.single);

    expect(viewModel.misses, isEmpty);
    expect(
      repository.serverRows.firstWhere((row) => row.id == 1).status,
      SearchMissStatus.open,
    );
  });

  test('switching filters drops the answer to the old one', () async {
    final gate = Completer<void>();
    final repository = FakeSearchMissRepository([
      miss(1, 'ارز'),
      miss(2, 'بيبسي', status: SearchMissStatus.resolved, productId: 3),
    ])..loadGate = gate;
    final viewModel = SearchMissesViewModel(repository);
    await pumpEventQueue();

    viewModel.setFilter(SearchMissFilter.resolved);
    expect(viewModel.misses, isEmpty);
    expect(viewModel.isLoading, isTrue);

    gate.complete();
    await pumpEventQueue();

    expect(viewModel.filter, SearchMissFilter.resolved);
    expect(_terms(viewModel), ['بيبسي']);
    expect(viewModel.isLoading, isFalse);
  });
}
