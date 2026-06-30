import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/discount_rule.dart';

DiscountRuleDraft _draft({
  DiscountValueType valueType = DiscountValueType.percentage,
  DiscountScope scope = DiscountScope.line,
  String value = '10',
  String groupSize = '',
  String buyQuantity = '',
  String getQuantity = '',
  DiscountBuyGetReward? rewardType,
  List<DiscountTier> tiers = const [],
}) {
  return DiscountRuleDraft(
    name: 'Promo',
    description: '',
    channel: DiscountChannel.sales,
    applicationType: DiscountApplicationType.automatic,
    couponCode: '',
    scope: scope,
    valueType: valueType,
    value: value,
    groupSize: groupSize,
    buyQuantity: buyQuantity,
    getQuantity: getQuantity,
    rewardType: rewardType,
    tiers: tiers,
    maxDiscountAmount: '',
    roundingMode: DiscountRoundingMode.none,
    roundingIncrement: '',
    minOrderSubtotal: '0.00',
    minLineQuantity: '',
    priority: '100',
    exclusive: true,
    isActive: true,
    startsAt: null,
    endsAt: null,
    usageLimit: '',
    perCustomerUsageLimit: '',
    perSupplierUsageLimit: '',
    products: const [],
    variants: const [],
    productCategories: const [],
    customers: const [],
    customerRanks: const [],
    suppliers: const [],
  );
}

void main() {
  group('DiscountRuleDraft.toJson quantity promotions', () {
    test('multi-buy sends group size and group price', () {
      final json = _draft(
        valueType: DiscountValueType.multiBuy,
        value: '1.00',
        groupSize: '3',
      ).toJson();
      expect(json['value_type'], 'multi_buy');
      expect(json['group_size'], 3);
      expect(json['value'], '1.00');
      expect(json['tiers'], isEmpty);
      expect(json['reward_type'], '');
    });

    test('tiered omits value (server derives it) and sends tier rows', () {
      final json = _draft(
        valueType: DiscountValueType.tiered,
        value: '',
        tiers: const [
          DiscountTier(minQuantity: 6, unitPrice: 0.40),
          DiscountTier(minQuantity: 12, unitPrice: 0.35),
        ],
      ).toJson();
      expect(json['value_type'], 'tiered');
      expect(json['value'], isNull);
      expect(json['tiers'], [
        {'min_quantity': 6, 'unit_price': '0.4000'},
        {'min_quantity': 12, 'unit_price': '0.3500'},
      ]);
    });

    test('buy-x-get-y sends buy/get quantities and reward type', () {
      final json = _draft(
        valueType: DiscountValueType.buyXGetY,
        value: '100',
        buyQuantity: '2',
        getQuantity: '1',
        rewardType: DiscountBuyGetReward.free,
      ).toJson();
      expect(json['value_type'], 'buy_x_get_y');
      expect(json['buy_quantity'], 2);
      expect(json['get_quantity'], 1);
      expect(json['reward_type'], 'free');
      expect(json['value'], '100');
    });
  });

  group('DiscountRule.fromJson quantity promotions', () {
    test('parses tiers and tiered value', () {
      final rule = DiscountRule.fromJson({
        'id': 5,
        'name': 'Tiered',
        'value_type': 'tiered',
        'value': '0.35',
        'scope': 'line',
        'tiers': [
          {'min_quantity': 6, 'unit_price': '0.4000'},
          {'min_quantity': 12, 'unit_price': '0.3500'},
        ],
      });
      expect(rule.valueType, DiscountValueType.tiered);
      expect(rule.tiers.length, 2);
      expect(rule.tiers.first.minQuantity, 6);
      expect(rule.tiers.first.unitPrice, 0.40);
    });

    test('parses buy-x-get-y reward parameters', () {
      final rule = DiscountRule.fromJson({
        'id': 6,
        'name': 'BOGO',
        'value_type': 'buy_x_get_y',
        'value': '100',
        'buy_quantity': 2,
        'get_quantity': 1,
        'reward_type': 'free',
      });
      expect(rule.valueType, DiscountValueType.buyXGetY);
      expect(rule.buyQuantity, 2);
      expect(rule.getQuantity, 1);
      expect(rule.rewardType, DiscountBuyGetReward.free);
    });

    test('non-promotion rules default the new fields to null/empty', () {
      final rule = DiscountRule.fromJson({
        'id': 1,
        'name': 'Percent',
        'value_type': 'percentage',
        'value': '10',
      });
      expect(rule.groupSize, isNull);
      expect(rule.buyQuantity, isNull);
      expect(rule.rewardType, isNull);
      expect(rule.tiers, isEmpty);
    });
  });
}
