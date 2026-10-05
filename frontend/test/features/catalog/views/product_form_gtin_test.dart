import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';
import 'package:pointy_frontend/src/shared/tracking/tracking_features.dart';

/// A lot-tracked product's GTIN and expiry policy on the create form.
///
/// The GTIN appears only with the lot policy — a shop selling Coca-Cola never
/// sees it — is checked before the save, lands on the default variant, and
/// like every code is neither carried to the next product nor copied by
/// «منتج مشابه».
void main() {
  late List<Map<String, Object?>> posted;
  late http.Response Function(Map<String, Object?> body) answer;

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  http.Response created(Map<String, Object?> body) => json({
    'id': 100 + posted.length,
    'name': body['name'],
    'variants': [
      {
        'id': 1000 + posted.length,
        'product': 100 + posted.length,
        'sku': '1042',
        'unit_price': '1.00',
        'is_default': true,
      },
    ],
  }, 201);

  CatalogViewModel buildViewModel() {
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/next-sku/')) {
          return json({'sku': '1042'});
        }
        if (path.endsWith('/identity-check/')) {
          return json(const {'sku': null, 'barcode': null});
        }
        if (request.method == 'POST' && path.endsWith('/products/')) {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          posted.add(body);
          return answer(body);
        }
        return json(const {'results': <Object?>[], 'next': null});
      }),
    );
    final viewModel = CatalogViewModel(CatalogRepository(service));
    addTearDown(viewModel.dispose);
    return viewModel;
  }

  Future<AppLocalizations> pumpForm(
    WidgetTester tester, {
    Product? similarTo,
    bool offerAddAnother = false,
  }) async {
    posted = [];
    answer = created;
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => TrackingFeaturesScope(
          features: const TrackingFeatures(batch: true, serial: true),
          child: child!,
        ),
        home: Scaffold(
          body: ProductForm(
            viewModel: buildViewModel(),
            similarTo: similarTo,
            offerAddAnother: offerAddAnother,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  Future<void> type(WidgetTester tester, String label, String text) async {
    await tester.enterText(field(label), text);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  Future<void> chooseLots(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('product_tracking_mode_batch')));
    await tester.pumpAndSettle();
  }

  Future<void> create(WidgetTester tester, AppLocalizations l10n) async {
    await tester.ensureVisible(find.text(l10n.createProductButton).first);
    await tester.tap(find.text(l10n.createProductButton).first);
    await tester.pumpAndSettle();
  }

  testWidgets('the GTIN shows with the lot policy and nowhere else', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    expect(field(l10n.variantGtinLabel), findsNothing);

    await chooseLots(tester);
    expect(field(l10n.variantGtinLabel), findsOne);
    expect(
      find.byKey(const ValueKey('product_tracking_expiry_required')),
      findsOne,
    );
  });

  testWidgets('a wrong check digit is refused before anything is sent', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await type(tester, l10n.productNameLabel, 'أموكسيسيلين');
    await type(tester, l10n.unitPriceLabel, '12');
    await chooseLots(tester);
    await type(tester, l10n.variantGtinLabel, '4006381333932');

    await create(tester, l10n);

    expect(posted, isEmpty);
    expect(find.text(l10n.gtinErrorCheckDigit), findsOne);
  });

  testWidgets('the GTIN and expiry policy reach the default variant', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    await type(tester, l10n.productNameLabel, 'أموكسيسيلين');
    await type(tester, l10n.unitPriceLabel, '12');
    await chooseLots(tester);
    await type(tester, l10n.variantGtinLabel, '4006381333931');
    await tester.tap(
      find.byKey(const ValueKey('product_tracking_expiry_required')),
    );
    await tester.pumpAndSettle();

    await create(tester, l10n);

    final body = posted.single;
    expect(body['tracking_mode'], TrackingMode.batch.wire);
    expect(body['expiry_required'], isTrue);
    final variant = body['default_variant']! as Map<String, Object?>;
    expect(variant['gtin'], '4006381333931');
  });

  testWidgets("another product's GTIN lands under the field, in Arabic", (
    tester,
  ) async {
    final l10n = await pumpForm(tester);
    answer = (_) => json({
      'default_variant': {
        'gtin': ['GTIN "04006381333931" is already used by "باراسيتامول".'],
      },
      'conflicts': [
        {
          'field': 'gtin',
          'kind': 'variant',
          'target': 'default_variant',
          'value': '04006381333931',
          'product_name': 'باراسيتامول',
        },
      ],
    }, 400);
    await type(tester, l10n.productNameLabel, 'أموكسيسيلين');
    await type(tester, l10n.unitPriceLabel, '12');
    await chooseLots(tester);
    await type(tester, l10n.variantGtinLabel, '4006381333931');

    await create(tester, l10n);

    expect(find.text(l10n.gtinTakenError('باراسيتامول')), findsOne);
  });

  testWidgets('a counted product sends no GTIN at all', (tester) async {
    final l10n = await pumpForm(tester);
    await type(tester, l10n.productNameLabel, 'كولا');
    await type(tester, l10n.unitPriceLabel, '1');

    await create(tester, l10n);

    final variant = posted.single['default_variant']! as Map<String, Object?>;
    expect(variant.containsKey('gtin'), isFalse);
  });

  testWidgets('«منتج مشابه» copies the lot policy but not the GTIN', (
    tester,
  ) async {
    final source = Product(
      id: 1,
      name: 'أموكسيسيلين 500',
      quantityOnHand: 0,
      trackingMode: TrackingMode.batch,
      expiryRequired: true,
      defaultVariant: const ProductVariant(
        id: 11,
        productId: 1,
        sku: '1001',
        gtin: '04006381333931',
        unitPrice: 12,
        isDefault: true,
      ),
    );
    final l10n = await pumpForm(tester, similarTo: source);

    final gtin = tester.widget<TextFormField>(field(l10n.variantGtinLabel));
    expect(gtin.controller!.text, isEmpty);
    final expiry = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey('product_tracking_expiry_required')),
    );
    expect(expiry.value, isTrue);
  });

  testWidgets('the next product after «إضافة آخر» starts without the GTIN', (
    tester,
  ) async {
    final l10n = await pumpForm(tester, offerAddAnother: true);
    await type(tester, l10n.productNameLabel, 'أموكسيسيلين');
    await type(tester, l10n.unitPriceLabel, '12');
    await chooseLots(tester);
    await type(tester, l10n.variantGtinLabel, '4006381333931');

    await tester.ensureVisible(find.text(l10n.createAndAddAnotherButton));
    await tester.tap(find.text(l10n.createAndAddAnotherButton));
    await tester.pumpAndSettle();

    expect(posted, hasLength(1));
    // Lots again for the next product: the number itself never carries.
    if (field(l10n.variantGtinLabel).evaluate().isEmpty) {
      await chooseLots(tester);
    }
    expect(
      tester
          .widget<TextFormField>(field(l10n.variantGtinLabel))
          .controller!
          .text,
      isEmpty,
    );
  });
}
