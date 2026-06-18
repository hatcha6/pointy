import '../../../core/parsing.dart';
import '../../../data/models/card_payment_receipt.dart';
import '../../../data/models/sale_order.dart';

class SplitTenderInput {
  const SplitTenderInput({
    required this.method,
    required this.amount,
    this.cardReceipt,
  });

  final PaymentMethod method;
  final double amount;
  final CardPaymentReceipt? cardReceipt;
}

class SplitTenderPaymentSummary {
  const SplitTenderPaymentSummary({
    required this.paid,
    required this.remaining,
    required this.changeDue,
  });

  final double paid;
  final double remaining;
  final double changeDue;
}

class SplitTenderPaymentCalculator {
  const SplitTenderPaymentCalculator();

  double parseAmount(String value) {
    return parseDecimalOr(value);
  }

  SplitTenderPaymentSummary summary({
    required double total,
    required Iterable<SplitTenderInput> tenders,
  }) {
    final paid = paidTotal(tenders);
    final overage = paid - total;
    final hasCashTender = tenders.any(
      (tender) => tender.method == PaymentMethod.cash,
    );

    return SplitTenderPaymentSummary(
      paid: paid,
      remaining: (total - paid).clamp(0, double.infinity).toDouble(),
      changeDue: overage > 0 && hasCashTender ? overage : 0,
    );
  }

  double paidTotal(Iterable<SplitTenderInput> tenders) {
    return tenders.fold<double>(0, (sum, tender) => sum + tender.amount);
  }

  int balanceTenderIndex({required int editedIndex, required int tenderCount}) {
    if (editedIndex < tenderCount - 1) {
      return editedIndex + 1;
    }
    return editedIndex - 1;
  }

  double balanceTenderAmount({
    required double total,
    required List<SplitTenderInput> tenders,
    required int balanceIndex,
  }) {
    final totalWithoutBalance = tenders.indexed
        .where((entry) => entry.$1 != balanceIndex)
        .fold<double>(0, (sum, entry) => sum + entry.$2.amount);
    return (total - totalWithoutBalance).clamp(0, double.infinity).toDouble();
  }

  List<SaleCheckoutPaymentDraft>? appliedPayments({
    required double total,
    required Iterable<SplitTenderInput> tenders,
  }) {
    final parsed = tenders
        .where((tender) => tender.amount > 0)
        .toList(growable: false);
    final paid = paidTotal(parsed);
    if (parsed.isEmpty || paid < total) {
      return null;
    }

    var overage = paid - total;
    if (overage > 0) {
      final cashTotal = parsed
          .where((tender) => tender.method == PaymentMethod.cash)
          .fold<double>(0, (sum, tender) => sum + tender.amount);
      if (cashTotal < overage) {
        return null;
      }
    }

    final payments = <SaleCheckoutPaymentDraft>[];
    for (final tender in parsed.reversed) {
      var appliedAmount = tender.amount;
      if (overage > 0 && tender.method == PaymentMethod.cash) {
        final reduction = appliedAmount < overage ? appliedAmount : overage;
        appliedAmount -= reduction;
        overage -= reduction;
      }
      if (appliedAmount > 0) {
        payments.add(
          SaleCheckoutPaymentDraft(
            method: tender.method,
            amount: appliedAmount,
            cardReceiptUrl: tender.method == PaymentMethod.card
                ? tender.cardReceipt?.sourceUrl ?? ''
                : '',
          ),
        );
      }
    }
    return payments.reversed.toList(growable: false);
  }
}
