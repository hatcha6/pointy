import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/employee.dart';
import '../../../data/models/job_refusal.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/models/workflow.dart';
import '../../../data/repositories/operations_repository.dart';
import 'job_print_actions.dart';

class JobDetailsViewModel extends ChangeNotifier {
  JobDetailsViewModel(
    this._repository, {
    required this.jobId,
    AnalyticsEngine? analyticsEngine,
    JobPrintActions? printActions,
  }) : _analyticsEngine = analyticsEngine,
       _printActions = printActions;

  final OperationsRepository _repository;
  final int jobId;
  final AnalyticsEngine? _analyticsEngine;
  final JobPrintActions? _printActions;
  bool _isPrinting = false;

  /// Whether this screen can print the intake receipt and the device sticker.
  bool get canPrintIntakeDocuments => _printActions != null;
  bool get isPrinting => _isPrinting;

  OperationsJob? _job;
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  bool _hasMutationError = false;
  JobRefusal? _lastRefusal;

  OperationsJob? get job => _job;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  bool get hasMutationError => _hasMutationError;

  /// Why the last mutation was refused, when the backend refused it for a
  /// reason the screen can act on — an unsettled handover, or an invoice above
  /// the approved price. Both are decisions, not mistakes, so the screen asks a
  /// specific question instead of showing a generic failure.
  JobRefusal? get lastRefusal => _lastRefusal;

  Future<void> loadJob() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadJob(jobId);
    switch (result) {
      case Ok<OperationsJob>():
        _job = result.value;
      case Error<OperationsJob>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> saveJob(Map<String, Object?> changes) async {
    final updated = await _mutate(
      () => _repository.updateJob(jobId, changes),
      eventName: 'operations.job.updated',
    );
    return updated != null;
  }

  Future<bool> assignEmployee(int? employeeId) async {
    final updated = await _mutate(
      () => _repository.assignJob(jobId, employeeId),
      eventName: 'operations.job.assigned',
    );
    return updated != null;
  }

  Future<bool> transition(
    int toStage, {
    String note = '',
    String handedOverTo = '',
    bool forceRelease = false,
  }) async {
    final updated = await _mutate(
      () => _repository.transitionJob(
        jobId,
        toStage: toStage,
        note: note,
        handedOverTo: handedOverTo,
        forceRelease: forceRelease,
        idempotencyKey: _newIdempotencyKey(),
      ),
      eventName: 'operations.job.transitioned',
    );
    return updated != null;
  }

  /// A move from the job screen, reported the way the shared stage-move flow
  /// wants it: whether it happened, and the refusal when there is one.
  Future<JobMoveAttempt> moveTo(
    WorkflowStage stage, {
    String handedOverTo = '',
  }) async {
    final moved = await transition(stage.id, handedOverTo: handedOverTo);
    return (moved: moved, refusal: _lastRefusal);
  }

  /// Records the price the customer agreed to, without moving the job — for a
  /// jump that passes the approval stage, which then moves it itself.
  Future<bool> recordApprovedPrice(double price) async {
    final saved = await _mutate(
      () => _repository.updateJob(jobId, {
        'approved_price': price.toStringAsFixed(2),
      }),
      eventName: 'operations.job.quote_approved',
    );
    return saved != null;
  }

  /// Who the job can be given to, or null when the list cannot be read.
  Future<List<Employee>?> loadAssignees() async {
    final result = await _repository.loadJobAssignees();
    return switch (result) {
      Ok<List<Employee>>(:final value) => value,
      Error<List<Employee>>() => null,
    };
  }

  Future<bool> addService(JobServiceDraft draft) async {
    final updated = await _mutate(
      () => _repository.addJobService(
        jobId,
        draft,
        idempotencyKey: _newIdempotencyKey(),
      ),
      eventName: 'operations.job.service_added',
    );
    return updated != null;
  }

  Future<bool> removeService(int serviceId) async {
    final updated = await _mutate(
      () => _repository.removeJobService(jobId, serviceId),
      eventName: 'operations.job.service_removed',
    );
    return updated != null;
  }

  Future<bool> hold({required String reason}) async {
    final updated = await _mutate(
      () => _repository.holdJob(jobId, reason: reason),
      eventName: 'operations.job.held',
    );
    return updated != null;
  }

  Future<bool> resume() async {
    final updated = await _mutate(
      () => _repository.resumeJob(jobId),
      eventName: 'operations.job.resumed',
    );
    return updated != null;
  }

  Future<bool> addMaterial({
    required int variant,
    required double quantity,
    bool consumeNow = false,
  }) async {
    final updated = await _mutate(
      () => _repository.addJobMaterial(
        jobId,
        variant: variant,
        quantity: quantity,
        consumeNow: consumeNow,
        idempotencyKey: _newIdempotencyKey(),
      ),
      eventName: 'operations.job.material_added',
    );
    return updated != null;
  }

  Future<bool> reverseMaterial(int materialId) async {
    final updated = await _mutate(
      () => _repository.reverseJobMaterial(jobId, materialId),
      eventName: 'operations.job.material_reversed',
    );
    return updated != null;
  }

  Future<OperationsJob?> invoice(JobInvoiceDraft draft) async {
    return _mutate(
      () => _repository.invoiceJob(
        jobId,
        draft,
        idempotencyKey: _newIdempotencyKey(),
      ),
      eventName: 'operations.job.invoiced',
    );
  }

  /// The customer said yes: record the price they agreed to, then move the
  /// job past the approval stage — the one tap that used to be an edit, a
  /// save and an advance.
  Future<bool> approveQuote(double price) async {
    final saved = await _mutate(
      () => _repository.updateJob(jobId, {
        'approved_price': price.toStringAsFixed(2),
      }),
      eventName: 'operations.job.quote_approved',
    );
    if (saved == null) {
      return false;
    }
    final next = saved.nextStage;
    return next == null ? true : transition(next.id);
  }

  /// The customer said no, or it cannot be fixed: end the work and keep the
  /// item on the shelf until it is handed back.
  Future<bool> decline(JobDeclineDraft draft) async {
    final updated = await _mutate(
      () => _repository.declineJob(
        jobId,
        draft,
        idempotencyKey: _newIdempotencyKey(),
      ),
      eventName: 'operations.job.declined',
    );
    return updated != null;
  }

  /// A declined job's item going home. Refused while a diagnosis fee is
  /// unsettled — see [lastRefusal] — unless a manager forces it with a note.
  Future<bool> handBack({
    String handedOverTo = '',
    String note = '',
    bool forceRelease = false,
  }) async {
    final updated = await _mutate(
      () => _repository.handBackJob(
        jobId,
        handedOverTo: handedOverTo,
        note: note,
        forceRelease: forceRelease,
        idempotencyKey: _newIdempotencyKey(),
      ),
      eventName: 'operations.job.handed_back',
    );
    return updated != null;
  }

  Future<JobPrintStatus> printTicket() {
    return _print((actions, job) => actions.printTicket(job));
  }

  Future<JobPrintStatus> printLabel() {
    return _print((actions, job) => actions.printLabel(job));
  }

  Future<JobPrintStatus> _print(
    Future<JobPrintStatus> Function(JobPrintActions actions, OperationsJob job)
    print,
  ) async {
    final actions = _printActions;
    final job = _job;
    if (actions == null || job == null) {
      return JobPrintStatus.failed;
    }
    _isPrinting = true;
    notifyListeners();
    final status = await print(actions, job);
    _isPrinting = false;
    notifyListeners();
    return status;
  }

  Future<bool> cancel({String reason = ''}) async {
    final updated = await _mutate(
      () => _repository.cancelJob(jobId, reason: reason),
      eventName: 'operations.job.cancelled',
    );
    return updated != null;
  }

  Future<bool> reopen() async {
    final updated = await _mutate(
      () => _repository.reopenJob(jobId),
      eventName: 'operations.job.reopened',
    );
    return updated != null;
  }

  Future<OperationsJob?> _mutate(
    Future<Result<OperationsJob>> Function() operation, {
    required String eventName,
  }) async {
    _isMutating = true;
    _hasMutationError = false;
    _lastRefusal = null;
    notifyListeners();

    final result = await operation();
    OperationsJob? updated;
    switch (result) {
      case Ok<OperationsJob>():
        updated = result.value;
        _job = result.value;
        _trackJobEvent(eventName, result.value);
      case Error<OperationsJob>():
        _hasMutationError = true;
        _lastRefusal = jobRefusalFromException(result.exception);
    }

    _isMutating = false;
    notifyListeners();
    return updated;
  }

  String _newIdempotencyKey() {
    return 'operations-job:${generateAnalyticsEventId()}';
  }

  void _trackJobEvent(String name, OperationsJob job) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'operations_job',
      entityId: jobId,
      attributes: {
        'job_type': job.jobType.toJson(),
        'status': job.status.toJson(),
        'current_stage': job.currentStage,
        'source': 'operations_ui',
      },
    );
  }
}
