import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/consignment.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/features/inventory/pdf/consignment_document_content.dart';

/// What the two consignment vouchers put on paper.
///
/// Asserted at the content layer rather than on rendered bytes, because an
/// embedded Arabic font writes glyph indices and a byte search for "الأمانة"
/// would find nothing whatever the page said. The renderer has no second source
/// for any of this, which is the point: Phase B's identifiers reached a
/// serializer and never reached a receipt, and the test that was supposed to
/// catch that handed its key straight to the encoder.
void main() {
  ConsignmentAgreement agreement({
    String clause = 'الأمانة على مسؤولية صاحبها.',
    String payoutMode = ConsignmentPayoutMode.fixed,
    double? payoutRate = 10000,
    double? commissionPct,
    double? reservePrice,
  }) {
    return ConsignmentAgreement(
      id: 1,
      number: 'CA2026091900007',
      consignorId: 2,
      consignorName: 'سالم',
      consignorPhone: '0912345678',
      payoutMode: payoutMode,
      payoutRate: payoutRate,
      commissionPct: commissionPct,
      reservePrice: reservePrice,
      liabilityClause: clause,
      docStatus: 'submitted',
      units: const [
        StockUnit(
          id: 7,
          variantId: 3,
          code: 'ROLEX-116610-A',
          variantName: 'ساعة رولكس',
          declaredValue: 12000,
          attributes: {'حالة الهيكل': 'ممتازة'},
          notes: 'مع العلبة والأوراق',
        ),
      ],
    );
  }

  group('سند استلام أمانة', () {
    test('prints the clause that was signed, not the one in force today', () {
      final content = buildConsignmentVoucherContent(
        agreement: agreement(clause: 'النص الأول'),
        units: agreement().units,
      );

      expect(content.clause, 'النص الأول');
      expect(content.allText, contains('النص الأول'));
    });

    test(
      'a page with no clause on it prints none rather than a blank panel',
      () {
        final content = buildConsignmentVoucherContent(
          agreement: agreement(clause: ''),
        );

        expect(content.clause, isEmpty);
      },
    );

    test('names the article, its identifier and its agreed worth', () {
      final source = agreement();
      final content = buildConsignmentVoucherContent(
        agreement: source,
        units: source.units,
      );

      expect(content.tableRows, hasLength(1));
      final row = content.tableRows.single;
      expect(row, contains('ساعة رولكس'));
      expect(row, contains('ROLEX-116610-A'));
      expect(row.last, contains('12'));
    });

    test('carries the condition agreed at the counter', () {
      final source = agreement();

      final description = describeUnitCondition(source.units.single);

      expect(description, contains('حالة الهيكل: ممتازة'));
      expect(description, contains('مع العلبة والأوراق'));
    });

    test('states a fixed payout as an amount', () {
      final content = buildConsignmentVoucherContent(agreement: agreement());

      expect(
        content.termFields.map((field) => field.label),
        contains('المبلغ المستحق لصاحب الأمانة'),
      );
    });

    test('states a commission as a percentage, trimmed', () {
      final content = buildConsignmentVoucherContent(
        agreement: agreement(
          payoutMode: ConsignmentPayoutMode.commission,
          payoutRate: null,
          commissionPct: 15,
        ),
      );

      final terms = {
        for (final field in content.termFields) field.label: field.value,
      };
      expect(terms['عمولة المحل'], contains('15%'));
      expect(terms.containsKey('المبلغ المستحق لصاحب الأمانة'), isFalse);
    });

    test('both the owner and the shop are named on it', () {
      final content = buildConsignmentVoucherContent(agreement: agreement());

      expect(content.allText, contains('سالم'));
      expect(content.allText, contains('CA2026091900007'));
    });
  });

  group('سند صرف أمانة', () {
    ConsignorPayout payout() => ConsignorPayout(
      id: 4,
      number: 'CP2026091900003',
      consignorName: 'سالم',
      consignorPhone: '0912345678',
      amount: 10000,
      method: 'cash',
      paidAt: DateTime(2026, 9, 19, 11, 30),
      lines: [
        ConsignorPayoutLine(
          unitId: 7,
          code: 'ROLEX-116610-A',
          productName: 'ساعة رولكس',
          soldAt: DateTime(2026, 9, 17),
          soldPrice: 12000,
          payoutDue: 10000,
        ),
      ],
    );

    test('says which article the money was for', () {
      final content = buildConsignorPayoutContent(payout: payout());

      expect(content.tableRows, hasLength(1));
      expect(content.tableRows.single, contains('ROLEX-116610-A'));
      expect(content.tableRows.single, contains('ساعة رولكس'));
    });

    test('carries the total handed over', () {
      final content = buildConsignorPayoutContent(payout: payout());

      expect(content.total, isNotNull);
      expect(content.total!.label, 'إجمالي المبلغ المستلم');
    });

    test('says whether it left the drawer or the bank', () {
      final cash = buildConsignorPayoutContent(payout: payout());
      expect(cash.allText, contains('نقدًا من الصندوق'));
    });

    test('carries no liability clause — it is a receipt, not a contract', () {
      final content = buildConsignorPayoutContent(payout: payout());

      expect(content.clause, isEmpty);
    });
  });
}
