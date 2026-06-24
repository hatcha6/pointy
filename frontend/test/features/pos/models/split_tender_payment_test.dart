import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/features/pos/models/split_tender_payment.dart';

void main() {
  const calculator = SplitTenderPaymentCalculator();

  group('SplitTenderPaymentCalculator', () {
    test('applies cash overpayment as change due', () {
      final tenders = const [
        SplitTenderInput(method: PaymentMethod.cash, amount: 10),
      ];

      final summary = calculator.summary(total: 7, tenders: tenders);
      final payments = calculator.appliedPayments(total: 7, tenders: tenders);

      expect(summary.paid, 10);
      expect(summary.remaining, 0);
      expect(summary.changeDue, 3);
      expect(payments, hasLength(1));
      expect(payments?.single.method, PaymentMethod.cash);
      expect(payments?.single.amount, 7);
    });

    test('rejects overpayment when cash cannot cover the change', () {
      final tenders = const [
        SplitTenderInput(method: PaymentMethod.cash, amount: 2),
        SplitTenderInput(method: PaymentMethod.card, amount: 12),
      ];

      final payments = calculator.appliedPayments(total: 10, tenders: tenders);

      expect(payments, isNull);
    });

    test('preserves split tender order while reducing cash overage', () {
      final tenders = const [
        SplitTenderInput(method: PaymentMethod.card, amount: 9),
        SplitTenderInput(method: PaymentMethod.cash, amount: 5),
      ];

      final payments = calculator.appliedPayments(total: 10, tenders: tenders);

      expect(payments, hasLength(2));
      expect(payments?[0].method, PaymentMethod.card);
      expect(payments?[0].amount, 9);
      expect(payments?[1].method, PaymentMethod.cash);
      expect(payments?[1].amount, 1);
    });

    test('credit down-payment accepts a partial tender', () {
      final tenders = const [
        SplitTenderInput(method: PaymentMethod.cash, amount: 4),
      ];

      final payments = calculator.appliedPayments(
        total: 10,
        tenders: tenders,
        allowPartial: true,
      );

      expect(payments, hasLength(1));
      expect(payments?.single.method, PaymentMethod.cash);
      expect(payments?.single.amount, 4);
    });

    test('credit down-payment accepts an empty tender (fully on credit)', () {
      final payments = calculator.appliedPayments(
        total: 10,
        tenders: const [],
        allowPartial: true,
      );

      expect(payments, isNotNull);
      expect(payments, isEmpty);
    });

    test('credit down-payment rejects a tender above the total', () {
      final tenders = const [
        SplitTenderInput(method: PaymentMethod.card, amount: 12),
      ];

      final payments = calculator.appliedPayments(
        total: 10,
        tenders: tenders,
        allowPartial: true,
      );

      // A card over-tender can't make change, so it is rejected.
      expect(payments, isNull);
    });

    test('calculates the adjacent split tender balance', () {
      final tenders = const [
        SplitTenderInput(method: PaymentMethod.cash, amount: 5),
        SplitTenderInput(method: PaymentMethod.card, amount: 2),
      ];
      final balanceIndex = calculator.balanceTenderIndex(
        editedIndex: 0,
        tenderCount: tenders.length,
      );

      final balanceAmount = calculator.balanceTenderAmount(
        total: 7,
        tenders: tenders,
        balanceIndex: balanceIndex,
      );

      expect(balanceIndex, 1);
      expect(balanceAmount, 2);
    });
  });
}
