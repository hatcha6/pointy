import '../sandbox_payloads.dart';
import '../sandbox_request.dart';
import '../sandbox_shop.dart';

/// Products, variants, barcodes and prices — the shop's own description of
/// what it sells.
SandboxReply handleCatalog(SandboxShop shop, SandboxRequest request) {
  if (request.on('GET', 'products/') != null) {
    return (200, page(_search(shop, request.query('search'))));
  }
  if (request.on('POST', 'products/') != null) {
    return (201, productJson(_createProduct(shop, request)));
  }

  final product = request.on('GET', 'products/{id}/');
  if (product != null) {
    final found = shop.products.where((p) => '${p.id}' == product.first);
    return found.isEmpty
        ? (404, {'detail': 'not found'})
        : (200, productJson(found.first));
  }

  final patch = request.on('PATCH', 'products/{id}/');
  if (patch != null) {
    for (final item in shop.products) {
      if ('${item.id}' != patch.first) {
        continue;
      }
      if (request.body.containsKey('name')) {
        item.name = request.text('name');
      }
      shop.stateVersion++;
      return (200, productJson(item));
    }
    return (404, {'detail': 'not found'});
  }

  final addVariant = request.on('POST', 'products/{id}/variants/');
  if (addVariant != null) {
    final variant = shop.addVariant(
      productId: int.tryParse(addVariant.first) ?? 0,
      name: request.text('name'),
      sku: request.text('sku'),
      barcode: request.text('barcode'),
      price: request.field('unit_price'),
    );
    if (variant == null) {
      return (404, {'detail': 'not found'});
    }
    final parent = shop.productOfVariant(variant.id)!;
    return (201, variantJson(parent, variant));
  }

  final setPrices = request.on('POST', 'products/{id}/set-variant-prices/');
  if (setPrices != null) {
    for (final row in request.rows('prices')) {
      final id = int.tryParse(row['product_variant']?.toString() ?? '');
      if (id != null) {
        shop.setVariantPrice(
          variantId: id,
          price: request.money(row['unit_price']),
        );
      }
    }
    final found = shop.products.where((p) => '${p.id}' == setPrices.first);
    return found.isEmpty
        ? (404, {'detail': 'not found'})
        : (200, productJson(found.first));
  }

  if (request.on('GET', 'product-variants/') != null) {
    return (200, page(_variants(shop, request)));
  }
  if (request.on('POST', 'product-variants/') != null) {
    final variant = shop.addVariant(
      productId: request.id('product') ?? 0,
      name: request.text('name'),
      sku: request.text('sku'),
      barcode: request.text('barcode'),
      price: request.field('unit_price'),
    );
    if (variant == null) {
      return (400, {'detail': 'منتج غير معروف'});
    }
    return (201, variantJson(shop.productOfVariant(variant.id)!, variant));
  }

  final variantPatch = request.on('PATCH', 'product-variants/{id}/');
  if (variantPatch != null) {
    final variant = shop.variantById(int.tryParse(variantPatch.first) ?? 0);
    if (variant == null) {
      return (404, {'detail': 'not found'});
    }
    if (request.body.containsKey('unit_price')) {
      variant.unitPrice = request.field('unit_price');
    }
    if (request.body.containsKey('barcode')) {
      variant.barcode = request.text('barcode');
    }
    if (request.body.containsKey('name')) {
      variant.name = request.text('name');
    }
    shop.stateVersion++;
    return (200, variantJson(shop.productOfVariant(variant.id)!, variant));
  }

  if (request.on('GET', 'units-of-measure/') != null) {
    return (
      200,
      page([
        for (final (index, unit) in const [
          ('piece', 'حبة', 'count'),
          ('box', 'علبة', 'count'),
          ('carton', 'كرتونة', 'count'),
          ('kg', 'كيلوغرام', 'mass'),
        ].indexed)
          {
            'id': index + 1,
            'code': unit.$1,
            'name': unit.$2,
            'abbreviation': unit.$2,
            'dimension': unit.$3,
            'reference_factor': null,
            'allows_fractional': unit.$3 == 'mass',
            'is_system': true,
            'is_active': true,
            'display_order': index,
            'product_count': 0,
          },
      ]),
    );
  }
  if (request.on('GET', 'product-variants/identity-check/') != null ||
      request.on('POST', 'product-variants/identity-check/') != null) {
    // The practice shop is not the identity checker: a lesson that dead-ends
    // on "this barcode is taken" teaches nothing, and the real check has its
    // own tests. Everything typed here is free.
    return (
      200,
      {'sku_available': true, 'barcode_available': true, 'conflicts': const []},
    );
  }

  if (request.on('GET', 'product-categories/') != null) {
    return (
      200,
      page([
        for (final category in shop.categories)
          {'id': category.id, 'name': category.name, 'parent': null},
      ]),
    );
  }
  if (request.on('GET', 'variant-options/') != null) {
    // One option with three values, so a lesson can teach generation without
    // the learner first having to invent a vocabulary. A grocery does not sell
    // shirts, but every shop that has variants has exactly this shape.
    return (200, page([_sizeOption]));
  }
  if (request.on('GET', 'variant-option-values/') != null) {
    return (200, page(_sizeOption['values']! as List<Object?>));
  }
  if (request.on('GET', 'stock/') != null) {
    return (
      200,
      page([
        for (final item in shop.products)
          for (final variant in item.variants)
            {
              'id': variant.id,
              'product_variant': variant.id,
              'product_name': item.name,
              'sku': variant.sku,
              'quantity': money(variant.stock),
              'quantity_on_hand': money(variant.stock),
            },
      ]),
    );
  }
  if (request.on('GET', 'stock-movements/') != null) {
    return (200, page(const []));
  }
  if (request.on('POST', 'stock-movements/') != null) {
    final id = request.id('product_variant');
    final quantity = request.field('quantity');
    final type = request.text('movement_type');
    if (id != null) {
      shop.adjustStock(
        variantId: id,
        delta: type == 'out' || type == 'waste' ? -quantity : quantity,
      );
    }
    return (
      201,
      {
        'id': nextPracticeId(),
        'product_variant': id,
        'movement_type': type,
        'quantity': money(quantity),
        'created_at': stamp(DateTime.now()),
      },
    );
  }
  return null;
}

SandboxProduct _createProduct(SandboxShop shop, SandboxRequest request) {
  // The form posts one `default_variant` for a plain product and a `variants`
  // list for a product with options — both shapes, because the catalogue form
  // teaches both and a lesson has to reach the same endpoint the shop does.
  final rows = request.rows('variants');
  final single = request.body['default_variant'];
  if (rows.isEmpty && single is Map<String, Object?>) {
    rows.add(single);
  }
  final variants = <({String name, String sku, String barcode, double price})>[
    for (final row in rows)
      (
        name: row['name']?.toString() ?? '',
        sku: row['sku']?.toString() ?? '',
        barcode: row['barcode']?.toString() ?? '',
        price: request.money(row['unit_price']),
      ),
  ];
  if (variants.isEmpty) {
    variants.add((name: '', sku: '', barcode: '', price: 0));
  }

  final product = shop.createProduct(
    name: request.text('name'),
    unit: request.body['unit']?.toString() ?? 'piece',
    categoryIds: [
      for (final value in (request.body['categories'] as List<Object?>? ?? []))
        if (int.tryParse(value.toString()) != null) int.parse(value.toString()),
    ],
    variants: variants,
  );

  // Packaging codes ride along on the product's units — the carton's own EAN,
  // which scans to the same product at the carton's price.
  for (final unit in request.rows('units')) {
    for (final code in (unit['barcodes'] as List<Object?>? ?? const [])) {
      shop.addBarcode(
        variantId: product.defaultVariant.id,
        barcode: code.toString(),
      );
    }
  }
  return product;
}

List<Map<String, Object?>> _search(SandboxShop shop, String search) {
  final matches = search.isEmpty
      ? shop.products
      : shop.products
            .where(
              (product) =>
                  product.name.contains(search) ||
                  product.variants.any(
                    (variant) =>
                        variant.sku == search ||
                        variant.allBarcodes.contains(search),
                  ),
            )
            .toList(growable: false);
  return [for (final product in matches) productJson(product)];
}

List<Map<String, Object?>> _variants(SandboxShop shop, SandboxRequest request) {
  final barcode = request.query('barcode');
  final search = request.query('search');
  final results = <Map<String, Object?>>[];
  for (final product in shop.products) {
    for (final variant in product.variants) {
      final matchesBarcode =
          barcode.isEmpty ||
          variant.sku == barcode ||
          variant.allBarcodes.contains(barcode);
      final matchesSearch =
          search.isEmpty ||
          product.name.contains(search) ||
          variant.sku == search ||
          variant.allBarcodes.contains(search);
      if (matchesBarcode && matchesSearch) {
        results.add(variantJson(product, variant, includeProductDetail: true));
      }
    }
  }
  return results;
}

/// «المقاس» — صغير / وسط / كبير.
const Map<String, Object?> _sizeOption = {
  'id': 1,
  'code': 'size',
  'name': 'المقاس',
  'display_order': 0,
  'is_active': true,
  'values': [
    {'id': 11, 'option': 1, 'code': 's', 'name': 'صغير', 'is_active': true},
    {'id': 12, 'option': 1, 'code': 'm', 'name': 'وسط', 'is_active': true},
    {'id': 13, 'option': 1, 'code': 'l', 'name': 'كبير', 'is_active': true},
  ],
};
