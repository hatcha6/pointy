import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';

import '../../support/voucher_menu_testing.dart';

/// The till's «كروت دفتر» menu as the shop's backend serves it. The company
/// owns the categories, the order and the promotions; the till must show
/// exactly that, and must never offer a card it cannot sell.
void main() {
  group('reading the menu', () {
    test('keeps the company\'s categories, countries and brands in order', () {
      final menu = VoucherMenu.fromJson(voucherMenuJson());

      expect(menu.available, isTrue);
      expect(menu.provider, 'pointy');
      expect(menu.balance, 345.5);
      expect(menu.balanceAt, isNotNull);
      expect(menu.categories.map((category) => category.key), [
        'gift_cards',
        'games',
        'telecom',
      ]);
      expect(menu.brands.map((brand) => brand.key), [
        'itunes',
        'playstation',
        'libyana',
      ]);
      expect(menu.hasBrands, isTrue);
    });

    test('decodes each flag once, from bare base64 or a data URL', () {
      final menu = VoucherMenu.fromJson(voucherMenuJson());

      expect(menu.country('US').flag, isNotNull);
      expect(menu.country('US').flag, orderedEquals(voucherFlagBytes));
      expect(menu.country('GB').flag, orderedEquals(voucherFlagBytes));
      expect(menu.country('US').label, 'الولايات المتحدة');
      // One instance for the life of the menu: what the image cache keys on.
      expect(
        identical(menu.country('US').flag, menu.countries.first.flag),
        isTrue,
      );
    });

    test('a country without a flag, or with a broken one, keeps its code', () {
      final menu = VoucherMenu.fromJson(voucherMenuJson());

      expect(menu.country('LY').flag, isNull, reason: 'sent as null');
      expect(
        VoucherCountry.fromJson(const {'code': 'tr', 'flag': '%%%not-base64'}),
        isA<VoucherCountry>()
            .having((country) => country.code, 'code', 'TR')
            .having((country) => country.flag, 'flag', isNull)
            .having((country) => country.label, 'label', 'TR'),
      );
      // A code nobody listed still answers, by its code.
      expect(menu.country('ZZ').label, 'ZZ');
    });

    test('reads a card\'s prices, promotion, availability and cost', () {
      final itunes = VoucherMenu.fromJson(voucherMenuJson()).brands.first;
      final promo = itunes.items[1];

      expect(promo.label, '25 دولار');
      expect(promo.name, 'الولايات المتحدة · 25 دولار');
      expect(promo.country, 'US');
      expect(promo.faceValue, '25');
      expect(promo.faceCurrency, 'USD');
      expect(promo.price, 145);
      expect(promo.regularPrice, 150);
      expect(promo.isDiscounted, isTrue);
      expect(promo.badge, 'عرض');
      expect(promo.promoEndsAt, isNotNull);
      expect(promo.cost, 128);
      expect(promo.profit, 17);
      expect(promo.available, isTrue);

      final plain = itunes.items.first;
      expect(plain.isDiscounted, isFalse, reason: 'regular equals price');
      expect(plain.isOnPromo, isFalse);
    });

    test('a cashier is sent no cost, and gets no profit: absent, not zero', () {
      final itunes = VoucherMenu.fromJson(
        voucherMenuJson(withCost: false),
      ).brands.first;

      expect(itunes.items.every((item) => item.cost == null), isTrue);
      expect(itunes.items.every((item) => item.profit == null), isTrue);
    });

    test('a brand\'s card points at its own system product\'s variant', () {
      final itunes = VoucherMenu.fromJson(voucherMenuJson()).brands.first;
      final variant = itunes.variantFor(itunes.items.first)!;

      expect(variant.id, itunes.items.first.variantId);
      expect(variant.productDetail?.isVoucher, isTrue);
      // The line names every detail the cashier picked.
      expect(variant.displayLabel, 'آيتونز - الولايات المتحدة · 10 دولار');
      expect(itunes.logoUrl, contains('/attachments/'));
    });

    test('orders its countries the way its cards come', () {
      final itunes = VoucherMenu.fromJson(voucherMenuJson()).brands.first;

      expect(itunes.countryCodes, ['US', 'GB']);
      expect(itunes.itemsFor('GB').map((item) => item.label), [
        '10 جنيه',
        '25 جنيه',
      ]);
      expect(itunes.itemsFor(null), hasLength(itunes.items.length));
    });

    test('prices a brand from what can be sold now', () {
      final itunes = VoucherMenu.fromJson(voucherMenuJson()).brands.first;
      final range = itunes.priceRange!;

      // The 100 دولار card is sold out; its 575.00 is not the top price.
      expect(range.min, 60);
      expect(range.max, 290);
      expect(itunes.onPromo, isTrue);
      expect(itunes.promoBadge, 'عرض');
      expect(itunes.isAvailable, isTrue);
    });

    test('filters brands by category and lists only categories in use', () {
      final menu = VoucherMenu.fromJson(
        voucherMenuJson(
          extraCategories: const [
            {'key': 'streaming', 'name': 'الترفيه'},
          ],
        ),
      );

      expect(menu.usedCategories.map((category) => category.key), [
        'gift_cards',
        'games',
        'telecom',
      ]);
      expect(menu.brandsIn('games').map((brand) => brand.key), ['playstation']);
      expect(menu.brandsIn(null), hasLength(3));
      expect(menu.brandForProduct(9004)?.key, 'libyana');
      expect(menu.brandForProduct(1), isNull);
    });
  });

  group('what a broken payload costs', () {
    test('a sold-out card, or one whose variant is gone, cannot be sold', () {
      final itunes = VoucherMenu.fromJson(voucherMenuJson()).brands.first;
      final soldOut = itunes.items[3];

      expect(soldOut.available, isFalse);
      expect(itunes.canSell(soldOut), isFalse);

      final orphan = VoucherItem.fromJson(const {
        'variant_id': 424242,
        'key': 'itunes-us-gone',
        'price': '10.00',
        'available': true,
      });
      expect(itunes.variantFor(orphan), isNull);
      expect(itunes.canSell(orphan), isFalse);
    });

    test('a card with no "available" is not offered on a guess', () {
      final item = VoucherItem.fromJson(const {
        'variant_id': 1,
        'key': 'x',
        'price': 'not a number',
      });

      expect(item.available, isFalse);
      expect(item.price, 0);
      expect(item.regularPrice, isNull);
      expect(item.cost, isNull);
    });

    test('one malformed brand loses itself, not the menu', () {
      final json = voucherMenuJson();
      final brands = [...(json['brands']! as List<Object?>)];
      brands
        ..add('not a brand')
        ..add({
          'key': 'broken',
          'name': 'منتج تالف',
          'category': 'games',
          // A product the till cannot read: the brand stays, unsellable.
          'product': {'id': 'x', 'variants': 'nope'},
          'items': [
            {
              'variant_id': 7,
              'key': 'broken-1',
              'price': '5',
              'available': true,
            },
          ],
        })
        // A brand with no cards has nothing to show.
        ..add({'key': 'empty', 'name': 'فارغ', 'items': <Object?>[]});
      final menu = VoucherMenu.fromJson({...json, 'brands': brands});

      expect(menu.brands.map((brand) => brand.key), [
        'itunes',
        'playstation',
        'libyana',
        'broken',
      ]);
      final broken = menu.brands.last;
      expect(broken.isAvailable, isFalse);
      expect(broken.variantFor(broken.items.single), isNull);
    });

    test('a server with nothing to say is an empty, unavailable menu', () {
      final menu = VoucherMenu.fromJson(const {
        'available': false,
        'error_code': 'not_configured',
      });

      expect(menu.available, isFalse);
      expect(menu.errorCode, 'not_configured');
      expect(menu.brands, isEmpty);
      expect(menu.hasBrands, isFalse);
      expect(VoucherMenu.empty.hasBrands, isFalse);
    });

    test('a flag sent as a data URL decodes like a bare one', () {
      expect(
        decodeVoucherImage(
          'data:image/png;base64,${base64Encode(voucherFlagBytes)}',
        ),
        orderedEquals(voucherFlagBytes),
      );
      expect(decodeVoucherImage(''), isNull);
      expect(decodeVoucherImage(null), isNull);
      expect(decodeVoucherImage(42), isNull);
    });
  });

  group('the «كروت دفتر» chip', () {
    test('is told apart by its system key, and keeps it', () {
      final chip = ProductCategory.fromJson(const {
        'id': 99,
        'name': 'كروت دفتر',
        'is_quick_access': true,
        'is_system': true,
        'system_key': 'vouchers:pointy',
      });

      expect(chip.systemKey, ProductCategorySystemKey.pointyVouchers);
      expect(chip.isPointyVouchers, isTrue);
      expect(chip.copyWith(isQuickAccess: false).isPointyVouchers, isTrue);
    });

    test('a shop category, or a server before the key, is not it', () {
      expect(
        ProductCategory.fromJson(const {'id': 1, 'name': 'مشروبات'}).systemKey,
        '',
      );
      expect(
        ProductCategory.fromJson(const {
          'id': 7,
          'name': 'كروت قريب',
          'is_system': true,
          'system_key': 'vouchers:qareeb',
        }).isPointyVouchers,
        isFalse,
      );
    });
  });
}
