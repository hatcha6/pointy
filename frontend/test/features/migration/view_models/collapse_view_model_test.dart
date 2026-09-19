import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/migration_collapse.dart';
import 'package:pointy_frontend/src/features/migration/view_models/collapse_view_model.dart';
import 'package:pointy_frontend/src/features/migration/view_models/migration_view_model.dart';

import '../migration_fakes.dart';

/// §12's review is a document somebody argues with, and these lock down the two
/// things that makes true: the screen never shows a total that predates the
/// edit that produced it, and an approved proposal stops being editable.
void main() {
  Map<String, Object?> planJson({
    String status = 'ready',
    int products = 12,
    int units = 331,
  }) => {
    'id': 7,
    'source': 1,
    'status': status,
    'is_editable': status == 'ready',
    'thresholds': {'low': 0.5, 'high': 0.8},
    'asset_type_name': 'هاتف',
    'stats': {
      'source_products': 340,
      'products': products,
      'variants': 31,
      'units': units,
      'units_in_stock': 96,
      'units_sold': 235,
      'kept': 9,
      'needs_review': 2,
    },
  };

  Map<String, Object?> candidateJson({
    int id = 1,
    String decision = 'collapse',
    String stem = 'iPhone 13 Pro',
    String stemKey = 'iphone 13 pro',
    bool needsReview = false,
    String confidence = '0.90',
  }) => {
    'id': id,
    'source_key': '$id',
    'source_name': 'iPhone 13 Pro 256GB Blue IMEI35123456789012$id',
    'decision': decision,
    'stem': stem,
    'stem_key': stemKey,
    'identifier': '35123456789012$id',
    'identifier_kind': 'imei',
    'options': const {'storage': '256GB', 'colour': 'blue'},
    'option_labels': const {'storage': '256GB', 'colour': 'أزرق'},
    'attributes': const {'battery_health': 86},
    'unit_status': 'in_stock',
    'unit_cost': '2400.000000',
    'confidence': confidence,
    'reasons': const <String>[],
    'edited': false,
    'needs_review': needsReview,
  };

  Future<CollapseViewModel> loaded(FakeMigrationRepository repository) async {
    final viewModel = CollapseViewModel(repository, sourceId: 1);
    await viewModel.load();
    return viewModel;
  }

  test('no proposal yet means the screen offers to build one', () async {
    final viewModel = await loaded(FakeMigrationRepository());
    expect(viewModel.hasPlan, isFalse);
    expect(viewModel.canApprove, isFalse);
  });

  test('a superseded proposal is history, not the answer', () async {
    final viewModel = await loaded(
      FakeMigrationRepository(plans: [planJson(status: 'superseded')]),
    );
    expect(viewModel.hasPlan, isFalse);
  });

  test('a ready proposal loads its products and its rows', () async {
    final repository = FakeMigrationRepository(
      plans: [planJson()],
      clusters: [
        {
          'stem_key': 'iphone 13 pro',
          'stem': 'iPhone 13 Pro',
          'variants': 6,
          'units': 84,
          'units_in_stock': 21,
          'units_sold': 63,
          'needs_review': 4,
          'option_values': {
            'storage': ['128GB', '256GB'],
          },
        },
      ],
      candidates: [candidateJson(needsReview: true, confidence: '0.30')],
    );
    final viewModel = await loaded(repository);
    expect(viewModel.stats.products, 12);
    expect(viewModel.clusters.single.stem, 'iPhone 13 Pro');
    // The default list is the one a person can help with.
    expect(viewModel.filter, CollapseFilter.needsReview);
    expect(viewModel.candidates, hasLength(1));
  });

  test('editing a row sends only what changed', () async {
    final repository = FakeMigrationRepository(
      plans: [planJson()],
      candidates: [candidateJson(needsReview: true)],
    );
    final viewModel = await loaded(repository);
    await viewModel.editCandidate(viewModel.candidates.single, {
      'stem': 'iPhone 13 Pro Max',
    });
    expect(repository.candidateEdits.single['stem'], 'iPhone 13 Pro Max');
  });

  test('a row that no longer needs a look leaves the list it was in', () async {
    final repository = FakeMigrationRepository(
      plans: [planJson()],
      candidates: [candidateJson(id: 1, needsReview: true)],
    );
    final viewModel = await loaded(repository);
    expect(viewModel.candidates, hasLength(1));
    // The server answers with `needs_review` absent, i.e. false.
    await viewModel.editCandidate(viewModel.candidates.single, {
      'stem': 'iPhone 13 Pro',
      'needs_review': false,
    });
    expect(viewModel.candidates, isEmpty);
  });

  test('renaming a product is sent as a rename, not as many edits', () async {
    final repository = FakeMigrationRepository(plans: [planJson()]);
    final viewModel = await loaded(repository);
    await viewModel.renameCluster('ايفون 12', 'iPhone 12');
    expect(repository.renames.single.stem, 'iPhone 12');
    expect(repository.candidateEdits, isEmpty);
  });

  test('an approved proposal can no longer be edited', () async {
    final repository = FakeMigrationRepository(
      plans: [planJson()],
      candidates: [candidateJson()],
    );
    final viewModel = await loaded(repository);
    expect(viewModel.canApprove, isTrue);
    await viewModel.approve();
    expect(viewModel.plan!.isApproved, isTrue);
    expect(viewModel.isEditable, isFalse);
    await viewModel.editCandidate(CollapseCandidate.fromJson(candidateJson()), {
      'stem': 'iPhone 13',
    });
    expect(repository.candidateEdits, isEmpty);
  });

  test('a proposal with nothing in it is not offered for approval', () async {
    final viewModel = await loaded(
      FakeMigrationRepository(plans: [planJson(units: 0, products: 0)]),
    );
    expect(viewModel.canApprove, isFalse);
  });

  test(
    'the wizard sends an approved plan with the run, and nothing else',
    () async {
      final sources = [
        {
          'id': 1,
          'upload_state': 'ready',
          'supported_entities': const ['product'],
        },
      ];
      final withoutPlan = FakeMigrationRepository(sources: sources);
      final wizard = MigrationViewModel(withoutPlan);
      await wizard.load();
      await wizard.startRun(dryRun: true);
      expect(
        (withoutPlan.startedRuns.single['options'] as Map)['collapse_plan'],
        isNull,
      );

      final withPlan = FakeMigrationRepository(
        sources: sources,
        plans: [planJson(status: 'approved')],
      );
      final approved = MigrationViewModel(withPlan);
      await approved.load();
      // The collapse loads on its own; give it the microtask it needs.
      await Future<void>.delayed(Duration.zero);
      expect(approved.willCollapse, isTrue);
      await approved.startRun(dryRun: true);
      expect(
        (withPlan.startedRuns.single['options'] as Map)['collapse_plan'],
        7,
      );
    },
  );
}
