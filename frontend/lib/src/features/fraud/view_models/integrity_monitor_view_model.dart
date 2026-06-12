import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/fraud_finding.dart';
import '../../../data/repositories/fraud_repository.dart';

class IntegrityMonitorViewModel extends ChangeNotifier {
  IntegrityMonitorViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine {
    loadFindings();
  }

  final FraudRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<FraudFinding> _findings = [];
  bool _isLoading = false;
  bool _hasError = false;
  bool _isSaving = false;
  bool _hasSaveError = false;

  List<FraudFinding> get findings => List.unmodifiable(_findings);
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  bool get isSaving => _isSaving;
  bool get hasSaveError => _hasSaveError;

  List<FraudFinding> get activeFindings => List.unmodifiable(
    _findings.where((finding) => finding.status == FraudFindingStatus.active),
  );

  /// Recently triaged or auto-resolved findings — shown so the owner can see
  /// the engine has been working even when everything is quiet.
  List<FraudFinding> get settledFindings => List.unmodifiable(
    _findings.where((finding) => finding.status != FraudFindingStatus.active),
  );

  Future<void> loadFindings() async {
    _isLoading = true;
    _hasError = false;
    notifyListeners();

    final result = await _repository.loadFindings();
    switch (result) {
      case Ok<FraudFindingPage>(value: final page):
        _findings = page.findings;
      case Error<FraudFindingPage>():
        _hasError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<bool> reviewFinding(FraudFinding finding, {String note = ''}) {
    return _triage(
      finding,
      () => _repository.reviewFinding(finding.id, note: note),
      eventName: 'fraud.finding.reviewed',
    );
  }

  Future<bool> dismissFinding(FraudFinding finding, {String note = ''}) {
    return _triage(
      finding,
      () => _repository.dismissFinding(finding.id, note: note),
      eventName: 'fraud.finding.dismissed',
    );
  }

  Future<bool> reopenFinding(FraudFinding finding) {
    return _triage(
      finding,
      () => _repository.reopenFinding(finding.id),
      eventName: 'fraud.finding.reopened',
    );
  }

  Future<bool> _triage(
    FraudFinding finding,
    Future<Result<FraudFinding>> Function() action, {
    required String eventName,
  }) async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await action();
    var saved = false;
    switch (result) {
      case Ok<FraudFinding>(value: final updated):
        _findings = [
          for (final existing in _findings)
            if (existing.id == updated.id) updated else existing,
        ];
        saved = true;
        trackAuditEvent(
          _analyticsEngine,
          name: eventName,
          entityType: 'fraud_finding',
          entityId: updated.id,
          attributes: {
            'rule_code': updated.ruleCode,
            'risk_score': updated.riskScore,
            'source': 'integrity_monitor_screen',
          },
        );
      case Error<FraudFinding>():
        _hasSaveError = true;
    }
    _isSaving = false;
    notifyListeners();
    return saved;
  }
}
