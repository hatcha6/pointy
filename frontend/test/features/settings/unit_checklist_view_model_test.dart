import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/unit_attribute.dart';
import 'package:pointy_frontend/src/features/settings/view_models/unit_checklist_kinds_view_model.dart';
import 'package:pointy_frontend/src/features/settings/view_models/unit_checklist_view_model.dart';

import 'unit_checklist_fakes.dart';

/// One kind's intake checklist, edited from the app: what is asked, in what
/// order, and what the server refused and where to show it.
void main() {
  group('the kinds list', () {
    test('loads every kind with its counts', () async {
      final viewModel = UnitChecklistKindsViewModel(FakeChecklistRepository());

      await viewModel.load();

      expect(viewModel.kinds.single.name, 'هاتف');
      expect(viewModel.kinds.single.fieldCount, 3);
      expect(viewModel.loadError, isNull);
    });

    test('a failed load keeps what it had and says so', () async {
      final repository = FakeChecklistRepository();
      final viewModel = UnitChecklistKindsViewModel(repository);
      await viewModel.load();

      repository.refuseLoad = Exception('offline');
      await viewModel.load();

      expect(viewModel.kinds, hasLength(1));
      expect(viewModel.loadError, isNotNull);
      expect(viewModel.isLoading, isFalse);
    });
  });

  group('one checklist', () {
    late FakeChecklistRepository repository;
    late UnitChecklistViewModel viewModel;

    setUp(() async {
      repository = FakeChecklistRepository();
      viewModel = UnitChecklistViewModel(
        repository: repository,
        kind: phoneKind,
      );
      await viewModel.load();
    });

    List<String> labels() => [
      for (final field in viewModel.fields) field.label,
    ];

    test('loads the fields in order', () {
      expect(viewModel.hasLoaded, isTrue);
      expect(labels(), ['صحة البطارية', 'درجة الحالة', 'العلبة والملحقات']);
      expect(viewModel.hasChanges, isFalse);
    });

    test('a new field lands at the end', () async {
      final outcome = await viewModel.save(
        const UnitAttributeDefinition(
          key: '',
          label: 'Face ID يعمل',
          assetTypeId: 7,
          dataType: UnitAttributeType.boolean,
        ),
      );

      expect(outcome.isSaved, isTrue);
      expect(outcome.definition!.id, 100);
      expect(labels().last, 'Face ID يعمل');
      expect(viewModel.hasChanges, isTrue);
    });

    test('an edit replaces the field where it stands', () async {
      final grade = viewModel.fields[1];

      await viewModel.save(grade.copyWith(label: 'الحالة'));

      expect(labels(), ['صحة البطارية', 'الحالة', 'العلبة والملحقات']);
      expect(repository.saved.single.id, grade.id);
    });

    test('a refusal lands under the field it names, in Arabic', () async {
      repository.refuseSave = badRequest({
        'label': ['اسم الحقل لا يتجاوز 80 حرفًا.'],
        'choices': ['الخيار «أسود» مكرر.'],
      });

      final outcome = await viewModel.save(viewModel.fields[1]);

      expect(outcome.isSaved, isFalse);
      expect(outcome.fieldErrors, {
        'label': 'اسم الحقل لا يتجاوز 80 حرفًا.',
        'choices': 'الخيار «أسود» مكرر.',
      });
      expect(outcome.message, isEmpty);
      expect(labels(), hasLength(3));
    });

    test('a refusal naming no field is one sentence — never English', () {
      final arabic = unitChecklistRefusalOf(
        badRequest({
          'non_field_errors': [
            'لا يزيد عدد حقول نوع الجهاز الواحد على 40 حقلًا.',
          ],
        }),
      );
      final english = unitChecklistRefusalOf(
        badRequest({
          'display_order': ['A valid integer is required.'],
        }),
      );
      final offline = unitChecklistRefusalOf(Exception('socket'));

      expect(arabic.message, startsWith('لا يزيد'));
      expect(arabic.fieldErrors, isEmpty);
      expect(english.message, isEmpty);
      expect(english.error, isNotNull);
      expect(offline.message, isEmpty);
      expect(offline.fieldErrors, isEmpty);
    });

    test('delete drops the field; a refused one stays', () async {
      repository.refuseDelete = Exception('offline');
      expect(await viewModel.delete(viewModel.fields.first), isFalse);
      expect(labels(), hasLength(3));
      expect(viewModel.actionError, isNotNull);

      repository.refuseDelete = null;
      expect(await viewModel.delete(viewModel.fields.first), isTrue);
      expect(labels(), ['درجة الحالة', 'العلبة والملحقات']);
      expect(repository.deleted, [1, 1]);
    });

    test('a move is shown at once and sent as the whole order', () async {
      final moving = viewModel.move(0, 2);

      // Before the server answers.
      expect(labels(), ['درجة الحالة', 'العلبة والملحقات', 'صحة البطارية']);
      expect(viewModel.isReordering, isTrue);
      expect(await moving, isTrue);

      expect(repository.reorders.single, [2, 3, 1]);
      expect(viewModel.isReordering, isFalse);
      expect(viewModel.hasChanges, isTrue);
    });

    test('a refused move is undone', () async {
      repository.refuseReorder = Exception('offline');

      expect(await viewModel.move(2, 0), isFalse);

      expect(labels(), ['صحة البطارية', 'درجة الحالة', 'العلبة والملحقات']);
      expect(viewModel.actionError, isNotNull);
    });

    test('a move nowhere, or off the end, sends nothing', () async {
      expect(await viewModel.move(1, 1), isFalse);
      expect(await viewModel.move(0, 3), isFalse);
      expect(await viewModel.move(-1, 0), isFalse);
      expect(repository.reorders, isEmpty);
    });
  });
}
