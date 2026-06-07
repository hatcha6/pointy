import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/repositories/discount_repository.dart';

class DiscountManagementViewModel extends ChangeNotifier {
  DiscountManagementViewModel(
    this._discountRepository, {
    AnalyticsEngine? analyticsEngine,
  }) : _analyticsEngine = analyticsEngine {
    loadRules();
  }

  final DiscountRepository _discountRepository;
  final AnalyticsEngine? _analyticsEngine;

  DiscountRepository get discountRepository => _discountRepository;

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
    return _save(
      () => _discountRepository.createDiscountRule(draft),
      eventName: 'discounts.management.rule.created',
    );
  }

  Future<bool> updateRule({
    required DiscountRule rule,
    required DiscountRuleDraft draft,
  }) async {
    return _save(
      () => _discountRepository.updateDiscountRule(id: rule.id, draft: draft),
      eventName: 'discounts.management.rule.updated',
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
      eventName: isActive
          ? 'discounts.management.rule.enabled'
          : 'discounts.management.rule.disabled',
    );
  }

  Future<bool> archiveRule(DiscountRule rule) async {
    return _save(
      () => _discountRepository.archiveDiscountRule(rule.id),
      eventName: 'discounts.management.rule.archived',
    );
  }

  Future<bool> _save(
    Future<Result<DiscountRule>> Function() operation, {
    required String eventName,
  }) async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await operation();
    _isSaving = false;
    switch (result) {
      case Ok<DiscountRule>(value: final rule):
        _upsertRule(rule);
        _trackRuleChanged(name: eventName, rule: rule);
        notifyListeners();
        return true;
      case Error<DiscountRule>():
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }

  void _trackRuleChanged({required String name, required DiscountRule rule}) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'discount_rule',
      entityId: rule.id,
      attributes: {
        'discount_rule_id': rule.id,
        'discount_rule_name': rule.name,
        'channel': rule.channel.apiValue,
        'application_type': rule.applicationType.apiValue,
        'coupon_code_present': rule.couponCode.trim().isNotEmpty,
        'scope': rule.scope.apiValue,
        'value_type': rule.valueType.apiValue,
        'exclusive': rule.exclusive,
        'is_active': rule.isActive,
        'has_schedule': rule.startsAt != null || rule.endsAt != null,
        'has_usage_limit': rule.usageLimit != null,
        'source': 'discount_management',
      },
      metrics: {
        'value': rule.value,
        'priority': rule.priority,
        'constraint_count': _constraintCount(rule),
        'redemption_count': rule.redemptionCount,
        'applied_count': rule.appliedCount,
      },
    );
  }

  int _constraintCount(DiscountRule rule) {
    return rule.products.length +
        rule.variants.length +
        rule.productCategories.length +
        rule.customers.length +
        rule.suppliers.length;
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
