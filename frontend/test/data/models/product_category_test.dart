import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';

void main() {
  group('ProductCategory.isSystem', () {
    test('reads the category a provider shelf keeps', () {
      final category = ProductCategory.fromJson(const {
        'id': 7,
        'name': 'كروت قريب',
        'is_quick_access': true,
        'is_system': true,
      });

      expect(category.isSystem, isTrue);
      // An optimistic pin toggle must not forget what the row is.
      expect(category.copyWith(isQuickAccess: false).isSystem, isTrue);
    });

    test('a shop category, or a server that predates the flag, is not one', () {
      final shop = ProductCategory.fromJson(const {
        'id': 8,
        'name': 'مشروبات',
        'is_system': false,
      });
      final older = ProductCategory.fromJson(const {'id': 9, 'name': 'حلويات'});

      expect(shop.isSystem, isFalse);
      expect(older.isSystem, isFalse);
    });
  });
}
