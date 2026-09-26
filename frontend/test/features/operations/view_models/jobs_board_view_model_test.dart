import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bill_of_materials.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/workflow.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/jobs_board_view_model.dart';

void main() {
  test('loadAll seeds templates and jobs', () async {
    final repo = _FakeOperationsRepository();
    final vm = JobsBoardViewModel(repo);
    addTearDown(vm.dispose);

    await vm.loadAll();

    expect(vm.isLoading, isFalse);
    expect(vm.hasLoadError, isFalse);
    expect(repo.loadJobsCount, 1);
  });

  test(
    'the board never asks for recipes, so a refusal cannot fail it',
    () async {
      // Field export, 2026-09-25: the board loaded the recipe list on every
      // open, a cashier may not read it, and the 403 marked the whole board
      // failed — an empty board said "failed to load jobs" at every phone shop.
      final repo = _FakeOperationsRepository(templates: _twoTemplates)
        ..bomsForbidden = true;
      final vm = JobsBoardViewModel(repo);
      addTearDown(vm.dispose);

      await vm.loadAll();

      expect(repo.loadBomsCount, 0);
      expect(vm.hasLoadError, isFalse);
    },
  );

  test(
    'recipes load only for a production batch, and a refusal is null',
    () async {
      final repo = _FakeOperationsRepository()..bomsForbidden = true;
      final vm = JobsBoardViewModel(repo);
      addTearDown(vm.dispose);

      expect(await vm.loadActiveRecipes(), isNull);
      expect(repo.loadBomsCount, 1);
    },
  );

  test('the board only ever asks for open work', () async {
    // Finished jobs live on the history screen. If the board could be widened
    // to "all", a shop with a year of repairs behind it would load every one of
    // them into a kanban that loads its pages eagerly.
    final repo = _FakeOperationsRepository();
    final vm = JobsBoardViewModel(repo);
    addTearDown(vm.dispose);

    await vm.loadAll();

    expect(repo.lastStatus, OperationsJobStatus.open);

    vm.searchQuery = 'أحمد';
    expect(repo.lastStatus, OperationsJobStatus.open);
  });

  test(
    'every live lane is on the board and a switched-off one is not',
    () async {
      // No switcher: a shop running two kinds of work sees both lanes, and a
      // lane the shop turned off is simply not there.
      final repo = _FakeOperationsRepository(templates: _twoTemplates);
      final vm = JobsBoardViewModel(repo);
      addTearDown(vm.dispose);
      await vm.loadAll();

      expect(vm.enabledTemplates.map((template) => template.id), [1, 2]);
    },
  );

  test('recipes matter only to a kitchen or a production line', () async {
    final repairOnly = JobsBoardViewModel(
      _FakeOperationsRepository(templates: [_template(1, 'تصليح')]),
    );
    final withKitchen = JobsBoardViewModel(
      _FakeOperationsRepository(templates: _twoTemplates),
    );
    addTearDown(repairOnly.dispose);
    addTearDown(withKitchen.dispose);
    await repairOnly.loadAll();
    await withKitchen.loadAll();

    expect(repairOnly.usesRecipes, isFalse);
    expect(withKitchen.usesRecipes, isTrue);
  });

  test('currentUserId reloads only while assignedToMe is on', () async {
    final repo = _FakeOperationsRepository();
    final vm = JobsBoardViewModel(repo);
    addTearDown(vm.dispose);
    await vm.loadAll();
    repo.loadJobsCount = 0;

    // assignedToMe off: changing the user must not reload.
    vm.currentUserId = 7;
    expect(repo.loadJobsCount, 0);

    // turning it on reloads and scopes the query to the current user.
    vm.assignedToMe = true;
    expect(repo.loadJobsCount, 1);
    expect(repo.lastAssignedTo, 7);

    // with it on, changing the user reloads again.
    vm.currentUserId = 9;
    expect(repo.loadJobsCount, 2);
    expect(repo.lastAssignedTo, 9);
  });

  test('the default open-only view does not count as a user filter', () async {
    final repo = _FakeOperationsRepository();
    final vm = JobsBoardViewModel(repo);
    addTearDown(vm.dispose);
    await vm.loadAll();

    // A brand-new shop with no jobs must get the onboarding empty state, not
    // an invitation to clear filters that are hiding nothing.
    expect(vm.hasActiveFilters, isFalse);

    vm.assignedToMe = true;
    expect(vm.hasActiveFilters, isTrue);
  });

  test('clearFilters restores the defaults in a single reload', () async {
    final repo = _FakeOperationsRepository();
    final vm = JobsBoardViewModel(repo);
    addTearDown(vm.dispose);
    await vm.loadAll();
    vm.assignedToMe = true;
    vm.searchQuery = 'أحمد';
    repo.loadJobsCount = 0;

    vm.clearFilters();

    expect(vm.assignedToMe, isFalse);
    expect(vm.searchQuery, isEmpty);
    expect(vm.hasActiveFilters, isFalse);
    // Resetting the fields through their setters would have fired a query each
    // and flickered the board through the intermediate results.
    expect(repo.loadJobsCount, 1);
    expect(repo.lastStatus, OperationsJobStatus.open);
    expect(repo.lastAssignedTo, isNull);
  });

  test('clearFilters on an untouched board does not reload', () async {
    final repo = _FakeOperationsRepository();
    final vm = JobsBoardViewModel(repo);
    addTearDown(vm.dispose);
    await vm.loadAll();
    repo.loadJobsCount = 0;

    vm.clearFilters();

    expect(repo.loadJobsCount, 0);
  });
}

WorkflowTemplate _template(
  int id,
  String name, {
  bool isActive = true,
  OperationsJobType jobType = OperationsJobType.repair,
}) {
  return WorkflowTemplate(
    id: id,
    name: name,
    jobType: jobType,
    isActive: isActive,
    isSystem: true,
    jobCount: 0,
    stages: const [],
  );
}

final List<WorkflowTemplate> _twoTemplates = [
  _template(1, 'تصليح'),
  _template(2, 'مطبخ', jobType: OperationsJobType.kitchen),
  _template(3, 'قديم', isActive: false),
];

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository({this.templates = const []})
    : super(PosApiService());

  final List<WorkflowTemplate> templates;
  bool bomsForbidden = false;
  int loadBomsCount = 0;
  int loadJobsCount = 0;
  OperationsJobStatus? lastStatus;
  int? lastAssignedTo;

  @override
  Future<Result<List<WorkflowTemplate>>> loadAllWorkflowTemplates({
    OperationsJobType? jobType,
    bool? isActive,
  }) async {
    return Ok(templates);
  }

  @override
  Future<Result<List<BillOfMaterials>>> loadAllBoms({bool? isActive}) async {
    loadBomsCount++;
    if (bomsForbidden) {
      return Error(
        PosApiException(
          message: 'forbidden',
          statusCode: 403,
          responseBody: '{"detail":"You do not have permission."}',
        ),
      );
    }
    return const Ok([]);
  }

  @override
  Future<Result<List<OperationsJob>>> loadAllJobs({
    OperationsJobStatus? status,
    OperationsJobType? jobType,
    int? currentStage,
    int? assignedTo,
    int? customer,
    int? asset,
    int? workflowTemplate,
    String search = '',
  }) async {
    loadJobsCount++;
    lastStatus = status;
    lastAssignedTo = assignedTo;
    return const Ok([]);
  }

  @override
  Future<Result<List<OperationsJob>>> loadJobsAwaitingHandBack({
    String search = '',
  }) async {
    return const Ok([]);
  }
}
