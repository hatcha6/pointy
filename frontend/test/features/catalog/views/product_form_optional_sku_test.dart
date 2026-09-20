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

/// Plenty of shops keep no SKUs and no barcodes — a sack of rice has a name
/// and a price and nothing else. The wizard used to refuse to move past the
/// variant step until a code was invented, so the shop ended up with codes it
/// made up on the spot and never used again. Both fields are optional now; the
/// server codes a blank SKU itself.
void main() {
  Future<Map<String, Object?>?> createWith(
    WidgetTester tester, {
    required String sku,
    required String barcode,
  }) async {
    Map<String, Object?>? posted;
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
              'name': 'أرز',
              'variants': [
                {
                  'id': 34,
                  'product': 12,
                  'sku': 'P000012',
                  'barcode': '',
                  'unit_price': '5.00',
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

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ProductForm(viewModel: viewModel)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'أرز');
    await tester.tap(find.text(l10n.nextButton));
    await tester.pumpAndSettle();

    // Step two, in order: variant name, SKU, barcode, price.
    await tester.enterText(find.byType(TextFormField).at(1), sku);
    await tester.enterText(find.byType(TextFormField).at(2), barcode);
    await tester.enterText(find.byType(TextFormField).at(3), '5');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.createProductButton));
    await tester.pumpAndSettle();
    return posted;
  }

  testWidgets('a product is created with neither a SKU nor a barcode', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final posted = await createWith(tester, sku: '', barcode: '');

    expect(
      find.text(l10n.requiredField),
      findsNothing,
      reason: 'neither identity field may block the save',
    );
    expect(posted, isNotNull);
    final defaultVariant =
        (posted!['default_variant'] as Map<String, Object?>?)!;
    expect(defaultVariant['sku'], '');
    expect(defaultVariant['barcode'], '');
  });

  testWidgets('the field still says a SKU will be coded for a blank one', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
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
        home: Scaffold(body: ProductForm(viewModel: viewModel)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'أرز');
    await tester.tap(find.text(l10n.nextButton));
    await tester.pumpAndSettle();

    expect(find.text(l10n.skuOptionalHelper), findsOneWidget);
  });

  testWidgets('a typed SKU is still sent as typed', (tester) async {
    final posted = await createWith(tester, sku: 'RICE-5', barcode: '');

    final defaultVariant =
        (posted!['default_variant'] as Map<String, Object?>?)!;
    expect(defaultVariant['sku'], 'RICE-5');
  });
}
