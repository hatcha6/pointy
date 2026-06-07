import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/discount_rule.dart';
import '../../../data/repositories/discount_repository.dart';

class DiscountDetailsViewModel extends ChangeNotifier {
  DiscountDetailsViewModel({
    required DiscountRepository discountRepository,
    required DiscountRule initialRule,
  }) : _discountRepository = discountRepository,
       _rule = initialRule {
    load();
  }

  final DiscountRepository _discountRepository;

  DiscountRule _rule;
  DiscountRulePerformance? _performance;
  List<DiscountBeneficiary> _beneficiaries = [];
  bool _isLoading = false;
  bool _isLoadingBeneficiaries = false;
  bool _isLoadingMoreBeneficiaries = false;
  bool _hasLoadError = false;
  bool _hasBeneficiaryLoadError = false;
  bool _hasMoreBeneficiaries = true;
  int _nextBeneficiaryPage = 1;

  DiscountRule get rule => _rule;
  DiscountRulePerformance? get performance => _performance;
  List<DiscountBeneficiary> get beneficiaries =>
      List.unmodifiable(_beneficiaries);
  bool get isLoading => _isLoading;
  bool get isLoadingBeneficiaries => _isLoadingBeneficiaries;
  bool get isLoadingMoreBeneficiaries => _isLoadingMoreBeneficiaries;
  bool get hasLoadError => _hasLoadError;
  bool get hasBeneficiaryLoadError => _hasBeneficiaryLoadError;
  bool get hasMoreBeneficiaries => _hasMoreBeneficiaries;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final ruleResult = await _discountRepository.loadDiscountRule(_rule.id);
    final performanceResult = await _discountRepository
        .loadDiscountRulePerformance(_rule.id);

    switch (ruleResult) {
      case Ok<DiscountRule>(value: final rule):
        _rule = rule;
      case Error<DiscountRule>():
        _hasLoadError = true;
    }

    switch (performanceResult) {
      case Ok<DiscountRulePerformance>(value: final performance):
        _performance = performance;
      case Error<DiscountRulePerformance>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
    await loadBeneficiaries();
  }

  Future<void> loadBeneficiaries() async {
    _isLoadingBeneficiaries = true;
    _hasBeneficiaryLoadError = false;
    _hasMoreBeneficiaries = true;
    _nextBeneficiaryPage = 1;
    notifyListeners();

    final result = await _discountRepository.loadDiscountRuleBeneficiaries(
      id: _rule.id,
      page: _nextBeneficiaryPage,
    );
    switch (result) {
      case Ok<DiscountBeneficiaryPage>(value: final page):
        _beneficiaries = page.beneficiaries;
        _hasMoreBeneficiaries = page.hasMore;
        _nextBeneficiaryPage = 2;
      case Error<DiscountBeneficiaryPage>():
        _beneficiaries = [];
        _hasBeneficiaryLoadError = true;
        _hasMoreBeneficiaries = false;
    }

    _isLoadingBeneficiaries = false;
    notifyListeners();
  }

  Future<void> loadMoreBeneficiaries() async {
    if (_isLoadingBeneficiaries ||
        _isLoadingMoreBeneficiaries ||
        !_hasMoreBeneficiaries) {
      return;
    }

    _isLoadingMoreBeneficiaries = true;
    notifyListeners();

    final result = await _discountRepository.loadDiscountRuleBeneficiaries(
      id: _rule.id,
      page: _nextBeneficiaryPage,
    );
    switch (result) {
      case Ok<DiscountBeneficiaryPage>(value: final page):
        _beneficiaries = [..._beneficiaries, ...page.beneficiaries];
        _hasMoreBeneficiaries = page.hasMore;
        _nextBeneficiaryPage += 1;
      case Error<DiscountBeneficiaryPage>():
        _hasBeneficiaryLoadError = true;
        _hasMoreBeneficiaries = false;
    }

    _isLoadingMoreBeneficiaries = false;
    notifyListeners();
  }
}
