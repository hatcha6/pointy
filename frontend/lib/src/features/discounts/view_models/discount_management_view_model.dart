import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/repositories/discount_repository.dart';

class DiscountManagementViewModel extends ChangeNotifier {
  DiscountManagementViewModel(this._discountRepository) {
    loadRules();
  }

  final DiscountRepository _discountRepository;

  List<DiscountRule> _rules = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isSaving = false;
  bool _hasLoadError = false;
  bool _hasSaveError = false;
  bool _hasMoreRules = true;
  int _nextPage = 1;
  DiscountRuleQuery _query = const DiscountRuleQuery();

  List<DiscountRule> get rules => List.unmodifiable(_rules);
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isSaving => _isSaving;
  bool get hasLoadError => _hasLoadError;
  bool get hasSaveError => _hasSaveError;
  bool get hasMoreRules => _hasMoreRules;
  DiscountRuleQuery get query => _query;

  Future<void> loadRules() async {
    _isLoading = true;
    _hasLoadError = false;
    _hasSaveError = false;
    _hasMoreRules = true;
    _nextPage = 1;
    notifyListeners();

    final result = await _discountRepository.loadDiscountRules(
      query: _query,
      page: _nextPage,
    );
    switch (result) {
      case Ok<DiscountRulePage>():
        _rules = result.value.rules;
        _hasMoreRules = result.value.hasMore;
        _nextPage = 2;
      case Error<DiscountRulePage>():
        _rules = [];
        _hasLoadError = true;
        _hasMoreRules = false;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMoreRules() async {
    if (_isLoading || _isLoadingMore || !_hasMoreRules) {
      return;
    }

    _isLoadingMore = true;
    notifyListeners();

    final result = await _discountRepository.loadDiscountRules(
      query: _query,
      page: _nextPage,
    );
    switch (result) {
      case Ok<DiscountRulePage>():
        _rules = [..._rules, ...result.value.rules];
        _hasMoreRules = result.value.hasMore;
        _nextPage += 1;
      case Error<DiscountRulePage>():
        _hasLoadError = true;
        _hasMoreRules = false;
    }

    _isLoadingMore = false;
    notifyListeners();
  }

  Future<void> updateSearch(String search) async {
    if (search == _query.search) {
      return;
    }
    _query = _query.copyWith(search: search);
    await loadRules();
  }

  Future<void> applyQuery(DiscountRuleQuery query) async {
    if (query == _query) {
      return;
    }
    _query = query;
    await loadRules();
  }

  Future<bool> createRule(DiscountRuleDraft draft) async {
    return _save(() => _discountRepository.createDiscountRule(draft));
  }

  Future<bool> updateRule({
    required DiscountRule rule,
    required DiscountRuleDraft draft,
  }) async {
    return _save(
      () => _discountRepository.updateDiscountRule(id: rule.id, draft: draft),
    );
  }

  Future<bool> setRuleActive(DiscountRule rule, bool isActive) async {
    if (rule.isActive == isActive) {
      return true;
    }
    return _save(
      () => isActive
          ? _discountRepository.enableDiscountRule(rule.id)
          : _discountRepository.disableDiscountRule(rule.id),
    );
  }

  Future<bool> archiveRule(DiscountRule rule) async {
    return _save(() => _discountRepository.archiveDiscountRule(rule.id));
  }

  Future<bool> _save(Future<Result<DiscountRule>> Function() operation) async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await operation();
    _isSaving = false;
    switch (result) {
      case Ok<DiscountRule>(value: final rule):
        _upsertRule(rule);
        notifyListeners();
        return true;
      case Error<DiscountRule>():
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }

  void _upsertRule(DiscountRule rule) {
    final index = _rules.indexWhere((existing) => existing.id == rule.id);
    if (index == -1) {
      _rules = [rule, ..._rules];
      return;
    }
    final rules = [..._rules];
    rules[index] = rule;
    _rules = rules;
  }
}
