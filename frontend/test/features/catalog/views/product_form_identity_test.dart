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

/// The create-product dialog has to answer "that barcode already exists" on the
/// barcode field, naming the owner. Creating a product used to send the code
/// straight into the unique index, so the shop owner got a 500 with no idea
/// which of the two codes was the problem.
void main() {
  const conflictBody = {
    'default_variant': {
      'barcode': ['Barcode "999" is already used by "قهوة عربية".'],
    },
    'conflicts': [
      {
        'field': 'barcode',
        'value': '999',
        'kind': 'variant',
        'target': 'default_variant',
        'index': '',
        'product_id': '7',
        'product_name': 'قهوة عربية',
        'variant_id': '70',
        'variant_sku': 'COF-1',
        'variant_name': '',
        'unit_code': '',
        'is_archived': 'false',
        'message': 'Barcode "999" is already used by "قهوة عربية".',
      },
    ],
  };

  const takenIdentity = {
    'sku': null,
    'barcode': {
      'field': 'barcode',
      'value': '999',
      'kind': 'unit',
      'target': '',
      'index': null,
      'product_id': 7,
      'product_name': 'قهوة عربية',
      'variant_id': null,
      'variant_sku': '',
      'variant_name': '',
      'unit_code': 'carton',
      'is_archived': false,
      'message': 'unit clash',
    },
  };

  const freeIdentity = {'sku': null, 'barcode': null};

  Future<void> pumpForm(
    WidgetTester tester, {
    required Map<String, Object?> identityResponse,
    int createStatus = 201,
    Map<String, Object?> createBody = const {},
  }) async {
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/identity-check/')) {
          return http.Response(
            jsonEncode(identityResponse),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode(createBody),
            createStatus,
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
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ProductForm(viewModel: viewModel)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Fills the first step and moves to the default-variant step.
  Future<void> goToVariantStep(
    WidgetTester tester,
    AppLocalizations l10n,
  ) async {
    await tester.enterText(find.byType(TextFormField).first, 'منتج جديد');
    await tester.tap(find.text(l10n.nextButton));
    await tester.pumpAndSettle();
  }

  testWidgets('a packaging barcode clash is named on the barcode field', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpForm(tester, identityResponse: takenIdentity);
    await goToVariantStep(tester, l10n);

    // Step two: variant name, SKU, barcode, price.
    await tester.enterText(find.byType(TextFormField).at(2), '999');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(
      find.text(l10n.barcodeTakenByUnitError('carton', 'قهوة عربية')),
      findsOneWidget,
    );
  });

  testWidgets(
    'a scanned-in barcode is checked without waiting for a keystroke',
    (tester) async {
      final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
      final service = PosApiService(
        baseUrl: 'http://pointy.test/api',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/identity-check/')) {
            return http.Response(
              jsonEncode(takenIdentity),
              200,
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            // How the POS opens this form for a code that matched nothing.
            body: ProductForm(viewModel: viewModel, initialBarcode: '999'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await goToVariantStep(tester, l10n);
      await tester.pumpAndSettle();

      expect(
        find.text(l10n.barcodeTakenByUnitError('carton', 'قهوة عربية')),
        findsOneWidget,
      );
    },
  );

  testWidgets('a rejected create marks the default variant field', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpForm(
      tester,
      identityResponse: freeIdentity,
      createStatus: 400,
      createBody: conflictBody,
    );
    await goToVariantStep(tester, l10n);

    await tester.enterText(find.byType(TextFormField).at(1), 'NEW-1');
    await tester.enterText(find.byType(TextFormField).at(2), '999');
    await tester.enterText(find.byType(TextFormField).at(3), '5');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.createProductButton));
    await tester.pumpAndSettle();

    expect(find.text(l10n.barcodeTakenError('قهوة عربية')), findsOneWidget);
    expect(find.text(l10n.formFixHighlightedFieldsError), findsOneWidget);
    expect(find.text(l10n.productCreateError), findsNothing);
  });
}
