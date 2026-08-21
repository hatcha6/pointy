import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/expense.dart';
import '../../../data/models/expense_category.dart';
import '../../../data/models/expense_ledger_entry.dart';
import '../../../data/repositories/expense_repository.dart';

/// Drives the unified expenses screen: the month-bounded ledger across all
/// sources, the managed categories used by the editor, client-side source
/// filtering, and create/update/delete of ad-hoc expenses.
class ExpensesViewModel extends ChangeNotifier {
  ExpensesViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine {
    final now = DateTime.now();
    _periodStart = DateTime(now.year, now.month, 1);
    _periodEnd = DateTime(now.year, now.month + 1, 0);
    _ledger = ExpenseLedger.empty(_periodStart, _periodEnd);
  }

  final ExpenseRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  late DateTime _periodStart;
  late DateTime _periodEnd;
  late ExpenseLedger _ledger;
  List<ExpenseCategory> _categories = const [];
  final Set<ExpenseLedgerSource> _hiddenSources = {};
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;

  DateTime get periodStart => _periodStart;
  DateTime get periodEnd => _periodEnd;
  ExpenseLedger get ledger => _ledger;
  List<ExpenseCategory> get categories => _categories;
  List<ExpenseCategory> get activeCategories => _categories
      .where((category) => category.isActive)
      .toList(growable: false);
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;

  bool get isCurrentMonth {
    final now = DateTime.now();
    return _periodStart.year == now.year && _periodStart.month == now.month;
  }

  bool isSourceVisible(ExpenseLedgerSource source) =>
      !_hiddenSources.contains(source);

  /// Whether the source chips are hiding rows the month actually has. False
  /// for a month with no spending at all, so an empty list is only ever
  /// blamed on the filters when clearing them would really bring rows back.
  bool get isFilteredToNothing =>
      _hiddenSources.isNotEmpty && _ledger.entries.isNotEmpty;

  /// The ledger rows currently visible given the source-filter chips.
  List<ExpenseLedgerEntry> get visibleEntries => _ledger.entries
      .where((entry) => isSourceVisible(entry.source))
      .toList(growable: false);

  /// Total of the visible rows — reflects active source filters.
  double get visibleTotal =>
      visibleEntries.fold(0, (sum, entry) => sum + entry.amount);

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final ledgerResult = await _repository.loadLedger(
      start: _periodStart,
      end: _periodEnd,
    );
    switch (ledgerResult) {
      case Ok<ExpenseLedger>():
        _ledger = ledgerResult.value;
      case Error<ExpenseLedger>():
        _hasLoadError = true;
    }
    await _loadCategories();

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _loadCategories() async {
    final result = await _repository.loadCategories();
    if (result is Ok<List<ExpenseCategory>>) {
      _categories = result.value;
    }
  }

  void toggleSource(ExpenseLedgerSource source) {
    if (!_hiddenSources.remove(source)) {
      _hiddenSources.add(source);
    }
    notifyListeners();
  }

  void showAllSources() {
    _hiddenSources.clear();
    notifyListeners();
  }

  Future<void> showPreviousMonth() {
    _shiftMonth(-1);
    return load();
  }

  Future<void> showNextMonth() {
    _shiftMonth(1);
    return load();
  }

  void _shiftMonth(int delta) {
    final anchor = DateTime(_periodStart.year, _periodStart.month + delta, 1);
    _periodStart = anchor;
    _periodEnd = DateTime(anchor.year, anchor.month + 1, 0);
  }

  Future<Result<Expense>> loadExpense(int expenseId) =>
      _repository.loadExpense(expenseId);

  Future<bool> createExpense(ExpenseDraft draft) {
    return _mutate(() async {
      final result = await _repository.createExpense(draft);
      switch (result) {
        case Ok<Expense>():
          _trackMutation('expenses.expense.created', result.value.id, draft);
          return true;
        case Error<Expense>():
          return false;
      }
    });
  }

  Future<bool> updateExpense(int expenseId, ExpenseDraft draft) {
    return _mutate(() async {
      final result = await _repository.updateExpense(expenseId, draft);
      switch (result) {
        case Ok<Expense>():
          _trackMutation('expenses.expense.updated', expenseId, draft);
          return true;
        case Error<Expense>():
          return false;
      }
    });
  }

  Future<bool> deleteExpense(int expenseId) {
    return _mutate(() async {
      final result = await _repository.deleteExpense(expenseId);
      switch (result) {
        case Ok<void>():
          trackAuditEvent(
            _analyticsEngine,
            name: 'expenses.expense.deleted',
            entityType: 'expense',
            entityId: expenseId,
            attributes: const {'source': 'expenses'},
          );
          return true;
        case Error<void>():
          return false;
      }
    });
  }

  Future<bool> _mutate(Future<bool> Function() operation) async {
    _isMutating = true;
    notifyListeners();

    final outcome = await operation();
    _isMutating = false;
    notifyListeners();
    await load();
    return outcome;
  }

  void _trackMutation(String name, int expenseId, ExpenseDraft draft) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'expense',
      entityId: expenseId,
      attributes: {
        'payment_method': draft.paymentMethod.apiValue,
        'pay_from_register': draft.payFromRegister,
        'source': 'expenses',
      },
      metrics: {'amount': draft.amount},
    );
  }
}
