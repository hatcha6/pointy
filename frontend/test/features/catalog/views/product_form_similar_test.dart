import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/modifier_group.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/models/variant_option.dart';
import 'package:pointy_frontend/src/data/models/variant_option_value.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_entry_pins.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';

/// «منتج مشابه» opens the new-product form on an existing product's values.
/// What has to hold: the copy says what it copied and from where, none of the
/// original's codes come along, nothing is saved until the owner creates it,
/// and a name left as the original's is questioned once.
void main() {
  late List<Map<String, Object?>> posted;
  late List<Product> closedWith;

  const carton = UnitOfMeasure(id: 2, code: 'carton', name: 'كرتون');
  final cola = Product(
    id: 1,
    name: 'كولا علبة 330',
    quantityOnHand: 40,
    description: 'مشروب غازي',
    tracksExpiry: true,
    categories: const [ProductCategory(id: 3, name: 'مشروبات')],
    modifierGroups: const [ModifierGroup(id: 9, name: 'ثلج')],
    units: const [
      ProductUnit(
        id: 70,
        unit: carton,
        factorToBase: 24,
        price: 30,
        barcodes: ['6281000000999'],
      ),
    ],
    defaultVariant: const ProductVariant(
      id: 11,
      productId: 1,
      sku: '1001',
      barcode: '6281000000013',
      unitPrice: 1.25,
      isDefault: true,
    ),
  );

  const sizeOptionJson = {
    'id': 1,
    'code': 'size',
    'name': 'المقاس',
    'values': [
      {'id': 11, 'option': 1, 'code': 'S', 'name': 'S'},
      {'id': 12, 'option': 1, 'code': 'M', 'name': 'M'},
    ],
  };
  const colorOptionJson = {
    'id': 2,
    'code': 'color',
    'name': 'اللون',
    'values': [
      {'id': 21, 'option': 2, 'code': 'RED', 'name': 'أحمر'},
      {'id': 22, 'option': 2, 'code': 'BLUE', 'name': 'أزرق'},
    ],
  };

  CatalogViewModel buildViewModel() {
    var nextSku = 1042;
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/next-sku/')) {
          return json({'sku': '$nextSku'});
        }
        if (path.endsWith('/identity-check/')) {
          return json(const {'sku': null, 'barcode': null});
        }
        if (path.endsWith('/variant-options/')) {
          return json(const {
            'results': [sizeOptionJson, colorOptionJson],
            'next': null,
          });
        }
        if (request.method == 'POST' && path.endsWith('/products/')) {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          posted.add(body);
          final id = 100 + posted.length;
          final sku = '$nextSku';
          nextSku += 1;
          return json({
            'id': id,
            'name': body['name'],
            'variants': [
              {
                'id': id * 10,
                'product': id,
                'sku': sku,
                'barcode': '',
                'unit_price': '1.00',
                'is_default': true,
              },
            ],
          }, 201);
        }
        return json(const {'results': <Object?>[], 'next': null});
      }),
    );
    final viewModel = CatalogViewModel(CatalogRepository(service));
    addTearDown(viewModel.dispose);
    return viewModel;
  }

  Widget formFor(CatalogViewModel viewModel, Product source) {
    return ProductForm(
      viewModel: viewModel,
      similarTo: source,
      offerAddAnother: true,
      showOpeningStock: true,
      onCreated: closedWith.add,
    );
  }

  Future<AppLocalizations> pumpForm(
    WidgetTester tester, {
    Product? source,
  }) async {
    posted = [];
    closedWith = [];
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: formFor(buildViewModel(), source ?? cola)),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  String textOf(WidgetTester tester, String label) =>
      tester.widget<TextFormField>(field(label)).controller!.text;

  Future<void> type(WidgetTester tester, String label, String text) async {
    await tester.enterText(field(label), text);
    // The live duplicate-code check is debounced.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets("the copy opens on the original's values, not on its codes", (
    tester,
  ) async {
    final l10n = await pumpForm(tester);

    expect(find.text(l10n.similarProductNotice('كولا علبة 330')), findsOne);
    expect(textOf(tester, l10n.productNameLabel), 'كولا علبة 330');
    expect(textOf(tester, l10n.unitPriceLabel), '1.25');
    // Folded details holding a copied value open, so nothing copied hides.
    expect(textOf(tester, l10n.descriptionLabel), 'مشروب غازي');
    // The barcode is the original's; the SKU is numbered like any new one.
    expect(textOf(tester, l10n.barcodeLabel), '');
    expect(textOf(tester, l10n.skuLabel), '1042');

    // Marked as the original's, not as a previous product's — and no pins:
    // there is no next product for them to keep anything for yet.
    expect(find.text(l10n.productFieldCopiedLabel), findsWidgets);
    expect(find.text(l10n.productFieldKeptLabel), findsNothing);
    expect(find.byType(FieldPinButton), findsNothing);
    expect(find.text(l10n.productEntryPinsHint), findsNothing);
    expect(find.text(l10n.similarProductNameUnchangedWarning), findsOne);
  });

  testWidgets("it is created with the original's values and codes of its own", (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await type(tester, l10n.barcodeLabel, '6281000000020');
    await type(tester, l10n.productNameLabel, 'كولا علبة 250');

    await press(tester, l10n.createProductButton);

    final body = posted.single;
    expect(body['name'], 'كولا علبة 250');
    expect(body['description'], 'مشروب غازي');
    expect(body['tracks_expiry'], isTrue);
    expect(body['categories'], [3]);
    expect(body['modifier_groups'], [9]);
    final unit = (body['units']! as List).single as Map<String, Object?>;
    expect(unit['unit'], 'carton');
    expect(unit['price'], '30.00');
    expect(unit['barcodes'], isEmpty, reason: "the carton's code is taken");
    final variant = body['default_variant']! as Map<String, Object?>;
    expect(variant['barcode'], '6281000000020');
    expect(variant['sku'], '1042');
    expect(variant['unit_price'], '1.25');
    expect(closedWith, hasLength(1));
  });

  testWidgets(
    'Enter from the barcode lands at the end of the copied name',
    (tester) async {
      final l10n = await pumpForm(tester);
      await type(tester, l10n.barcodeLabel, '6281000000020');

      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();

      // A desktop selects a whole field on focus; then Ctrl+Backspace would
      // take the whole name instead of its last word.
      final name = tester
          .widget<TextFormField>(field(l10n.productNameLabel))
          .controller!;
      expect(
        name.selection,
        TextSelection.collapsed(offset: 'كولا علبة 330'.length),
      );
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets("a name left as the original's is questioned once", (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await type(tester, l10n.barcodeLabel, '6281000000020');

    await press(tester, l10n.createProductButton);
    expect(posted, isEmpty, reason: 'two products named alike, unasked');
    expect(find.text(l10n.similarProductNameUnchangedConfirm), findsOne);

    await press(tester, l10n.createProductButton);
    expect(posted, hasLength(1), reason: 'saving again means it was meant');
  });

  testWidgets('closing a copy nobody touched asks nothing', (tester) async {
    posted = [];
    closedWith = [];
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final viewModel = buildViewModel();
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.binding.setSurfaceSize(const Size(900, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    unawaited(
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(body: formFor(viewModel, cola)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();

    // A copy is not work to lose; nothing was saved, so nothing is left.
    expect(find.text(l10n.unsavedChangesTitle), findsNothing);
    expect(find.byType(ProductForm), findsNothing);
    expect(posted, isEmpty);
  });

  testWidgets('once the copy is added, the run carries on as usual', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await type(tester, l10n.barcodeLabel, '6281000000020');
    await type(tester, l10n.productNameLabel, 'كولا علبة 250');

    await press(tester, l10n.createAndAddAnotherButton);

    expect(posted, hasLength(1));
    expect(find.text(l10n.similarProductNotice('كولا علبة 330')), findsNothing);
    expect(find.byType(FieldPinButton), findsWidgets);
    expect(find.text(l10n.productEntryPinsHint), findsOne);
    // The category is pinned from the start, so it goes on — as the
    // previous product's now.
    expect(find.text(l10n.productFieldKeptLabel), findsOne);
    expect(find.text(l10n.productFieldCopiedLabel), findsNothing);
    expect(textOf(tester, l10n.productNameLabel), '');
  });

  testWidgets('a sized and coloured copy starts from the same grid', (
    tester,
  ) async {
    VariantOptionValue value(int id, int optionId, String name) =>
        VariantOptionValue(id: id, optionId: optionId, name: name);
    final small = value(11, 1, 'S');
    final medium = value(12, 1, 'M');
    final red = value(21, 2, 'أحمر');
    final blue = value(22, 2, 'أزرق');
    ProductVariant variant(
      int id,
      List<VariantOptionValue> values, {
      required double price,
      bool isActive = true,
      bool isDefault = false,
    }) {
      return ProductVariant(
        id: id,
        productId: 5,
        sku: 'SHIRT-$id',
        barcode: '62800$id',
        unitPrice: price,
        isActive: isActive,
        isDefault: isDefault,
        optionValueIds: [for (final value in values) value.id],
        optionValues: values,
      );
    }

    final smallRed = variant(101, [small, red], price: 10, isDefault: true);
    final l10n = await pumpForm(
      tester,
      source: Product(
        id: 5,
        name: 'قميص قطن',
        quantityOnHand: 0,
        variantOptions: const [
          VariantOption(id: 1, code: 'size', name: 'المقاس'),
          VariantOption(id: 2, code: 'color', name: 'اللون'),
        ],
        defaultVariant: smallRed,
        variants: [
          smallRed,
          variant(102, [medium, red], price: 12),
          variant(103, [small, blue], price: 10, isActive: false),
        ],
      ),
    );
    await type(tester, l10n.productNameLabel, 'قميص كتان');

    await press(tester, l10n.nextButton);
    await press(tester, l10n.createProductButton);

    final rows = {
      for (final row in posted.single['variants']! as List)
        ((row as Map<String, Object?>)['option_values']! as List).join(','):
            row,
    };
    expect(rows.keys, unorderedEquals(['11,21', '11,22', '12,21', '12,22']));
    for (final row in rows.values) {
      expect(row['barcode'], '', reason: "the original's codes stay its own");
    }
    expect(rows['11,21']!['unit_price'], '10.00');
    expect(rows['11,21']!['is_default'], isTrue);
    expect(rows['12,21']!['unit_price'], '12.00');
    expect(rows['12,21']!['is_active'], isTrue);
    expect(rows['11,22']!['is_active'], isFalse, reason: 'off in the original');
    // Every combination of the values is a row; one the original never had
    // is the owner's to switch on.
    expect(rows['12,22']!['is_active'], isFalse);
  });
}
