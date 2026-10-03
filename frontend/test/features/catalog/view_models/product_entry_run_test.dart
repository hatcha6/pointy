import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_entry_run.dart';
import 'package:pointy_frontend/src/shared/async_selection/async_multi_select_picker.dart';

void main() {
  const product = Product(id: 1, name: 'كفر ايفون 13', quantityOnHand: 0);
  const drinks = AsyncSelectionOption<int>(
    id: 4,
    label: 'مشروبات',
    subtitle: '',
  );

  ProductCarryOverValues values({
    String name = 'كفر ايفون 13',
    String price = '25',
    List<AsyncSelectionOption<int>> categories = const [drinks],
    String unit = 'piece',
    bool tracksExpiry = false,
  }) {
    return ProductCarryOverValues(
      name: name,
      price: price,
      pricingCurrency: '',
      categories: categories,
      unit: unit,
      tracksExpiry: tracksExpiry,
      openingCost: '',
    );
  }

  test('nothing carries before the first product is created', () {
    final run = ProductEntryRun();

    expect(run.hasStarted, isFalse);
    expect(run.repeatsPreviousName('كفر ايفون 13'), isFalse);
  });

  test(
    'category and unit are pinned from the start; name and price are not',
    () {
      final run = ProductEntryRun();

      expect(run.isPinned(ProductCarryField.category), isTrue);
      expect(run.isPinned(ProductCarryField.unit), isTrue);
      expect(run.isPinned(ProductCarryField.name), isFalse);
      expect(run.isPinned(ProductCarryField.price), isFalse);
    },
  );

  test('only pinned fields that had a value are marked as carried', () {
    final run = ProductEntryRun()
      ..recordCreated(product, values(), imageFailed: false);

    expect(run.createdCount, 1);
    expect(run.lastCreated, product);
    expect(run.isKept(ProductCarryField.category), isTrue);
    // Pinned, but "piece" is what every new product starts with anyway.
    expect(run.isKept(ProductCarryField.unit), isFalse);
    // Not pinned.
    expect(run.isKept(ProductCarryField.price), isFalse);
  });

  test('pinning a field marks it carried once the previous one had it', () {
    final run = ProductEntryRun()
      ..recordCreated(product, values(), imageFailed: false);

    expect(run.togglePin(ProductCarryField.price), isTrue);
    run.markKept(ProductCarryField.price);
    expect(run.isKept(ProductCarryField.price), isTrue);

    // Unpinning stops it going on; the value shown is still the previous one.
    expect(run.togglePin(ProductCarryField.price), isFalse);
    expect(run.isKept(ProductCarryField.price), isTrue);

    expect(run.unkeep(ProductCarryField.price), isTrue);
    expect(run.isKept(ProductCarryField.price), isFalse);
    expect(run.unkeep(ProductCarryField.price), isFalse);
  });

  test('a name the same as the previous one is caught, spacing aside', () {
    final run = ProductEntryRun()
      ..recordCreated(product, values(), imageFailed: false);

    expect(run.repeatsPreviousName('  كفر  ايفون 13 '), isTrue);
    expect(run.repeatsPreviousName('كفر ايفون 14'), isFalse);
    expect(run.repeatsPreviousName(''), isFalse);
  });

  test('a later product is what the next one carries from', () {
    final run = ProductEntryRun()
      ..recordCreated(product, values(), imageFailed: false)
      ..recordCreated(
        product,
        values(name: 'كفر ايفون 14', categories: const []),
        imageFailed: true,
      );

    expect(run.createdCount, 2);
    expect(run.previous!.name, 'كفر ايفون 14');
    expect(run.lastCreatedImageFailed, isTrue);
    expect(run.isKept(ProductCarryField.category), isFalse);
  });

  test('a copy marks every value it brought, pinned or not', () {
    final run = ProductEntryRun()
      ..startFrom(values(unit: 'kg', tracksExpiry: true));

    expect(run.copiesProduct, isTrue);
    expect(run.createdCount, 0);
    expect(run.lastCreated, isNull);
    for (final field in [
      ProductCarryField.name,
      ProductCarryField.price,
      ProductCarryField.category,
      ProductCarryField.unit,
      ProductCarryField.tracksExpiry,
    ]) {
      expect(run.isKept(field), isTrue, reason: '$field');
    }
    // The original's own shelf cost is not the copy's.
    expect(run.isKept(ProductCarryField.openingCost), isFalse);
    expect(run.repeatsPreviousName('كفر ايفون 13'), isTrue);
  });

  test('once the copy is created, the run carries on from it', () {
    final run = ProductEntryRun()
      ..startFrom(values())
      ..recordCreated(
        product,
        values(name: 'كفر ايفون 14'),
        imageFailed: false,
      );

    expect(run.copiesProduct, isFalse);
    expect(run.previous!.name, 'كفر ايفون 14');
    // Back to what a run keeps: the pinned fields only.
    expect(run.isKept(ProductCarryField.category), isTrue);
    expect(run.isKept(ProductCarryField.name), isFalse);
  });
}
