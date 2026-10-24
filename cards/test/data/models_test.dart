import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/core/money.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';
import 'package:pointy_cards/src/data/models/order.dart';

void main() {
  test('the catalog reads the relay view and tolerates odd rows', () {
    final catalog = CardCatalog.fromJson({
      'version': 'v1',
      'channel': 'ios',
      'categories': [
        {'key': 'telecom', 'name': 'اتصالات', 'rank': 1},
      ],
      'countries': [],
      'brands': [
        {
          'key': 'libyana',
          'name': 'ليبيانا',
          'category': 'telecom',
          'aliases': ['libyana', 7],
          'items': [
            {
              'key': 'libyana-10',
              'price': '10.00',
              'regular_price': '12.00',
              'promo': {'badge': 'عرض'},
              'available': true,
            },
            'not a map',
          ],
        },
      ],
    });
    final brand = catalog.brand('libyana')!;
    expect(brand.aliases, ['libyana']);
    expect(brand.items.single.price, Money.parse('10'));
    expect(brand.items.single.onPromo, isTrue);
    expect(brand.anyAvailable, isTrue);
  });

  test('an order reads its money, status and codes', () {
    final order = CardOrder.fromJson({
      'id': 'o1',
      'status': 'delivered',
      'total': '20.000',
      'fee': '0.410',
      'amount_to_pay': '20.410',
      'codes': [
        {'code': '1234', 'serial': 'S1'},
      ],
    });
    expect(order.status, OrderStatus.delivered);
    expect(order.amountToPay.toFixed2(), '20.41');
    expect(order.codes.single.code, '1234');
    expect(OrderStatus.parse('mystery'), OrderStatus.failed);
    expect(OrderStatus.awaitingPayment.isOpen, isTrue);
  });

  test('the checkout fee matches the relay figure', () {
    const options = CheckoutOptions(
      methods: [],
      feePercent: 2,
      maxQuantity: 10,
      testMode: false,
    );
    // The same cases as the relay's TestCustomerPaymentFeeCoversTheGatewayShare.
    expect(options.feeOn(Money.parse('10')).toWire(), '0.210');
    expect(options.feeOn(Money.parse('20')).toWire(), '0.410');
    expect(options.feeOn(Money.parse('49.99')).toWire(), '1.030');
    expect(options.feeOn(Money.parse('98')).toWire(), '2.000');
    expect(options.feeOn(Money.zero), Money.zero);
    const free = CheckoutOptions(
      methods: [],
      feePercent: 0,
      maxQuantity: 10,
      testMode: false,
    );
    expect(free.feeOn(Money.parse('10')), Money.zero);
  });
}
