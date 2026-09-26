import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/bill_of_materials.dart';
import '../../../data/models/job_refusal.dart';
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
  List<OperationsJob> _awaitingHandBack = const [];
  List<WorkflowTemplate> _templates = const [];
  String _searchQuery = '';
  bool _assignedToMe = false;
  int? _currentUserId;
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  bool _hasMutationError = false;

  List<OperationsJob> get jobs => _jobs;

  /// Declined jobs whose item is still here, waiting for its owner. Finished
  /// work, so not a column — but the phone is on the shelf, and the board is
  /// where the counter looks for what the shop is holding.
  List<OperationsJob> get awaitingHandBack => _awaitingHandBack;
  List<WorkflowTemplate> get templates => _templates;
  String get searchQuery => _searchQuery;
  bool get assignedToMe => _assignedToMe;
  int? get currentUserId => _currentUserId;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  bool get hasMutationError => _hasMutationError;

  /// The kinds of work this shop runs, one board lane each.
  ///
  /// Which workflows are live is the shop's choice — its type at setup, its
  /// switches in the operations settings — and the server keeps the built-in
  /// ones in step with it. The board shows every live one and offers no
  /// switcher: a phone shop has one lane, and the rare shop with two sees
  /// both rather than having one hidden behind a chip.
  List<WorkflowTemplate> get enabledTemplates =>
      _templates.where((template) => template.isActive).toList(growable: false);

  /// Whether any live lane works from recipes — production batches, or a
  /// kitchen cooking made-to-order dishes. A repair shop has no use for them.
  bool get usesRecipes => enabledTemplates.any(
    (template) =>
        template.jobType == OperationsJobType.production ||
        template.jobType == OperationsJobType.kitchen,
  );

  /// Whether the technician has narrowed the board away from its default view.
  ///
  /// The search term is deliberately excluded: `QueryEmptyState` takes it
  /// separately so it can word the escape after whichever is actually hiding
  /// the work. The default "open only" status is excluded too — counting it
  /// would tell a brand-new shop with no jobs at all to clear filters that are
  /// hiding nothing.
  bool get hasActiveFilters => _assignedToMe;

  /// Restores the default view in one round trip.
  ///
  /// Assigning the setters in turn would fire a `loadJobs()` per field and
  /// leave the board flickering through intermediate results, so the fields are
  /// reset together and reloaded once.
  void clearFilters() {
    if (!hasActiveFilters && _searchQuery.isEmpty) {
      return;
    }
    _assignedToMe = false;
    _searchQuery = '';
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

    // Recipes are NOT loaded here. Only a production batch needs them, and
    // the list is behind a permission a repair counter's cashier does not
    // hold: asking for it on every board load 403'd, and the refusal marked
    // the whole board failed — an empty board read "failed to load jobs" to
    // every cashier at a phone shop (field export, 2026-09-25).

    final jobsResult = await _loadAllJobs();
    switch (jobsResult) {
      case Ok<List<OperationsJob>>():
        _jobs = jobsResult.value;
      case Error<List<OperationsJob>>():
        _hasLoadError = true;
    }
    await _loadAwaitingHandBack();

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
    await _loadAwaitingHandBack();

    _isLoading = false;
    notifyListeners();
  }

  /// Follows the board's search, so a ticket scanned into it finds a declined
  /// phone as readily as one still being worked on. A failure leaves the shelf
  /// as it was rather than blanking the board: these jobs are a side list.
  Future<void> _loadAwaitingHandBack() async {
    final result = await _repository.loadJobsAwaitingHandBack(
      search: _searchQuery,
    );
    if (result case Ok<List<OperationsJob>>(value: final jobs)) {
      _awaitingHandBack = jobs;
    }
  }

  /// The live recipes for a new production batch, or null when they cannot
  /// be read — including by someone the recipes are not shown to.
  Future<List<BillOfMaterials>?> loadActiveRecipes() async {
    final result = await _repository.loadAllBoms(isActive: true);
    return switch (result) {
      Ok<List<BillOfMaterials>>(:final value) => value,
      Error<List<BillOfMaterials>>() => null,
    };
  }

  /// Moves [job] to [stage] from the board, then refreshes it.
  Future<JobMoveAttempt> moveJob(
    OperationsJob job,
    WorkflowStage stage, {
    String handedOverTo = '',
  }) async {
    final result = await _repository.transitionJob(
      job.id,
      toStage: stage.id,
      handedOverTo: handedOverTo,
      idempotencyKey: 'operations-job:${generateAnalyticsEventId()}',
    );
    switch (result) {
      case Ok<OperationsJob>():
        _trackJobEvent('operations.job.transitioned', result.value);
        await loadJobs();
        return (moved: true, refusal: null);
      case Error<OperationsJob>():
        return (
          moved: false,
          refusal: jobRefusalFromException(result.exception),
        );
    }
  }

  /// Records the price the customer agreed to, for a move that passes the
  /// approval stage.
  Future<bool> recordApprovedPrice(OperationsJob job, double price) async {
    final result = await _repository.updateJob(job.id, {
      'approved_price': price.toStringAsFixed(2),
    });
    return result is Ok<OperationsJob>;
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

  // A reload fired by a filter change is not awaited, and it now makes two
  // requests — the board, then the declined phones on the shelf — so leaving
  // the screen mid-reload is ordinary. Swallow the late notification rather
  // than assert "used after disposed", as the catalog and invoice view models
  // do for the same reason.
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (_disposed) {
      return;
    }
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
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
