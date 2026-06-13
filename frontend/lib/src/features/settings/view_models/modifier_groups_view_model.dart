import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/modifier_group.dart';
import '../../../data/repositories/modifier_group_repository.dart';

class ModifierGroupsViewModel extends ChangeNotifier {
  ModifierGroupsViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine;

  final ModifierGroupRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  List<ModifierGroup> _groups = const [];
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;
  bool _hasMutationError = false;

  List<ModifierGroup> get groups => _groups;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;
  bool get hasMutationError => _hasMutationError;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadGroups();
    switch (result) {
      case Ok<List<ModifierGroup>>():
        _groups = result.value;
      case Error<List<ModifierGroup>>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> createGroup(ModifierGroupDraft draft) {
    return _mutate(() async {
      final result = await _repository.createGroup(draft);
      switch (result) {
        case Ok<ModifierGroup>():
          _track('settings.modifier_group.created', result.value);
          return true;
        case Error<ModifierGroup>():
          _hasMutationError = true;
          return false;
      }
    });
  }

  Future<bool> updateGroup(int groupId, ModifierGroupDraft draft) {
    return _mutate(() async {
      final result = await _repository.updateGroup(groupId, draft);
      switch (result) {
        case Ok<ModifierGroup>():
          _track('settings.modifier_group.updated', result.value);
          return true;
        case Error<ModifierGroup>():
          _hasMutationError = true;
          return false;
      }
    });
  }

  Future<bool> deleteGroup(ModifierGroup group) {
    return _mutate(() async {
      final result = await _repository.deleteGroup(group.id);
      switch (result) {
        case Ok<void>():
          _track('settings.modifier_group.deleted', group);
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
    await load();
    return outcome;
  }

  void _track(String name, ModifierGroup group) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'modifier_group',
      entityId: group.id,
      attributes: {
        'option_count': group.options.length,
        'source': 'shop_settings',
      },
    );
  }
}
