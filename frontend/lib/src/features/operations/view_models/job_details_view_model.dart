import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/job_refusal.dart';
import '../../../data/models/operations_job.dart';
import '../../../data/repositories/operations_repository.dart';

class JobDetailsViewModel extends ChangeNotifier {
  JobDetailsViewModel(
    this._repository, {
    required this.jobId,
    AnalyticsEngine? analyticsEngine,
  }) : _analyticsEngine = analyticsEngine;

  final OperationsRepository _repository;
  final int jobId;
  final AnalyticsEngine? _analyticsEngine;

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
