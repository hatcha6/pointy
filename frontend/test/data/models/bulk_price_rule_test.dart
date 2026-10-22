import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_preview.dart';
import 'package:pointy_frontend/src/data/models/bulk_price_rule.dart';

void main() {
  group('spec JSON matches the server contract', () {
    test('filter tree, chained steps and safeguards', () {
      const spec = BulkPriceSpec(
        filter: BulkPriceGroup(
          key: 'root',
          children: [
            BulkPriceCondition(
              key: 'a',
              field: BulkPriceField.category,
              operator: BulkPriceOperator.inList,
              refs: [BulkPriceRef(id: 4, label: 'مشروبات')],
            ),
            BulkPriceGroup(
              key: 'g',
              match: BulkPriceMatch.any,
              children: [
                BulkPriceCondition(
                  key: 'b',
                  field: BulkPriceField.price,
                  operator: BulkPriceOperator.between,
                  value: '١٫٥',
                  valueTo: '10',
                ),
                BulkPriceCondition(
                  key: 'c',
                  field: BulkPriceField.cost,
                  operator: BulkPriceOperator.isEmpty,
                ),
              ],
            ),
          ],
        ),
        steps: [
          BulkPriceStep(
            key: 's1',
            action: BulkPriceAction.increasePercent,
            value: '10',
            stop: true,
            when: BulkPriceGroup(
              key: 'w',
              children: [
                BulkPriceCondition(
                  key: 'd',
                  field: BulkPriceField.name,
                  operator: BulkPriceOperator.contains,
                  value: '  كولا ',
                ),
              ],
            ),
          ),
          BulkPriceStep(
            key: 's2',
            action: BulkPriceAction.round,
            value: '0.25',
            direction: BulkPriceDirection.up,
          ),
        ],
        neverBelowCost: true,
        packMode: BulkPricePackMode.keep,
      );

      expect(spec.toJson(), {
        'filter': {
          'match': 'all',
          'conditions': [
            {
              'field': 'category',
              'op': 'in',
              'value': [4],
            },
            {
              'match': 'any',
              'conditions': [
                {
                  'field': 'price',
                  'op': 'between',
                  'value': '1.5',
                  'value_to': '10',
                },
                {'field': 'cost', 'op': 'is_empty'},
              ],
            },
          ],
        },
        'steps': [
          {
            'action': 'increase_percent',
            'value': '10',
            'when': {
              'match': 'all',
              'conditions': [
                {'field': 'name', 'op': 'contains', 'value': 'كولا'},
              ],
            },
            'stop': true,
          },
          {
            'action': 'round',
            'value': '0.25',
            'direction': 'up',
            'stop': false,
          },
        ],
        'finish': {'never_below_cost': true, 'packs': 'keep'},
      });
      expect(spec.isComplete, isTrue);
    });
  });

  group('validation', () {
    BulkPriceCondition price(
      String value, {
      String to = '',
      BulkPriceOperator? op,
    }) => BulkPriceCondition(
      key: 'p',
      field: BulkPriceField.price,
      operator: op ?? BulkPriceOperator.lt,
      value: value,
      valueTo: to,
    );

    test('numbers', () {
      expect(price('').issues.value, BulkPriceIssue.required);
      expect(price('abc').issues.value, BulkPriceIssue.notANumber);
      expect(price('-1').issues.value, BulkPriceIssue.negative);
      expect(price('1.234').issues.value, BulkPriceIssue.tooManyDecimals);
      expect(price('٣٫٥').issues.value, isNull);
      expect(
        price('9', to: '3', op: BulkPriceOperator.between).issues.valueTo,
        BulkPriceIssue.boundsReversed,
      );
    });

    test('stock may be negative and carry three places', () {
      const stock = BulkPriceCondition(
        key: 's',
        field: BulkPriceField.stock,
        operator: BulkPriceOperator.lt,
        value: '-0.125',
      );
      expect(stock.isValid, isTrue);
    });

    test('step bounds', () {
      expect(
        const BulkPriceStep(
          key: 'x',
          action: BulkPriceAction.decreasePercent,
          value: '120',
        ).valueIssue,
        BulkPriceIssue.percentOver100,
      );
      expect(
        const BulkPriceStep(
          key: 'x',
          action: BulkPriceAction.round,
          value: '0',
        ).valueIssue,
        BulkPriceIssue.zeroIncrement,
      );
    });

    test('changing field kind drops a value that no longer means anything', () {
      const typed = BulkPriceCondition(
        key: 'k',
        field: BulkPriceField.name,
        operator: BulkPriceOperator.contains,
        value: 'cola',
      );
      final moved = typed.copyWith(field: BulkPriceField.price);
      expect(moved.value, '');
      expect(BulkPriceField.price.supports(moved.operator), isTrue);
      // Same kind keeps it.
      expect(typed.copyWith(field: BulkPriceField.sku).value, 'cola');
    });

    test('price never offers "is empty"', () {
      expect(
        BulkPriceField.price.supportedOperators,
        isNot(contains(BulkPriceOperator.isEmpty)),
      );
      expect(
        BulkPriceField.cost.supportedOperators,
        contains(BulkPriceOperator.isEmpty),
      );
    });
  });

  test('preview JSON parses', () {
    final preview = BulkPricePreview.fromJson({
      'fingerprint': 'abc',
      'cost_visible': true,
      'view': 'warnings',
      'count': 1,
      'summary': {
        'matched': 5,
        'changed': 3,
        'unchanged': 2,
        'increased': 2,
        'decreased': 1,
        'products_changed': 3,
        'packs_changed': 1,
        'average_change_percent': '4.5',
        'warnings': 1,
        'flags': {'below_cost': 1, 'no_cost': 0},
        'step_counts': [3, 1],
      },
      'rows': [
        {
          'variant_id': 9,
          'product_id': 4,
          'product_name': 'شاي',
          'variant_name': '',
          'sku': 'T',
          'old_price': '10.00',
          'new_price': '9.00',
          'delta': '-1.00',
          'delta_percent': '-10.0',
          'applied_steps': [0, 1],
          'flags': ['below_cost', 'unknown_flag'],
          'packs': [
            {
              'unit_id': 1,
              'label': 'كرتونة',
              'old_price': '100.00',
              'new_price': '90.00',
            },
          ],
          'cost': '9.50',
          'old_markup': '5.3',
          'new_markup': '-5.3',
        },
      ],
    });
    expect(preview.view, BulkPricePreviewView.warnings);
    expect(preview.summary.stepCounts, [3, 1]);
    expect(preview.summary.averageChangePercent, 4.5);
    final row = preview.rows.single;
    expect(row.flags, {BulkPriceFlag.belowCost});
    expect(row.increased, isFalse);
    expect(row.packs.single.newPrice, 90);
    expect(row.newMarkup, -5.3);
  });
}
