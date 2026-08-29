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

  /// The board only ever shows work that is still in progress.
  ///
  /// Finished jobs are history, and history has its own screen. Keeping them
  /// off the board is the whole point of it: a technician walking past a wall
  /// display should see what is in front of them today, not a growing wall of
  /// everything the shop has ever done.
  static const _boardStatus = OperationsJobStatus.open;

  final OperationsRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<OperationsJob> _jobs = const [];
  List<WorkflowTemplate> _templates = const [];
  List<BillOfMaterials> _boms = const [];
  OperationsJobType? _jobTypeFilter;
  int? _selectedTemplateId;
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
  OperationsJobType? get jobTypeFilter => _jobTypeFilter;
  String get searchQuery => _searchQuery;
  bool get assignedToMe => _assignedToMe;
  int? get currentUserId => _currentUserId;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  bool get hasMutationError => _hasMutationError;

  List<WorkflowTemplate> get enabledTemplates =>
      _templates.where((template) => template.isActive).toList(growable: false);

  /// The workflow the board is currently showing.
  ///
  /// A shop running more than one lane (a café with a kitchen *and* a repair
  /// counter) gets a switcher rather than two boards stacked on one screen —
  /// a kanban only reads as a kanban when one set of columns owns the width.
  WorkflowTemplate? get selectedTemplate {
    final templates = enabledTemplates;
    if (templates.isEmpty) {
      return null;
    }
    for (final template in templates) {
      if (template.id == _selectedTemplateId) {
        return template;
      }
    }
    return templates.first;
  }

  set selectedTemplateId(int? value) {
    if (_selectedTemplateId == value) {
      return;
    }
    _selectedTemplateId = value;
    notifyListeners();
  }

  /// Whether the technician has narrowed the board away from its default view.
  ///
  /// The search term is deliberately excluded: `QueryEmptyState` takes it
  /// separately so it can word the escape after whichever is actually hiding
  /// the work. The default "open only" status is excluded too — counting it
  /// would tell a brand-new shop with no jobs at all to clear filters that are
  /// hiding nothing.
  bool get hasActiveFilters => _assignedToMe || _jobTypeFilter != null;

  /// Restores the default view in one round trip.
  ///
  /// Assigning the setters in turn would fire a `loadJobs()` per field and
  /// leave the board flickering through intermediate results, so the fields are
  /// reset together and reloaded once.
  void clearFilters() {
    if (!hasActiveFilters && _searchQuery.isEmpty) {
      return;
    }
    _jobTypeFilter = null;
    _assignedToMe = false;
    _searchQuery = '';
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
      status: _boardStatus,
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
