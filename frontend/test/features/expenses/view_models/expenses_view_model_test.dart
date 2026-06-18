import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/expense_category.dart';
import 'package:pointy_frontend/src/data/models/expense_ledger_entry.dart';
import 'package:pointy_frontend/src/data/repositories/expense_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/expenses/view_models/expenses_view_model.dart';

void main() {
  ExpenseLedgerEntry entry(ExpenseLedgerSource source, double amount) {
    return ExpenseLedgerEntry(
      source: source,
      date: DateTime(2026, 6, 1),
      amount: amount,
      description: 'row',
      category: null,
      paymentMethod: 'cash',
      reference: '',
      relatedId: null,
    );
  }

  ExpenseLedger ledgerWith(List<ExpenseLedgerEntry> entries) {
    return ExpenseLedger(
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 6, 30),
      entries: entries,
      totalsBySource: const {},
      total: entries.fold(0, (sum, e) => sum + e.amount),
      truncated: false,
      totalCount: entries.length,
    );
  }

  test('load populates the ledger and categories', () async {
    final repo = _FakeExpenseRepository()
      ..ledger = ledgerWith([entry(ExpenseLedgerSource.expense, 50)])
      ..categories = const [
        ExpenseCategory(id: 1, name: 'إيجار', isActive: true, displayOrder: 0),
        ExpenseCategory(id: 2, name: 'قديم', isActive: false, displayOrder: 1),
      ];
    final vm = ExpensesViewModel(repo);
    addTearDown(vm.dispose);

    await vm.load();

    expect(vm.isLoading, isFalse);
    expect(vm.hasLoadError, isFalse);
    expect(vm.ledger.entries, hasLength(1));
    expect(vm.categories, hasLength(2));
    expect(vm.activeCategories, hasLength(1));
  });

  test('load flags an error when the ledger fails', () async {
    final repo = _FakeExpenseRepository(); // ledger stays null -> Error
    final vm = ExpensesViewModel(repo);
    addTearDown(vm.dispose);

    await vm.load();

    expect(vm.hasLoadError, isTrue);
  });

  test('toggleSource hides a source from the visible rows and total', () async {
    final repo = _FakeExpenseRepository()
      ..ledger = ledgerWith([
        entry(ExpenseLedgerSource.expense, 30),
        entry(ExpenseLedgerSource.registerPayout, 20),
        entry(ExpenseLedgerSource.payroll, 100),
      ]);
    final vm = ExpensesViewModel(repo);
    addTearDown(vm.dispose);
    await vm.load();

    expect(vm.visibleEntries, hasLength(3));
    expect(vm.visibleTotal, 150);

    vm.toggleSource(ExpenseLedgerSource.payroll);

    expect(vm.isSourceVisible(ExpenseLedgerSource.payroll), isFalse);
    expect(vm.visibleEntries, hasLength(2));
    expect(vm.visibleTotal, 50);

    vm.showAllSources();

    expect(vm.visibleTotal, 150);
  });

  test('showPreviousMonth shifts the period back and reloads', () async {
    final repo = _FakeExpenseRepository()..ledger = ledgerWith(const []);
    final vm = ExpensesViewModel(repo);
    addTearDown(vm.dispose);
    await vm.load();
    final loadsBefore = repo.loadLedgerCount;
    final startBefore = vm.periodStart;

    await vm.showPreviousMonth();

    expect(repo.loadLedgerCount, greaterThan(loadsBefore));
    expect(vm.periodStart.isBefore(startBefore), isTrue);
    // periodEnd is the last day of the (shifted) start month.
    expect(vm.periodEnd.month, vm.periodStart.month);
  });
}

class _FakeExpenseRepository extends ExpenseRepository {
  _FakeExpenseRepository() : super(PosApiService());

  ExpenseLedger? ledger;
  List<ExpenseCategory> categories = const [];
  int loadLedgerCount = 0;

  @override
  Future<Result<ExpenseLedger>> loadLedger({
    required DateTime start,
    required DateTime end,
  }) async {
    loadLedgerCount++;
    final value = ledger;
    return value == null ? Error(Exception('no ledger')) : Ok(value);
  }

  @override
  Future<Result<List<ExpenseCategory>>> loadCategories() async {
    return Ok(categories);
  }
}
