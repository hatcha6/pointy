import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';

PurchaseOrderLineDraft _line({double cost = 12, double? foreign}) =>
    PurchaseOrderLineDraft(
      variantId: 1,
      quantity: 10,
      unitCost: cost,
      unitCostInCurrency: foreign,
    );

PurchaseOrderDraft _draft({
  String currency = '',
  double? rate,
  List<PurchaseOrderLineDraft>? lines,
}) => PurchaseOrderDraft(
  supplierId: 7,
  lines: lines ?? [_line()],
  currencyCode: currency,
  exchangeRate: rate,
);

void main() {
  group('base-currency order', () {
    test('sends no currency key at all on create', () {
      final json = _draft().toJson();
      expect(json.containsKey('currency'), isFalse);
    });

    test('sends an explicit null on update, so clearing actually clears', () {
      final json = _draft().toJson(forUpdate: true);
      expect(json.containsKey('currency'), isTrue);
      expect(json['currency'], isNull);
    });

    test('sends the typed cost as the base unit cost', () {
      final line = (_draft().toJson()['lines'] as List).first as Map;
      expect(line['unit_cost'], '12.00');
      expect(line.containsKey('unit_cost_in_currency'), isFalse);
    });

    test('sends no exchange rate', () {
      expect(_draft().toJson().containsKey('exchange_rate'), isFalse);
    });
  });

  group('foreign-currency order', () {
    test('sends the currency', () {
      expect(_draft(currency: 'USD').toJson()['currency'], 'USD');
    });

    test('omits the rate so the server reads it as of the invoice date', () {
      // This omission is the feature: the invoice was priced on ITS date, not
      // on the day somebody typed it in.
      expect(
        _draft(currency: 'USD').toJson().containsKey('exchange_rate'),
        isFalse,
      );
    });

    test('sends a typed rate when the buyer overrode it', () {
      expect(
        _draft(currency: 'USD', rate: 7.2).toJson()['exchange_rate'],
        '7.2',
      );
    });
  });

  group('fromDraftLines routes the typed cost by currency', () {
    test('a base-currency draft keeps the cost as the base cost', () {
      final draft = PurchaseOrderDraft.fromDraftLines(const [], supplierId: 7);
      expect(draft.currencyCode, '');
      expect(draft.exchangeRate, isNull);
    });

    test('a foreign line sends the typed cost as the INVOICED amount', () {
      // The client never computes a stored base cost — that is the server's
      // one job here, so the two numbers cannot disagree.
      final line = _line(cost: 0, foreign: 12);
      final json = line.toJson();
      expect(json['unit_cost'], '0.00');
      expect(json['unit_cost_in_currency'], '12.00');
    });
  });
}
