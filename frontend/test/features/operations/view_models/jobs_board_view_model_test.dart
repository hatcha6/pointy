import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bill_of_materials.dart';
import 'package:pointy_frontend/src/data/models/operations_job.dart';
import 'package:pointy_frontend/src/data/models/workflow.dart';
import 'package:pointy_frontend/src/data/repositories/operations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/operations/view_models/jobs_board_view_model.dart';

void main() {
  test('loadAll seeds templates, boms, and jobs', () async {
    final repo = _FakeOperationsRepository();
    final vm = JobsBoardViewModel(repo);
    addTearDown(vm.dispose);

    await vm.loadAll();

    expect(vm.isLoading, isFalse);
    expect(vm.hasLoadError, isFalse);
    expect(repo.loadJobsCount, 1);
  });

  test('changing the status filter reloads with the new value', () async {
    final repo = _FakeOperationsRepository();
    final vm = JobsBoardViewModel(repo);
    addTearDown(vm.dispose);
    await vm.loadAll();
    repo.loadJobsCount = 0;

    vm.statusFilter = null; // default is `open`, so null is a change

    expect(repo.loadJobsCount, 1);
    expect(repo.lastStatus, isNull);
  });

  test('setting the status filter to the same value does not reload', () async {
    final repo = _FakeOperationsRepository();
    final vm = JobsBoardViewModel(repo);
    addTearDown(vm.dispose);
    await vm.loadAll();
    repo.loadJobsCount = 0;

    vm.statusFilter = OperationsJobStatus.open; // unchanged

    expect(repo.loadJobsCount, 0);
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

    vm.statusFilter = OperationsJobStatus.completed;
    expect(vm.hasActiveFilters, isTrue);
  });

  test('clearFilters restores the defaults in a single reload', () async {
    final repo = _FakeOperationsRepository();
    final vm = JobsBoardViewModel(repo);
    addTearDown(vm.dispose);
    await vm.loadAll();
    vm.statusFilter = OperationsJobStatus.completed;
    vm.assignedToMe = true;
    vm.searchQuery = 'أحمد';
    repo.loadJobsCount = 0;

    vm.clearFilters();

    expect(vm.statusFilter, OperationsJobStatus.open);
    expect(vm.assignedToMe, isFalse);
    expect(vm.jobTypeFilter, isNull);
    expect(vm.searchQuery, isEmpty);
    expect(vm.hasActiveFilters, isFalse);
    // Resetting four fields through their setters would have fired four
    // queries and flickered the board through the intermediate results.
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

class _FakeOperationsRepository extends OperationsRepository {
  _FakeOperationsRepository() : super(PosApiService());

  int loadJobsCount = 0;
  OperationsJobStatus? lastStatus;
  int? lastAssignedTo;

  @override
  Future<Result<List<WorkflowTemplate>>> loadAllWorkflowTemplates({
    OperationsJobType? jobType,
    bool? isActive,
  }) async {
    return const Ok([]);
  }

  @override
  Future<Result<List<BillOfMaterials>>> loadAllBoms({bool? isActive}) async {
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
}
