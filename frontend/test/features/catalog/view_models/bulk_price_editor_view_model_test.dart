import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_preview.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_rule.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/bulk_price_editor_view_model.dart';

import '../views/bulk_price_test_support.dart';

void main() {
  BulkPriceEditorViewModel build(
    FakeBulkPriceRepository repository, {
    List<BulkPriceRef> selected = const [],
  }) => BulkPriceEditorViewModel(
    catalogRepository: repository,
    selectedProducts: selected,
    previewDebounce: Duration.zero,
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  test('an incomplete spec never asks the server', () async {
    final repository = FakeBulkPriceRepository();
    final vm = build(repository);
    await vm.load();
    // The first step starts with no value.
    expect(vm.isComplete, isFalse);
    expect(repository.previewCalls, isEmpty);
    expect(vm.canApply, isFalse);
  });

  test('a completed edit previews, and a later edit makes it stale', () async {
    final repository = FakeBulkPriceRepository();
    final vm = build(repository);
    await vm.load();
    vm.updateStep(vm.spec.steps.first.key, (s) => s.copyWith(value: '10'));
    await settle();
    expect(repository.previewCalls, hasLength(1));
    expect(repository.previewCalls.single.spec['filter'], {
      'match': 'all',
      'conditions': <Object?>[],
    });
    expect(vm.isPreviewFresh, isTrue);
    expect(vm.canApply, isTrue);
    expect(vm.stepHits(0), 2);

    vm.updateStep(vm.spec.steps.first.key, (s) => s.copyWith(value: '12'));
    expect(vm.isPreviewFresh, isFalse);
    expect(vm.canApply, isFalse);
    expect(vm.stepHits(0), isNull);
  });

  test('a slow answer for old rules is dropped', () async {
    final repository = FakeBulkPriceRepository()
      ..previews.addAll([
        Ok(bulkPreview(fingerprint: 'old')),
        Ok(bulkPreview(fingerprint: 'new')),
      ]);
    final vm = build(repository);
    await vm.load();
    final key = vm.spec.steps.first.key;
    vm.updateStep(key, (s) => s.copyWith(value: '10'));
    final first = vm.refreshPreview();
    vm.updateStep(key, (s) => s.copyWith(value: '11'));
    final second = vm.refreshPreview();
    await Future.wait([first, second]);
    expect(vm.preview!.fingerprint, 'new');
  });

  test('"all products" sends no conditions but keeps the draft', () async {
    final repository = FakeBulkPriceRepository();
    final vm = build(repository);
    await vm.load();
    vm.setScopeAll(false);
    expect(vm.spec.filter.children, hasLength(1));
    final condition = vm.spec.filter.children.single.key;
    vm.updateCondition(
      condition,
      (c) => c.copyWith(refs: const [BulkPriceRef(id: 3, label: 'x')]),
    );
    vm.setScopeAll(true);
    expect(vm.effectiveSpec.filter.isEmpty, isTrue);
    vm.setScopeAll(false);
    expect(vm.spec.filter.children.single.key, condition);
  });

  test('removing the last condition returns to "all products"', () async {
    final vm = build(FakeBulkPriceRepository());
    vm.setScopeAll(false);
    vm.removeNode(vm.spec.filter.children.single.key);
    expect(vm.scopeAll, isTrue);
  });

  test('a nested group that loses its last condition disappears', () async {
    final vm = build(FakeBulkPriceRepository());
    vm.setScopeAll(false);
    vm.addGroup(vm.spec.filter.key);
    final group = vm.spec.filter.children.last as BulkPriceGroup;
    expect(group.match, BulkPriceMatch.any);
    vm.removeNode(group.children.single.key);
    expect(vm.spec.filter.children.whereType<BulkPriceGroup>(), isEmpty);
  });

  test('step conditions are edited through the same calls', () async {
    final vm = build(FakeBulkPriceRepository());
    final step = vm.spec.steps.first.key;
    vm.setStepConditional(step, true);
    final condition = vm.spec.steps.first.when!.children.single.key;
    vm.updateCondition(condition, (c) => c.copyWith(value: '5'));
    expect(
      (vm.spec.steps.first.when!.children.single as BulkPriceCondition).value,
      '5',
    );
    vm.removeNode(condition);
    expect(vm.spec.steps.first.when, isNull);
  });

  test('steps move, duplicate and remove', () async {
    final vm = build(FakeBulkPriceRepository());
    vm.addStep(BulkPriceAction.round, value: '0.5');
    vm.addStep(BulkPriceAction.ending, value: '0.99');
    expect(vm.spec.steps.last.direction, BulkPriceDirection.up);
    final round = vm.spec.steps[1].key;
    vm.moveStep(round, -1);
    expect(vm.spec.steps.first.action, BulkPriceAction.round);
    vm.duplicateStep(round);
    expect(vm.spec.steps[1].action, BulkPriceAction.round);
    expect(vm.spec.steps[1].key, isNot(round));
    vm.removeStep(round);
    expect(vm.spec.steps, hasLength(3));
  });

  test('selection starts narrowed to the selected products', () async {
    final repository = FakeBulkPriceRepository();
    final vm = build(
      repository,
      selected: const [
        BulkPriceRef(id: 5, label: 'a'),
        BulkPriceRef(id: 8, label: 'b'),
      ],
    );
    expect(vm.scopeAll, isFalse);
    expect(vm.effectiveSpec.toJson()['filter'], {
      'match': 'all',
      'conditions': [
        {
          'field': 'product',
          'op': 'in',
          'value': [5, 8],
        },
      ],
    });
    expect(vm.isDirty, isFalse);
  });

  test('apply sends the fingerprint the preview showed', () async {
    final repository = FakeBulkPriceRepository()
      ..fallbackPreview = Ok(bulkPreview(fingerprint: 'shown'));
    final vm = build(repository);
    await vm.load();
    vm.updateStep(vm.spec.steps.first.key, (s) => s.copyWith(value: '10'));
    await settle();
    expect(vm.isDirty, isTrue);
    final result = await vm.apply();
    expect(result, isA<Ok<BulkPriceChangeRecord>>());
    expect(repository.applyCalls.single.fingerprint, 'shown');
    expect(vm.isDirty, isFalse);
  });

  test('a stale refusal re-previews', () async {
    final repository = FakeBulkPriceRepository()
      ..applyResult = const Error(BulkPriceException(BulkPriceFailure.stale));
    final vm = build(repository);
    await vm.load();
    vm.updateStep(vm.spec.steps.first.key, (s) => s.copyWith(value: '10'));
    await settle();
    final before = repository.previewCalls.length;
    final result = await vm.apply();
    await settle();
    expect(result, isA<Error<BulkPriceChangeRecord>>());
    expect(repository.previewCalls.length, before + 1);
  });

  test('a failed extra page keeps the rows and the offer of more', () async {
    final repository = FakeBulkPriceRepository()
      ..fallbackPreview = Ok(bulkPreview(count: 5));
    final vm = build(repository);
    await vm.load();
    vm.updateStep(vm.spec.steps.first.key, (s) => s.copyWith(value: '10'));
    await settle();
    repository.previews.add(Error(Exception('offline')));
    await vm.loadMore();
    expect(vm.preview!.rows, hasLength(2));
    expect(vm.preview!.hasMore, isTrue);
    expect(repository.previewCalls.last.offset, 2);
  });
}
