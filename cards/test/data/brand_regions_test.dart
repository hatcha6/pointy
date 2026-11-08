import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/data/models/catalog.dart';

Map<String, dynamic> _item(String key, String country, String price) => {
  'key': key,
  'country': country,
  'label': key,
  'price': price,
  'regular_price': price,
  'available': true,
  'rank': 0,
};

void main() {
  test('a brand sold per region starts at the price of the first region', () {
    final brand = CardBrand.fromJson({
      'key': 'tu-free-fire',
      'name': 'فري فاير',
      'category': 'game_topup',
      'items': [
        _item('mena-100', 'MENA', '9.50'),
        _item('mena-50', 'MENA', '12.00'),
        _item('vn-10', 'VN', '0.75'),
      ],
    });
    expect(brand.fromPrice.toString(), brand.items.first.price.toString());
  });

  test('a brand with no regions starts at its cheapest card', () {
    final brand = CardBrand.fromJson({
      'key': 'libyana',
      'name': 'ليبيانا',
      'category': 'telecom',
      'items': [_item('a', '', '10.00'), _item('b', '', '5.00')],
    });
    expect(brand.fromPrice.toString(), brand.items.last.price.toString());
  });
}
