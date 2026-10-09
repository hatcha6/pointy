import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';
import 'package:pointy_frontend/src/features/pos/view_models/voucher_menu_search.dart';

import '../../../support/voucher_menu_testing.dart';
import '../../../support/voucher_search_testing.dart';

List<String> keys(VoucherMenuSearchResult result) => [
  for (final brand in result.brands) brand.key,
];

void main() {
  group('normalizeVoucherSearchText', () {
    test('folds alef, ya, ta marbuta, tashkeel and tatweel', () {
      expect(normalizeVoucherSearchText('  أبل  '), 'ابل');
      expect(normalizeVoucherSearchText('إيتونز'), 'ايتونز');
      expect(normalizeVoucherSearchText('كهرباء'), 'كهرباء');
      expect(
        normalizeVoucherSearchText('مياة'),
        normalizeVoucherSearchText('مياه'),
      );
      expect(normalizeVoucherSearchText('مكتبة'), 'مكتبه');
      expect(normalizeVoucherSearchText('على'), 'علي');
      expect(normalizeVoucherSearchText('بلايسـتيشن'), 'بلايستيشن');
      expect(normalizeVoucherSearchText('فِيزَا'), 'فيزا');
      expect(normalizeVoucherSearchText('Apple  STORE'), 'apple store');
      expect(normalizeVoucherSearchText('١٢٣'), '123');
    });
  });

  group('searchVoucherMenu', () {
    final menu = searchMenu();

    test('a blank query is the whole menu', () {
      expect(searchVoucherMenu(menu, '  ').brands, hasLength(4));
    });

    test('finds a brand by Arabic name, key and word prefix', () {
      expect(keys(searchVoucherMenu(menu, 'آيتونز')), ['itunes']);
      expect(keys(searchVoucherMenu(menu, 'ايتونز')), ['itunes']);
      expect(keys(searchVoucherMenu(menu, 'ITUN')), ['itunes']);
      expect(keys(searchVoucherMenu(menu, 'بلاي')), ['playstation']);
      expect(keys(searchVoucherMenu(menu, 'ليبيان')), ['libyana']);
    });

    test('finds a brand by its aliases', () {
      expect(keys(searchVoucherMenu(menu, 'visa')), ['mastercard']);
      expect(keys(searchVoucherMenu(menu, 'فيزا')), ['mastercard']);
    });

    test(
      'the synonym table finds the brand when the server sent no aliases',
      () {
        final bare = searchMenu(aliases: false);
        expect(keys(searchVoucherMenu(bare, 'Visa')), ['mastercard']);
        expect(keys(searchVoucherMenu(bare, 'apple')), ['itunes']);
        expect(keys(searchVoucherMenu(bare, 'app store')), ['itunes']);
        expect(keys(searchVoucherMenu(bare, 'أبل')), ['itunes']);
        expect(keys(searchVoucherMenu(bare, 'psn')), ['playstation']);
      },
    );

    test('top-up words find the airtime launcher', () {
      for (final word in ['top up', 'recharge', 'airtime', 'شحن رصيد', 'شحن']) {
        final result = searchVoucherMenu(menu, word);
        expect(result.airtime, isTrue, reason: word);
      }
    });

    test('bill words find the matching bill card only', () {
      expect(searchVoucherMenu(menu, 'electricity').bills, [
        BillType.electricity,
      ]);
      expect(searchVoucherMenu(menu, 'كهرباء').bills, [BillType.electricity]);
      expect(searchVoucherMenu(menu, 'مياه').bills, [BillType.water]);
      expect(searchVoucherMenu(menu, 'tv').bills, [BillType.tv]);
      expect(searchVoucherMenu(menu, 'internet').bills, [BillType.internet]);
      expect(searchVoucherMenu(menu, 'electricity').brands, isEmpty);
    });

    test('nothing matching is empty', () {
      expect(searchVoucherMenu(menu, 'قهوة').isEmpty, isTrue);
    });
  });

  test('a brand parses its aliases tolerantly', () {
    final json = voucherMenuJson(withCost: false);
    final brands = json['brands']! as List;
    (brands[0]! as Map)['aliases'] = ['Apple', '', 7, null];
    (brands[1]! as Map)['aliases'] = 'not a list';
    final menu = VoucherMenu.fromJson(json);
    expect(menu.brands[0].aliases, ['Apple', '7']);
    expect(menu.brands[1].aliases, isEmpty);
    expect(menu.brands[2].aliases, isEmpty);
  });
}
