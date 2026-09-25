import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/employee.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/employees/views/payroll_labels.dart';
import 'package:pointy_frontend/src/shared/payment_labels.dart';

/// What the till and the payroll screens read off the wire for a staff
/// purchase: the staff account, the salary deduction that settles it, and the
/// payroll row that says which invoice it took.
void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  group('the salary deduction a payroll run pays with', () {
    test('is read as itself, not as cash', () {
      final method = PaymentMethod.fromApiValue('salary_deduction');

      expect(method, PaymentMethod.salaryDeduction);
      expect(paymentMethodLabel(l10n, method), 'خصم من الراتب');
    });

    test('is never offered at a till', () {
      expect(PaymentMethod.salaryDeduction.isTillTender, isFalse);
      expect(PaymentMethod.values.where((method) => method.isTillTender), [
        PaymentMethod.cash,
        PaymentMethod.card,
        PaymentMethod.transfer,
      ]);
    });
  });

  group('a staff account', () {
    Customer parse(Object? staffEmployee) => Customer.fromJson({
      'id': 7,
      'customer_number': 'C1',
      'full_name': 'سلمى',
      'staff_employee': staffEmployee,
    });

    test('knows it is one', () {
      expect(parse(3).isStaffAccount, isTrue);
      expect(parse(3).staffEmployeeId, 3);
      expect(parse(null).isStaffAccount, isFalse);
    });

    test('is still one after a parked cart is restored', () {
      final restored = Customer.fromJson(parse(3).toJson());

      expect(restored.isStaffAccount, isTrue);
    });
  });

  group('a payroll deduction for a staff purchase', () {
    final adjustment = PayrollAdjustment.fromJson({
      'id': 1,
      'direction': 'deduction',
      'adjustment_type': 'staff_purchase',
      'amount': '45.00',
      'order': 12,
      'order_receipt_number': 'R20260915000123',
    });

    test('names the invoice it takes', () {
      expect(adjustment.isStaffPurchase, isTrue);
      expect(
        payrollAdjustmentTypeLabel(l10n, adjustment.adjustmentType),
        'مشتريات موظف',
      );
      expect(payrollAdjustmentNote(l10n, adjustment), 'فاتورة R20260915000123');
    });

    test('leaves every other row showing its own note', () {
      final loan = PayrollAdjustment.fromJson({
        'id': 2,
        'direction': 'deduction',
        'adjustment_type': 'loan',
        'amount': '100.00',
        'notes': 'قسط',
      });

      expect(loan.isStaffPurchase, isFalse);
      expect(payrollAdjustmentNote(l10n, loan), 'قسط');
    });
  });
}
