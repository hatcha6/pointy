import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/bill_of_materials.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/models/workflow.dart';
import '../../../data/repositories/operations_repository.dart';

class JobsBoardViewModel extends ChangeNotifier {
  JobsBoardViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine;

  final OperationsRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<OperationsJob> _jobs = const [];
  List<WorkflowTemplate> _templates = const [];
  List<BillOfMaterials> _boms = const [];
  OperationsJobStatus? _statusFilter = OperationsJobStatus.open;
  OperationsJobType? _jobTypeFilter;
  String _searchQuery = '';
  bool _assignedToMe = false;
  int? _currentUserId;
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  bool _hasMutationError = false;

  List<OperationsJob> get jobs => _jobs;
  List<WorkflowTemplate> get templates => _templates;
  List<BillOfMaterials> get boms => _boms;
  OperationsJobStatus? get statusFilter => _statusFilter;
  OperationsJobType? get jobTypeFilter => _jobTypeFilter;
  String get searchQuery => _searchQuery;
  bool get assignedToMe => _assignedToMe;
  int? get currentUserId => _currentUserId;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  bool get hasMutationError => _hasMutationError;

  List<WorkflowTemplate> get enabledTemplates => _templates
      .where((template) => template.isActive)
      .toList(growable: false);

  set statusFilter(OperationsJobStatus? value) {
    if (_statusFilter == value) {
      return;
    }
    _statusFilter = value;
    notifyListeners();
    loadJobs();
  }

  set jobTypeFilter(OperationsJobType? value) {
    if (_jobTypeFilter == value) {
      return;
    }
    _jobTypeFilter = value;
    notifyListeners();
    loadJobs();
  }

  set searchQuery(String value) {
    if (_searchQuery == value) {
      return;
    }
    _searchQuery = value;
    notifyListeners();
    loadJobs();
  }

  set assignedToMe(bool value) {
    if (_assignedToMe == value) {
      return;
    }
    _assignedToMe = value;
    notifyListeners();
    loadJobs();
  }

  set currentUserId(int? value) {
    if (_currentUserId == value) {
      return;
    }
    _currentUserId = value;
    if (_assignedToMe) {
      loadJobs();
    }
  }

  Future<void> loadAll() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final templatesResult = await _repository.loadAllWorkflowTemplates();
    switch (templatesResult) {
      case Ok<List<WorkflowTemplate>>():
        _templates = templatesResult.value;
      case Error<List<WorkflowTemplate>>():
        _hasLoadError = true;
    }

    final bomsResult = await _repository.loadAllBoms();
    switch (bomsResult) {
      case Ok<List<BillOfMaterials>>():
        _boms = bomsResult.value;
      case Error<List<BillOfMaterials>>():
        _hasLoadError = true;
    }

    final jobsResult = await _loadAllJobs();
    switch (jobsResult) {
      case Ok<List<OperationsJob>>():
        _jobs = jobsResult.value;
      case Error<List<OperationsJob>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadJobs() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _loadAllJobs();
    switch (result) {
      case Ok<List<OperationsJob>>():
        _jobs = result.value;
      case Error<List<OperationsJob>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<OperationsJob?> createJob(OperationsJobDraft draft) async {
    _isMutating = true;
    _hasMutationError = false;
    notifyListeners();

    final result = await _repository.createJob(
      draft,
      idempotencyKey: 'operations-job:${generateAnalyticsEventId()}',
    );
    OperationsJob? created;
    switch (result) {
      case Ok<OperationsJob>():
        created = result.value;
        _trackJobEvent('operations.job.created', result.value);
      case Error<OperationsJob>():
        _hasMutationError = true;
    }

    _isMutating = false;
    notifyListeners();
    await loadJobs();
    return created;
  }

  Map<int, List<OperationsJob>> jobsByStage(WorkflowTemplate template) {
    final byStage = <int, List<OperationsJob>>{
      for (final stage in template.stages) stage.id: <OperationsJob>[],
    };
    for (final job in _jobs) {
      if (job.workflowTemplate != template.id) {
        continue;
      }
      byStage.putIfAbsent(job.currentStage, () => <OperationsJob>[]).add(job);
    }
    return byStage;
  }

  Future<Result<List<OperationsJob>>> _loadAllJobs() {
    return _repository.loadAllJobs(
      status: _statusFilter,
      jobType: _jobTypeFilter,
      assignedTo: _assignedToMe ? _currentUserId : null,
      search: _searchQuery,
    );
  }

  void _trackJobEvent(String name, OperationsJob job) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'operations_job',
      entityId: job.id,
      attributes: {
        'job_type': job.jobType.toJson(),
        'workflow_template': job.workflowTemplate,
        'source': 'operations_ui',
      },
    );
  }
}
