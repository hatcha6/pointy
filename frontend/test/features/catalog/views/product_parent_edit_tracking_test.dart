import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bought_together_product.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_details_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/tracking_mode_refusal.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_parent_edit_sheet.dart';
import 'package:pointy_frontend/src/shared/tracking/tracking_features.dart';

/// Turning serials on for a product whose handsets are already on the shelf.
///
/// The server holds that save back with a question — the stock would wait
/// «بانتظار المعرّف», unsellable until each handset is scanned — and the sheet
/// asks it, once, then sends the same edit again with the answer. Declining
/// leaves the shop exactly as it was.
void main() {
  late List<Map<String, Object?>> patches;
  late http.Response Function(Map<String, Object?> body) answer;
  late int savedCount;

  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  Product buildProduct({double onHand = 3}) => Product(
    id: 1,
    name: 'هاتف',
    quantityOnHand: onHand,
    variants: const [
      ProductVariant(id: 11, productId: 1, sku: 'PH-1', unitPrice: 900),
    ],
  );

  Map<String, Object?> savedProduct(String mode) => {
    'id': 1,
    'name': 'هاتف',
    'quantity_on_hand': '3.000',
    'tracking_mode': mode,
    'variants': [
      {
        'id': 11,
        'product': 1,
        'sku': 'PH-1',
        'unit_price': '900.00',
        'is_default': true,
      },
    ],
  };

  final identifyQuestion = {
    'tracking_mode': [
      'في المخزون 3 قطعة من هذا المنتج بلا أرقام. عند التفعيل تُسجَّل '
          '«بانتظار المعرّف»، ولا تُباع قطعة منها حتى يُدخل رقمها.',
    ],
    'code': [trackingIdentifyLaterCode],
    'on_hand': ['3'],
    'current_mode': ['quantity'],
    'requested_mode': ['serial'],
  };

  /// The server as it is: a question without the answer, a save with it.
  http.Response serverAsksAboutStock(Map<String, Object?> body) =>
      body['tracking_mode_identify_later'] == true
      ? json(savedProduct('serial'))
      : json(identifyQuestion, 400);

  Future<AppLocalizations> pumpSheet(
    WidgetTester tester, {
    required Product product,
  }) async {
    patches = [];
    savedCount = 0;
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        if (request.method == 'PATCH' &&
            request.url.path.endsWith('/products/1/')) {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          patches.add(body);
          return answer(body);
        }
        return json(const {'results': <Object?>[], 'next': null});
      }),
    );
    final viewModel = ProductDetailsViewModel(
      _StubCatalogRepository(service, product),
      _StubPurchaseRepository(service),
      _StubSaleRepository(service),
      product,
      shouldLoadSaleHistory: false,
      shouldLoadPurchaseHistory: false,
    );
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => TrackingFeaturesScope(
          features: const TrackingFeatures(serial: true),
          child: child!,
        ),
        home: Scaffold(
          body: ProductParentEditSheet(
            viewModel: viewModel,
            onSaved: () => savedCount++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  Future<void> chooseSerialAndSave(
    WidgetTester tester,
    AppLocalizations l10n,
  ) async {
    final serial = find.byKey(const ValueKey('product_tracking_mode_serial'));
    await tester.ensureVisible(serial);
    await tester.tap(serial);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.saveProductButton));
    await tester.pumpAndSettle();
  }

  bool chipSelected(WidgetTester tester, String wire) => tester
      .widget<ChoiceChip>(find.byKey(ValueKey('product_tracking_mode_$wire')))
      .selected;

  testWidgets(
    'a stocked shelf is asked about once, then saved with the answer',
    (tester) async {
      answer = serverAsksAboutStock;
      final l10n = await pumpSheet(tester, product: buildProduct());

      await chooseSerialAndSave(tester, l10n);

      // One question, the one about the stock — not the plain change question
      // first and this one after it.
      expect(find.text(l10n.productTrackingChangeTitle), findsNothing);
      expect(
        find.byKey(const ValueKey('product_tracking_identify_later_dialog')),
        findsOne,
      );
      final body = l10n.productTrackingIdentifyLaterUnitsBody('3');
      expect(find.text(body), findsOne);
      // It names where the placeholders wait, in the words that screen uses.
      expect(body, contains(l10n.stockUnitsTitle));
      expect(body, contains(l10n.stockUnitsAwaitingIdentifier));
      // The question is not an error: nothing red behind the dialog.
      expect(
        find.byKey(const ValueKey('product_tracking_error')),
        findsNothing,
      );
      expect(find.text(l10n.productUpdateError), findsNothing);

      await tester.tap(find.text(l10n.productTrackingIdentifyLaterConfirm));
      await tester.pumpAndSettle();

      expect(patches, hasLength(2));
      expect(
        patches.first.containsKey('tracking_mode_identify_later'),
        isFalse,
      );
      expect(patches.last['tracking_mode_identify_later'], isTrue);
      expect(patches.last['tracking_mode'], 'serial');
      expect(savedCount, 1);
    },
  );

  testWidgets('declining leaves the product as it was and sends nothing more', (
    tester,
  ) async {
    answer = serverAsksAboutStock;
    final l10n = await pumpSheet(tester, product: buildProduct());

    await chooseSerialAndSave(tester, l10n);
    await tester.tap(find.text(l10n.cancelButton));
    await tester.pumpAndSettle();

    expect(patches, hasLength(1));
    expect(savedCount, 0);
    // Back on the mode that is actually in force.
    expect(chipSelected(tester, 'quantity'), isTrue);
    expect(chipSelected(tester, 'serial'), isFalse);
    expect(find.byKey(const ValueKey('product_tracking_error')), findsNothing);
  });

  testWidgets('an empty shelf keeps the plain change question', (tester) async {
    answer = (_) => json(savedProduct('serial'));
    final l10n = await pumpSheet(tester, product: buildProduct(onHand: 0));

    await chooseSerialAndSave(tester, l10n);

    expect(find.text(l10n.productTrackingChangeTitle), findsOne);
    await tester.tap(find.text(l10n.productTrackingChangeConfirm));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('product_tracking_identify_later_dialog')),
      findsNothing,
    );
    expect(patches.single.containsKey('tracking_mode_identify_later'), isFalse);
    expect(savedCount, 1);
  });

  testWidgets('a refusal no answer can fix lands under the choice', (
    tester,
  ) async {
    const reason =
        'الرصيد (2.5) ليس عددًا صحيحًا من القطع، والأصناف المسلسلة تُعدّ '
        'قطعة قطعة. صحّح الرصيد بجرد أو تسوية أولًا.';
    answer = (_) => json(const {
      'tracking_mode': [reason],
    }, 400);
    final l10n = await pumpSheet(tester, product: buildProduct(onHand: 2.5));

    await chooseSerialAndSave(tester, l10n);

    expect(
      find.byKey(const ValueKey('product_tracking_identify_later_dialog')),
      findsNothing,
    );
    expect(patches, hasLength(1));
    expect(find.text(reason), findsOne);
    expect(savedCount, 0);
  });
}

class _StubCatalogRepository extends CatalogRepository {
  _StubCatalogRepository(super.service, this._product);

  final Product _product;

  @override
  Future<Result<Product>> loadProduct(int id) async => Ok(_product);

  @override
  Future<Result<List<BoughtTogetherProduct>>> loadBoughtTogether(
    int productId, {
    int limit = 8,
  }) async => const Ok([]);
}

class _StubPurchaseRepository extends PurchaseRepository {
  _StubPurchaseRepository(super.service);

  @override
  Future<Result<List<VariantCostSummary>>> loadProductCostSummary(
    int productId,
  ) async => const Ok([]);
}

class _StubSaleRepository extends SaleRepository {
  _StubSaleRepository(super.service);
}
