import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/features/learning/content/learning_library.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_guide.dart';
import 'package:pointy_frontend/src/features/learning/models/learning_query.dart';
import 'package:pointy_frontend/src/features/learning/view_models/learning_view_model.dart';

import '../../support/key_value_store_testing.dart';

void main() {
  LearningViewModel build({bool manager = true}) {
    final user = PosUser(
      id: manager ? 1 : 2,
      username: manager ? 'manager' : 'cashier',
      role: manager ? UserRole.manager : UserRole.cashier,
      isActive: true,
    );
    return LearningViewModel(
      capabilities: AuthorizationCapabilities.forUser(user),
      userId: user.id,
    )..initialize();
  }

  test('with no query the catalogue is the whole library, in order', () {
    final viewModel = build();
    expect(viewModel.results.length, learningLibrary.length);
    expect(viewModel.results.first.id, learningLibrary.first.id);
  });

  test('search narrows the catalogue and survives Arabic spelling', () {
    final viewModel = build()..setSearch('اجل');
    expect(viewModel.results, isNotEmpty);
    expect(viewModel.results.length, lessThan(learningLibrary.length));
    expect(
      viewModel.results.map((guide) => guide.id),
      contains('money.credit_sale'),
    );
  });

  test('the track filter keeps only that track', () {
    final viewModel = build()..selectTrack(LearningTrack.purchasing);
    expect(viewModel.results, isNotEmpty);
    expect(
      viewModel.results.every((g) => g.track == LearningTrack.purchasing),
      isTrue,
    );
  });

  test('the level and kind filters compose', () {
    final viewModel = build()
      ..setQuery(
        const LearningQuery(
          level: LearningLevelFilter.beginner,
          kind: LearningKindFilter.walkthrough,
        ),
      );
    expect(viewModel.results, isNotEmpty);
    for (final guide in viewModel.results) {
      expect(guide.level, LearningLevel.beginner);
      expect(guide.kind, LearningKind.walkthrough);
    }
  });

  test('the permissions filter hides what a cashier cannot reach', () {
    final cashier = build(manager: false)
      ..setQuery(
        const LearningQuery(audience: LearningAudienceFilter.myPermissions),
      );
    final ids = cashier.results.map((guide) => guide.id).toSet();

    // A cashier sells and closes a drawer...
    expect(ids, contains('selling.first_sale'));
    expect(ids, contains('register.close'));
    // ...but does not run payroll or write discount rules.
    expect(ids, isNot(contains('people.employees')));
    expect(ids, isNot(contains('setup.discount_rules')));
    // Guides with no capability at all stay visible to everyone.
    expect(ids, contains('start.how_pointy_works'));
  });

  test('without the permissions filter the whole library stays readable', () {
    // An owner training a new hire has to be able to read the cashier's
    // guides, and a cashier reading about a screen they cannot open learns
    // why they cannot open it.
    final cashier = build(manager: false);
    expect(cashier.results.length, learningLibrary.length);
  });

  test('sorting by shortest puts the quickest read first', () {
    final viewModel = build()
      ..setQuery(const LearningQuery(sort: LearningSort.shortest));
    final minutes = viewModel.results.map((guide) => guide.minutes).toList();
    expect(minutes, orderedEquals(List.of(minutes)..sort()));
  });

  test('sorting by level puts beginner guides first', () {
    final viewModel = build()
      ..setQuery(const LearningQuery(sort: LearningSort.level));
    final levels = viewModel.results.map((guide) => guide.level.index).toList();
    expect(levels, orderedEquals(List.of(levels)..sort()));
  });

  test('relevance beats the chosen sort while searching', () {
    final viewModel = build()
      ..setQuery(const LearningQuery(sort: LearningSort.alphabetical))
      ..setSearch('تقسيم الدفع');
    expect(viewModel.results.first.id, 'money.split_tender');
  });

  test('marking a guide finished filters and persists', () async {
    final store = installMemoryKeyValueStore();
    final viewModel = build();

    await viewModel.toggleFinished('selling.first_sale');
    expect(viewModel.isFinished('selling.first_sale'), isTrue);
    expect(viewModel.finishedCount, 1);
    expect(
      await store.getStringList('learning.finished_guides.1'),
      contains('selling.first_sale'),
    );

    viewModel.setQuery(
      const LearningQuery(progress: LearningProgressFilter.finished),
    );
    expect(viewModel.results.map((guide) => guide.id), ['selling.first_sale']);

    viewModel.setQuery(
      const LearningQuery(progress: LearningProgressFilter.unfinished),
    );
    expect(
      viewModel.results.map((guide) => guide.id),
      isNot(contains('selling.first_sale')),
    );
  });

  test('restored progress drops ids that no longer exist', () async {
    installMemoryKeyValueStore({
      'learning.finished_guides.1': ['selling.first_sale', 'gone.guide'],
    });
    final viewModel = build();
    await viewModel.restoreProgress();

    expect(viewModel.finished, {'selling.first_sale'});
  });

  test('one till, two cashiers, two sets of ticks', () async {
    // A till is shared. Progress used to live under one device-wide key, so the
    // cashier who marked a guide finished this morning put a tick on the
    // catalogue of whoever read it this evening — and "who has been trained on
    // returns" is the one question this list is asked.
    installMemoryKeyValueStore();
    final manager = build();
    await manager.toggleFinished('selling.first_sale');

    final cashier = build(manager: false);
    await cashier.restoreProgress();

    expect(cashier.isFinished('selling.first_sale'), isFalse);
    expect(manager.isFinished('selling.first_sale'), isTrue);
  });

  test('clearing drops the search and every filter but keeps the sort', () {
    final viewModel = build()
      ..setQuery(
        const LearningQuery(
          search: 'اجل',
          track: LearningTrack.money,
          level: LearningLevelFilter.advanced,
          sort: LearningSort.alphabetical,
        ),
      )
      ..clearFilters();

    expect(viewModel.query.search, isEmpty);
    expect(viewModel.query.track, isNull);
    expect(viewModel.query.level, LearningLevelFilter.all);
    expect(viewModel.query.sort, LearningSort.alphabetical);
    expect(viewModel.results.length, learningLibrary.length);
  });

  test('related guides resolve to real guides', () {
    final viewModel = build();
    final guide = learningGuidesById['money.credit_down_payment']!;
    expect(
      viewModel.relatedTo(guide).map((g) => g.id),
      containsAll(<String>['money.credit_sale', 'money.split_tender']),
    );
  });
}
