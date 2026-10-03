import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';

/// A shop entering a product it already has forty of says so here, rather than
/// raising a purchase order against a supplier it never bought from. The pair
/// travels on the default variant, and the server turns it into a valued
/// opening balance — so the till has a cost for the product from day one.
void main() {
  late Map<String, Object?>? posted;

  Future<void> openForm(
    WidgetTester tester, {
    required bool showOpeningStock,
  }) async {
    posted = null;
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/identity-check/')) {
          return http.Response(
            jsonEncode(const {'sku': null, 'barcode': null}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST') {
          posted = jsonDecode(request.body) as Map<String, Object?>;
          return http.Response(
            jsonEncode(const {
              'id': 12,
              'name': 'زيت زيتون',
              'variants': [
                {
                  'id': 34,
                  'product': 12,
                  'sku': 'OIL-1',
                  'barcode': '',
                  'unit_price': '12.00',
                  'is_default': true,
                },
              ],
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode(const {'results': <Object?>[], 'next': null}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final viewModel = CatalogViewModel(CatalogRepository(service));
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ProductForm(
            viewModel: viewModel,
            showOpeningStock: showOpeningStock,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  /// One page: name, SKU and price, then — when it is offered — the opening
  /// quantity and cost under them.
  Future<void> fillProduct(
    WidgetTester tester,
    AppLocalizations l10n, {
    required String price,
    String? openingQuantity,
    String? openingCost,
  }) async {
    await tester.enterText(field(l10n.productNameLabel), 'زيت زيتون');
    await tester.enterText(field(l10n.skuLabel), 'OIL-1');
    await tester.enterText(field(l10n.unitPriceLabel), price);
    if (openingQuantity != null) {
      await tester.enterText(
        field(l10n.openingStockQuantityLabel),
        openingQuantity,
      );
    }
    if (openingCost != null) {
      await tester.enterText(
        field(l10n.openingStockUnitCostLabel),
        openingCost,
      );
    }
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  testWidgets('the opening pair travels on the default variant', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await openForm(tester, showOpeningStock: true);
    await fillProduct(
      tester,
      l10n,
      price: '12',
      openingQuantity: '40',
      openingCost: '7.5',
    );

    await tester.tap(find.text(l10n.createProductButton));
    await tester.pumpAndSettle();

    final variant = posted!['default_variant']! as Map<String, Object?>;
    expect(variant['opening_quantity'], '40.000');
    expect(variant['opening_unit_cost'], '7.500000');
  });

  testWidgets('a product with no opening stock sends neither key', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await openForm(tester, showOpeningStock: true);
    await fillProduct(tester, l10n, price: '12');

    await tester.tap(find.text(l10n.createProductButton));
    await tester.pumpAndSettle();

    final variant = posted!['default_variant']! as Map<String, Object?>;
    expect(variant.containsKey('opening_quantity'), isFalse);
    expect(variant.containsKey('opening_unit_cost'), isFalse);
  });

  testWidgets('the section is absent when the caller does not offer it', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await openForm(tester, showOpeningStock: false);

    expect(find.text(l10n.openingStockSectionTitle), findsNothing);
    expect(find.text(l10n.openingStockQuantityLabel), findsNothing);
  });

  testWidgets('a cost with no quantity blocks the save and says which', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await openForm(tester, showOpeningStock: true);
    await fillProduct(tester, l10n, price: '12', openingCost: '7.5');

    await tester.tap(find.text(l10n.createProductButton));
    await tester.pumpAndSettle();

    expect(posted, isNull);
    expect(find.text(l10n.openingStockCostNeedsQuantityError), findsOneWidget);
  });

  testWidgets('the pair multiplies out while it can still be corrected', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await openForm(tester, showOpeningStock: true);
    await fillProduct(
      tester,
      l10n,
      price: '12',
      openingQuantity: '40',
      openingCost: '7.5',
    );

    expect(
      find.textContaining('300.00'),
      findsOneWidget,
      reason: '40 × 7.50 should be shown under the fields',
    );
  });

  testWidgets('a service keeps no stock, so it is offered no opening', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await openForm(tester, showOpeningStock: true);
    expect(find.text(l10n.openingStockSectionTitle), findsOneWidget);

    await tester.enterText(field(l10n.productNameLabel), 'صيانة');
    // The service switch is folded under «تفاصيل إضافية».
    final moreDetails = find.byKey(
      const ValueKey('product_form_more_details_toggle'),
    );
    await tester.ensureVisible(moreDetails);
    await tester.pumpAndSettle();
    await tester.tap(moreDetails);
    await tester.pumpAndSettle();
    final serviceToggle = find.ancestor(
      of: find.text(l10n.productIsServiceTitle),
      matching: find.byType(SwitchListTile),
    );
    await tester.ensureVisible(serviceToggle);
    await tester.pumpAndSettle();
    await tester.tap(serviceToggle);
    await tester.pumpAndSettle();

    expect(find.text(l10n.openingStockSectionTitle), findsNothing);
  });
}
