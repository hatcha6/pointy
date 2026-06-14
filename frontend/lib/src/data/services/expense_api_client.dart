import '../models/expense.dart';
import '../models/expense_category.dart';
import '../models/expense_ledger_entry.dart';
import 'api_session.dart';

class ExpenseApiClient {
  const ExpenseApiClient(this._session);

  final PosApiSession _session;

  // --- categories ------------------------------------------------------------

  Future<ExpenseCategoryPage> fetchCategories({int page = 1}) async {
    final response = await _session.get(
      'expense-categories/',
      query: {'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'Expense categories request failed with status',
    );
    return ExpenseCategoryPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ExpenseCategory> createCategory(ExpenseCategoryDraft draft) async {
    final response = await _session.post(
      'expense-categories/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Expense category create failed with status',
    );
    return ExpenseCategory.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ExpenseCategory> updateCategory(
    int categoryId,
    Map<String, Object?> changes,
  ) async {
    final response = await _session.patch(
      'expense-categories/$categoryId/',
      body: changes,
    );
    _session.ensureSuccess(
      response,
      'Expense category update failed with status',
    );
    return ExpenseCategory.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteCategory(int categoryId) async {
    final response = await _session.delete('expense-categories/$categoryId/');
    _session.ensureSuccess(
      response,
      'Expense category delete failed with status',
    );
  }

  // --- expenses --------------------------------------------------------------

  Future<Expense> fetchExpense(int expenseId) async {
    final response = await _session.get('expenses/$expenseId/');
    _session.ensureSuccess(response, 'Expense request failed with status');
    return Expense.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Expense> createExpense(ExpenseDraft draft) async {
    final response = await _session.post('expenses/', body: draft.toJson());
    _session.ensureSuccess(response, 'Expense create failed with status');
    return Expense.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<Expense> updateExpense(int expenseId, ExpenseDraft draft) async {
    final response = await _session.patch(
      'expenses/$expenseId/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Expense update failed with status');
    return Expense.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<void> deleteExpense(int expenseId) async {
    final response = await _session.delete('expenses/$expenseId/');
    _session.ensureSuccess(response, 'Expense delete failed with status');
  }

  // --- unified ledger --------------------------------------------------------

  Future<ExpenseLedger> fetchLedger({
    required DateTime start,
    required DateTime end,
  }) async {
    final response = await _session.get(
      'expense-ledger/',
      query: {'start': _isoDate(start), 'end': _isoDate(end)},
    );
    _session.ensureSuccess(
      response,
      'Expense ledger request failed with status',
    );
    return ExpenseLedger.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  String _isoDate(DateTime value) {
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }
}
