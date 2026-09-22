import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/expense.dart';

/// Which bank an expense left, on the wire.
///
/// The non-obvious half is the cash case. Every other draft in the app OMITS a
/// key it has no value for, which is what keeps an older server routing the way
/// it always did. This draft cannot: it also edits, and an expense corrected
/// from card to cash has to clear the bank it used to name. An omitted key
/// would leave that bank charged for money that came out of the drawer.
void main() {
  ExpenseDraft draft({
    required ExpensePaymentMethod method,
    int? moneyAccountId,
  }) {
    return ExpenseDraft(
      categoryId: 1,
      description: 'كهرباء',
      amount: 40,
      paymentMethod: method,
      spentAt: DateTime(2026, 9, 22),
      moneyAccountId: moneyAccountId,
    );
  }

  test('a transfer carries the bank account it named', () {
    final json = draft(
      method: ExpensePaymentMethod.transfer,
      moneyAccountId: 7,
    ).toJson();

    expect(json['money_account'], 7);
  });

  test('a card expense carries it too', () {
    final json = draft(
      method: ExpensePaymentMethod.card,
      moneyAccountId: 7,
    ).toJson();

    expect(json['money_account'], 7);
  });

  test('a cash expense sends an explicit null, never the stale account', () {
    // The correction path: the form still holds the account from before the
    // cashier switched the method, and the key must go out as null anyway.
    final json = draft(
      method: ExpensePaymentMethod.cash,
      moneyAccountId: 7,
    ).toJson();

    expect(json.containsKey('money_account'), isTrue);
    expect(json['money_account'], isNull);
  });

  test(
    'a shop that names no account sends null and routes as it always did',
    () {
      final json = draft(method: ExpensePaymentMethod.transfer).toJson();

      expect(json['money_account'], isNull);
    },
  );

  test('an expense reads back the bank it left, with its mark', () {
    final expense = Expense.fromJson(const {
      'id': 1,
      'category': 2,
      'category_name': 'مرافق',
      'description': 'كهرباء',
      'amount': '40.00',
      'payment_method': 'transfer',
      'spent_at': '2026-09-22',
      'reference': '',
      'notes': '',
      'paid_from_register': false,
      'created_by_username': null,
      'money_account': 7,
      'money_account_name': 'حساب المحل',
      'money_account_bank_slug': 'jbank',
      'money_account_bank_name': 'مصرف الجمهورية',
    });

    expect(expense.bankAccount?.id, 7);
    expect(expense.bankAccount?.displayName, 'حساب المحل');
    expect(expense.bankAccount?.bankSlug, 'jbank');
  });

  test('an expense with no account reads back nothing at all', () {
    // Never an empty instance: a caller must not be able to draw a blank bank
    // row by forgetting to check.
    final expense = Expense.fromJson(const {
      'id': 1,
      'category': 2,
      'category_name': 'مرافق',
      'description': 'كهرباء',
      'amount': '40.00',
      'payment_method': 'cash',
      'spent_at': '2026-09-22',
      'reference': '',
      'notes': '',
      'paid_from_register': true,
      'created_by_username': null,
    });

    expect(expense.bankAccount, isNull);
  });
}
