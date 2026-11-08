import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/shared/category_icon.dart';

void main() {
  test('every category on the shelf has an icon of its own', () {
    const keys = [
      null,
      'telecom',
      'intl_topup',
      'internet',
      'tv',
      'gaming',
      'game_topup',
      'apps_topup',
      'game_keys',
      'steam_gifts',
      'gift_cards',
      'services',
    ];
    final icons = keys.map(categoryIcon).toList();
    expect(icons.toSet(), hasLength(keys.length));
    expect(icons, isNot(contains(categoryIcon('a category nobody knows'))));
  });
}
