import '../../core/result.dart';
import '../models/expense.dart';
import '../models/expense_category.dart';
import '../models/expense_ledger_entry.dart';
import '../services/pos_api_service.dart';

class ExpenseRepository {
  ExpenseRepository(this._service);

  final PosApiService _service;

  Future<Result<List<ExpenseCategory>>> loadCategories() async {
    return Result.guard(() async {
      final categories = <ExpenseCategory>[];
      var page = 1;
      var hasMore = true;
      while (hasMore) {
        final result = await _service.fetchExpenseCategories(page: page);
        categories.addAll(result.categories);
        hasMore = result.hasMore;
        page += 1;
      }
      return categories;
    });
  }

  Future<Result<ExpenseCategory>> createCategory(ExpenseCategoryDraft draft) {
    return Result.guard(() => _service.createExpenseCategory(draft));
  }

  Future<Result<ExpenseCategory>> updateCategory(
    int categoryId,
    Map<String, Object?> changes,
  ) {
    return Result.guard(
      () => _service.updateExpenseCategory(categoryId, changes),
    );
  }

  Future<Result<void>> deleteCategory(int categoryId) {
    return Result.guard(() => _service.deleteExpenseCategory(categoryId));
  }

  Future<Result<ExpenseLedger>> loadLedger({
    required DateTime start,
    required DateTime end,
  }) {
    return Result.guard(
      () => _service.fetchExpenseLedger(start: start, end: end),
    );
  }

  Future<Result<Expense>> loadExpense(int expenseId) {
    return Result.guard(() => _service.fetchExpense(expenseId));
  }

  Future<Result<Expense>> createExpense(ExpenseDraft draft) {
    return Result.guard(() => _service.createExpense(draft));
  }

  Future<Result<Expense>> updateExpense(int expenseId, ExpenseDraft draft) {
    return Result.guard(() => _service.updateExpense(expenseId, draft));
  }

  Future<Result<Expense>> cancelExpense(int expenseId, {String reason = ''}) {
    return Result.guard(
      () => _service.cancelExpense(expenseId, reason: reason),
    );
  }
}
