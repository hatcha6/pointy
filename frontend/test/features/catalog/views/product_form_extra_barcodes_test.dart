import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/barcode_resolution.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';

/// A product answers to more than one barcode. The create form keeps the main
/// barcode where it was and folds the others under it: one action until there
/// is a first code, then chips checked against the catalogue as they are added.
void main() {
  const freeIdentity = {'sku': null, 'barcode': null};

  Map<String, Object?> takenBy(String value, String owner) => {
    'sku': null,
    'barcode': {
      'field': 'barcode',
      'value': value,
      'kind': 'variant',
      'target': '',
      'index': null,
      'product_id': 7,
      'product_name': owner,
      'variant_id': 70,
      'variant_sku': 'OWN-1',
      'variant_name': '',
      'unit_code': '',
      'is_archived': false,
      'message': 'taken',
    },
  };

  late List<Map<String, Object?>> posted;

  Future<void> pumpForm(
    WidgetTester tester, {
    Map<String, Map<String, Object?>> takenBarcodes = const {},
    int createStatus = 201,
    Map<String, Object?>? createBody,
  }) async {
    posted = [];
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/identity-check/')) {
          final code = request.url.queryParameters['barcode'] ?? '';
          return http.Response.bytes(
            utf8.encode(jsonEncode(takenBarcodes[code] ?? freeIdentity)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'POST') {
          posted.add(jsonDecode(request.body) as Map<String, Object?>);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(
                createBody ??
                    {
                      'id': 1,
                      'name': 'حليب',
                      'default_variant': {
                        'id': 10,
                        'product': 1,
                        'sku': 'MILK-1',
                        'unit_price': '4.50',
                      },
                    },
              ),
            ),
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

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  final addButton = find.byKey(
    const ValueKey('variant_extra_barcodes_add_button'),
  );
  final extraInput = find.byKey(const ValueKey('variant_extra_barcode_input'));

  Future<void> fillEssentials(
    WidgetTester tester,
    AppLocalizations l10n,
  ) async {
    await tester.enterText(field(l10n.productNameLabel), 'حليب');
    await tester.enterText(field(l10n.barcodeLabel), '6281000000011');
    await tester.enterText(field(l10n.unitPriceLabel), '4.5');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  Future<void> addExtra(WidgetTester tester, String code) async {
    if (extraInput.evaluate().isEmpty) {
      await tester.ensureVisible(addButton);
      await tester.tap(addButton);
      await tester.pumpAndSettle();
    }
    await tester.enterText(extraInput, code);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Future<void> create(WidgetTester tester, AppLocalizations l10n) async {
    final button = find.text(l10n.createProductButton);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('the action appears only once there is a main barcode', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpForm(tester);

    expect(addButton, findsNothing);
    await fillEssentials(tester, l10n);
    expect(addButton, findsOneWidget);
    expect(extraInput, findsNothing);
  });

  testWidgets('added codes become chips and are saved beside the main one', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpForm(tester);
    await fillEssentials(tester, l10n);

    await addExtra(tester, '6281000000028');
    await addExtra(tester, '7001');
    expect(find.widgetWithText(InputChip, '6281000000028'), findsOneWidget);
    expect(find.widgetWithText(InputChip, '7001'), findsOneWidget);

    // Removing one takes it off the save.
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, '7001'),
        matching: find.byTooltip(l10n.variantExtraBarcodeRemoveTooltip),
      ),
    );
    await tester.pumpAndSettle();
    // Typed but never added: pressing save is as clear an "add it".
    await tester.enterText(extraInput, '8002');
    await create(tester, l10n);

    final variant = posted.single['default_variant'] as Map<String, Object?>;
    expect(variant['barcode'], '6281000000011');
    expect(variant['extra_barcodes'], ['6281000000028', '8002']);
  });

  testWidgets('a code another product owns is refused with its name', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpForm(
      tester,
      takenBarcodes: {'555': takenBy('555', 'قهوة عربية')},
    );
    await fillEssentials(tester, l10n);

    await addExtra(tester, '555');

    expect(find.text(l10n.barcodeTakenError('قهوة عربية')), findsOneWidget);
    expect(find.widgetWithText(InputChip, '555'), findsNothing);
  });

  testWidgets('the main barcode and a repeat are refused locally', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpForm(tester);
    await fillEssentials(tester, l10n);

    await addExtra(tester, '6281000000011');
    expect(find.text(l10n.variantExtraBarcodeIsPrimary), findsOneWidget);

    await tester.enterText(extraInput, '');
    await addExtra(tester, '7001');
    await addExtra(tester, '7001');
    expect(find.text(l10n.variantExtraBarcodeDuplicate), findsOneWidget);
    expect(find.widgetWithText(InputChip, '7001'), findsOneWidget);
  });

  testWidgets('a rejected save marks the extra code, not the main barcode', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    await pumpForm(
      tester,
      createStatus: 400,
      createBody: {
        'default_variant': {
          'extra_barcodes': ['Barcode "7001" is already used by "شاي".'],
        },
        'conflicts': [
          {
            'field': 'extra_barcodes',
            'value': '7001',
            'kind': 'variant',
            'target': 'default_variant',
            'index': '',
            'product_id': '8',
            'product_name': 'شاي',
            'variant_id': '80',
            'variant_sku': 'TEA-1',
            'variant_name': '',
            'unit_code': '',
            'is_archived': 'false',
            'message': 'taken',
          },
        ],
      },
    );
    await fillEssentials(tester, l10n);
    await addExtra(tester, '7001');

    await create(tester, l10n);

    expect(find.text(l10n.barcodeTakenError('شاي')), findsOneWidget);
    expect(find.text(l10n.formFixHighlightedFieldsError), findsOneWidget);
    // The main barcode field stays clean.
    final barcode = tester.widget<TextField>(
      find.descendant(
        of: field(l10n.barcodeLabel),
        matching: find.byType(TextField),
      ),
    );
    expect(barcode.decoration?.errorText, isNull);
  });

  test('a scan of an extra barcode resolves to its variant', () async {
    final repository = CatalogRepository(
      PosApiService(
        baseUrl: 'http://pointy.test/api',
        client: MockClient((request) async {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'count': 1,
                'next': null,
                'results': [
                  {
                    'id': 11,
                    'product': 5,
                    'product_name': 'حليب',
                    'sku': 'MILK-1',
                    'unit_price': '4.50',
                    'barcode': '6281000000011',
                    'extra_barcodes': ['6281000000028'],
                    'is_default': true,
                    'is_active': true,
                  },
                ],
              }),
            ),
            200,
          );
        }),
      ),
    );

    final result = await repository.resolveBarcode('6281000000028');

    final resolution = (result as Ok<BarcodeResolution?>).value;
    expect(resolution?.variant.id, 11);
    expect(resolution?.isUnitBarcode, isFalse);
  });
}
