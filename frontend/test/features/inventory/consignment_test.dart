import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/consignment.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';

/// The till's and the counter's half of الأمانات.
///
/// Every one of these is named after what goes wrong without it. The two that
/// matter most are the price floor — a fixed-payout watch sold below what the
/// shop owes its owner loses the shop's own money, not its commission — and the
/// credit flag, which is the difference between a cashier who knows the drawer
/// is about to be short and one who finds out afterwards.
void main() {
  group('the fixed-payout floor', () {
    test('is the higher of the reserve and the payout', () {
      const agreement = ConsignmentAgreement(
        id: 1,
        consignorId: 2,
        payoutMode: ConsignmentPayoutMode.fixed,
        payoutRate: 10000,
        reservePrice: 11000,
      );

      expect(agreement.hardFloor, 11000);
    });

    test('falls back to the payout when no reserve was agreed', () {
      const agreement = ConsignmentAgreement(
        id: 1,
        consignorId: 2,
        payoutMode: ConsignmentPayoutMode.fixed,
        payoutRate: 10000,
      );

      expect(agreement.hardFloor, 10000);
    });

    test('does not exist under commission, where the payout scales', () {
      const agreement = ConsignmentAgreement(
        id: 1,
        consignorId: 2,
        payoutMode: ConsignmentPayoutMode.commission,
        commissionPct: 15,
        reservePrice: 11000,
      );

      // The reserve there protects the consignor, not the shop, so it stays
      // advisory rather than becoming a wall.
      expect(agreement.hardFloor, isNull);
    });
  });

  group('a payable row', () {
    ConsignmentPayable payable({
      bool onCredit = false,
      int days = 3,
      double balance = 0,
    }) {
      return ConsignmentPayable.fromJson({
        'id': 7,
        'code': 'ROLEX-A',
        'product_name': 'ساعة رولكس',
        'consignor': 4,
        'consignor_name': 'سالم',
        'payout_due': '10000.00',
        'sold_price': '12000.00',
        'invoice_number': 'R2026-1',
        'invoice_balance_due': balance.toStringAsFixed(2),
        'sold_on_credit': onCredit,
        'days_waiting': days,
      });
    }

    test('carries what the shop still owes and what it has not collected', () {
      final row = payable(onCredit: true, balance: 12000);

      expect(row.payoutDue, 10000);
      // The second number: the shop owes cash on a sale it has not been paid
      // for, and the person about to open the drawer is told so in the row.
      expect(row.soldOnCredit, isTrue);
      expect(row.invoiceBalanceDue, 12000);
    });

    test('flags the owner who never came back', () {
      expect(payable(days: 3).isOverdue, isFalse);
      expect(payable(days: 45).isOverdue, isTrue);
    });
  });

  group('a consigned unit', () {
    StockUnit unit({String status = StockUnitStatus.sold, bool paid = false}) {
      return StockUnit.fromJson({
        'id': 9,
        'variant': 1,
        'code': 'ROLEX-A',
        'status': status,
        'is_consignment': true,
        'consignor': 4,
        'consignor_name': 'سالم',
        'incoming_rate': '10000.000000',
        'declared_value': '12000.00',
        if (paid) 'consignor_paid_at': '2026-09-18T10:00:00Z',
      });
    }

    test('awaits payout once sold and until collected', () {
      expect(unit().awaitsPayout, isTrue);
      expect(unit(paid: true).awaitsPayout, isFalse);
      expect(unit(status: StockUnitStatus.inStock).awaitsPayout, isFalse);
    });
  });

  group('the returns desk', () {
    SaleLineIdentifier identifier({bool consigned = true, bool paid = true}) {
      return SaleLineIdentifier.fromJson({
        'kind': 'unit',
        'code': 'ROLEX-A',
        'is_consignment': consigned,
        'consignor_paid': paid,
      });
    }

    test('asks only when the money has already gone out', () {
      expect(identifier().needsConsignmentDecision, isTrue);
      // Nothing has been paid yet, so the payable simply closes with the sale
      // that created it — there is nothing to decide.
      expect(identifier(paid: false).needsConsignmentDecision, isFalse);
      expect(identifier(consigned: false).needsConsignmentDecision, isFalse);
    });

    test(
      'sends the answer with the return, and nothing when there is none',
      () {
        final asked = SaleReturnDraft(
          lines: const [SaleReturnLineDraft(lineId: 1, quantity: 1)],
          reason: 'عاد',
          consignmentAction: ConsignmentReturnAction.buyIn,
        ).toJson();
        final plain = SaleReturnDraft(
          lines: const [SaleReturnLineDraft(lineId: 1, quantity: 1)],
          reason: 'عاد',
        ).toJson();

        expect(asked['consignment_action'], 'buy_in');
        // Absent rather than null: the backend's own default stands, and a null
        // would be a client opinion about a decision nobody made.
        expect(plain.containsKey('consignment_action'), isFalse);
      },
    );
  });

  group('the position', () {
    test('reads the four figures and the custody block', () {
      final position = ConsignmentPosition.fromJson({
        'stock_value': '0.00',
        'consignor_payable': '10000.00',
        'consignor_claims_open': '0.00',
        'shop_commission': '2000.00',
        'custody': {'unit_count': 7, 'declared_value': '84000.00'},
      });

      // Zero, and carried anyway: a page that did not say the goods are worth
      // nothing to this shop would be read as having forgotten to.
      expect(position.stockValue, 0);
      expect(position.payable, 10000);
      expect(position.shopCommission, 2000);
      expect(position.custodyUnitCount, 7);
      expect(position.custodyDeclaredValue, 84000);
    });
  });

  group('an intake item', () {
    test('sends only the overrides that were actually typed', () {
      const item = ConsignmentIntakeItem(
        variantId: 3,
        code: 'ROLEX-A',
        declaredValue: 12000,
      );

      final json = item.toJson();
      expect(json['variant'], 3);
      expect(json['declared_value'], 12000);
      // Null inherits the agreement's terms, so an untouched field is absent
      // rather than a null that would read as "no reserve".
      expect(json.containsKey('consignor_reserve_price'), isFalse);
      expect(json.containsKey('consignor_payout_rate'), isFalse);
    });
  });
}
