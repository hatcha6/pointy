import 'bank_account_ref.dart';

/// Payment methods an expense can be settled with. Mirrors the backend
/// ``Expense.PaymentMethod`` choices.
enum ExpensePaymentMethod {
  cash,
  card,
  transfer;

  String get apiValue => name;

  static ExpensePaymentMethod fromApi(String? value) {
    return ExpensePaymentMethod.values.firstWhere(
      (method) => method.name == value,
      orElse: () => ExpensePaymentMethod.cash,
    );
  }
}

/// A single ad-hoc shop expense (rent, utilities, ...). When paid in cash from
/// an open register, [paidFromRegister] is true and a drawer pay-out was booked.
class Expense {
  const Expense({
    required this.id,
    required this.categoryId,
    required this.categoryName,
    required this.description,
    required this.amount,
    required this.paymentMethod,
    required this.spentAt,
    required this.reference,
    required this.notes,
    required this.paidFromRegister,
    required this.createdByUsername,
    this.bankAccount,
  });

  final int id;
  final int categoryId;
  final String categoryName;
  final String description;
  final double amount;
  final ExpensePaymentMethod paymentMethod;
  final DateTime spentAt;
  final String reference;
  final String notes;
  final bool paidFromRegister;
  final String? createdByUsername;

  /// Which of the shop's bank accounts this money left. Null on cash, and on
  /// every expense a shop with one bank account recorded.
  final BankAccountRef? bankAccount;

  factory Expense.fromJson(Map<String, Object?> json) {
    return Expense(
      id: json['id'] as int,
      categoryId: (json['category'] as num?)?.toInt() ?? 0,
      categoryName: json['category_name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      amount: double.tryParse(json['amount']?.toString() ?? '') ?? 0,
      paymentMethod: ExpensePaymentMethod.fromApi(
        json['payment_method']?.toString(),
      ),
      spentAt:
          DateTime.tryParse(json['spent_at']?.toString() ?? '') ??
          DateTime.now(),
      reference: json['reference']?.toString() ?? '',
      notes: json['notes']?.toString() ?? '',
      paidFromRegister: json['paid_from_register'] == true,
      createdByUsername: json['created_by_username']?.toString(),
      bankAccount: BankAccountRef.fromPaymentJson(json),
    );
  }
}

class ExpensePage {
  const ExpensePage({required this.expenses, required this.hasMore});

  final List<Expense> expenses;
  final bool hasMore;

  factory ExpensePage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(Expense.fromJson)
        .toList(growable: false);

    return ExpensePage(expenses: results, hasMore: json['next'] != null);
  }
}

class ExpenseDraft {
  const ExpenseDraft({
    required this.categoryId,
    required this.description,
    required this.amount,
    required this.paymentMethod,
    required this.spentAt,
    this.reference = '',
    this.notes = '',
    this.payFromRegister = false,
    this.moneyAccountId,
  });

  final int categoryId;
  final String description;
  final double amount;
  final ExpensePaymentMethod paymentMethod;
  final DateTime spentAt;
  final String reference;
  final String notes;
  final bool payFromRegister;

  /// The bank account the money left. Sent as an explicit null on a cash
  /// expense — unlike every other draft in the app, which omits the key —
  /// because this one also EDITS: an expense switched from card to cash has to
  /// clear the bank it used to name, and an omitted key would leave it.
  final int? moneyAccountId;

  Map<String, Object?> toJson() {
    return {
      'category': categoryId,
      'description': description,
      'amount': amount.toStringAsFixed(2),
      'payment_method': paymentMethod.apiValue,
      'spent_at':
          '${spentAt.year.toString().padLeft(4, '0')}-'
          '${spentAt.month.toString().padLeft(2, '0')}-'
          '${spentAt.day.toString().padLeft(2, '0')}',
      'reference': reference,
      'notes': notes,
      'pay_from_register': payFromRegister,
      'money_account': paymentMethod == ExpensePaymentMethod.cash
          ? null
          : moneyAccountId,
    };
  }
}
