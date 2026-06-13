import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/workflow.dart';
import '../../../data/repositories/operations_repository.dart';

class WorkflowsViewModel extends ChangeNotifier {
  WorkflowsViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine;

  final OperationsRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<WorkflowTemplate> _templates = const [];
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  bool _hasMutationError = false;

  List<WorkflowTemplate> get templates => _templates;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  bool get hasMutationError => _hasMutationError;

  Future<void> loadTemplates() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadAllWorkflowTemplates();
    switch (result) {
      case Ok<List<WorkflowTemplate>>():
        _templates = result.value;
      case Error<List<WorkflowTemplate>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> save(WorkflowTemplateDraft draft) async {
    return _mutate(() async {
      final result = await _repository.saveWorkflowTemplate(draft);
      switch (result) {
        case Ok<WorkflowTemplate>():
          _trackTemplateEvent(
            draft.id == null
                ? 'operations.workflow_template.created'
                : 'operations.workflow_template.updated',
            result.value.id,
          );
          return true;
        case Error<WorkflowTemplate>():
          _hasMutationError = true;
          return false;
      }
    });
  }

  Future<bool> delete(int templateId) async {
    return _mutate(() async {
      final result = await _repository.deleteWorkflowTemplate(templateId);
      switch (result) {
        case Ok<void>():
          _trackTemplateEvent(
            'operations.workflow_template.deleted',
            templateId,
          );
          return true;
        case Error<void>():
          _hasMutationError = true;
          return false;
      }
    });
  }

  Future<bool> _mutate(Future<bool> Function() operation) async {
    _isMutating = true;
    _hasMutationError = false;
    notifyListeners();

    final outcome = await operation();
    _isMutating = false;
    notifyListeners();
    await loadTemplates();
    return outcome;
  }

  void _trackTemplateEvent(String name, int templateId) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'workflow_template',
      entityId: templateId,
      attributes: {'source': 'operations_ui'},
    );
  }
}
