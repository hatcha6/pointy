import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_draft_lines.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_line_entry_guide.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Entering a supplier's invoice from the keyboard alone: a line is walked
/// quantity ⏎ cost ⏎ expiry ⏎ and lands back on the search box, with no
/// mouse and no dialog. Real key events throughout — `enterText` writes a
/// controller and never proves a key reached anything.
void main() {
  const medicine = ProductVariant(
    id: 11,
    productId: 5,
    sku: 'MED-1',
    productName: 'مضاد حيوي',
    unitPrice: 10,
    trackingMode: TrackingMode.batch,
    expiryRequired: true,
  );
  const paper = ProductVariant(
    id: 12,
    productId: 6,
    sku: 'PAPER',
    productName: 'ورق',
    unitPrice: 3,
  );

  // Bought by the piece or by the carton of twelve.
  final water = ProductVariant(
    id: 13,
    productId: 7,
    sku: 'WTR',
    productName: 'ماء',
    unitPrice: 3,
    productDetail: Product(
      id: 7,
      name: 'ماء',
      quantityOnHand: 0,
      units: const [
        ProductUnit(
          unit: UnitOfMeasure(id: 1, code: 'carton', name: 'كرتونة'),
          factorToBase: 12,
        ),
      ],
    ),
  );

  late DateTime now;
  late int searchFocusRequests;

  Future<PurchaseViewModel> pumpLines(
    WidgetTester tester,
    List<ProductVariant> variants,
  ) async {
    now = DateTime(2026, 11, 1, 9);
    searchFocusRequests = 0;
    final viewModel = PurchaseViewModel(
      _FakeCatalogRepository(),
      _FakePurchaseRepository(),
    );
    viewModel.searchFocusController.addListener(() => searchFocusRequests++);
    for (final variant in variants) {
      await viewModel.addVariant(variant, source: 'test');
    }
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: viewModel,
            builder: (context, _) =>
                PurchaseDraftLines(viewModel: viewModel, clock: () => now),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return viewModel;
  }

  /// A person typing: a key, then a pause no scanner leaves.
  Future<void> typeKeys(
    WidgetTester tester,
    List<LogicalKeyboardKey> keys,
  ) async {
    for (final key in keys) {
      now = now.add(const Duration(milliseconds: 300));
      await tester.sendKeyEvent(key);
      await tester.pump();
    }
  }

  PurchaseLineEntryStep? guideStep(WidgetTester tester) => tester
      .widgetList<PurchaseLineEntryGuide>(find.byType(PurchaseLineEntryGuide))
      .firstOrNull
      ?.current;

  EditableText focusedField() => FocusManager.instance.primaryFocus!.context!
      .findAncestorWidgetOfExactType<EditableText>()!;

  testWidgets('quantity, cost and expiry, then back to the search box', (
    tester,
  ) async {
    final viewModel = await pumpLines(tester, [medicine]);
    viewModel.requestLineEntry(medicine.id);
    await tester.pumpAndSettle();

    await typeKeys(tester, [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
    ]);
    expect(find.textContaining('12'), findsWidgets);
    await typeKeys(tester, [LogicalKeyboardKey.enter]);
    await tester.pumpAndSettle();
    expect(viewModel.draft.single.quantity, 12);

    // Enter moved on to the cost, selected so the typed number replaces it.
    final cost = focusedField();
    expect(cost.controller.selection.extentOffset, cost.controller.text.length);
    tester.testTextInput.enterText('3.5');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
    expect(viewModel.draft.single.unitCost, 3.5);

    // ...then to the expiry, typed the way a foil prints it.
    expect(focusedField().controller, isNot(same(cost.controller)));
    tester.testTextInput.enterText('12/27');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final lot = viewModel.draft.single.batches.single;
    expect(lot.expiryDate, DateTime(2027, 12, 31));
    expect(lot.quantity, 12);
    expect(lot.code, isEmpty);
    expect(searchFocusRequests, greaterThan(0));
    expect(viewModel.selectedVariantId, isNull);
  });

  testWidgets('a line with nothing to date goes from its cost to the search', (
    tester,
  ) async {
    final viewModel = await pumpLines(tester, [paper]);
    viewModel.requestLineEntry(paper.id);
    await tester.pumpAndSettle();

    await typeKeys(tester, [LogicalKeyboardKey.enter]);
    await tester.pumpAndSettle();
    tester.testTextInput.enterText('2');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    expect(viewModel.draft.single.unitCost, 2);
    expect(searchFocusRequests, greaterThan(0));
  });

  testWidgets('Esc in a line field leaves the walk', (tester) async {
    final viewModel = await pumpLines(tester, [medicine]);
    viewModel.requestLineEntry(medicine.id);
    await tester.pumpAndSettle();
    await typeKeys(tester, [LogicalKeyboardKey.enter]);
    await tester.pumpAndSettle();
    expect(focusedField(), isNotNull);

    await typeKeys(tester, [LogicalKeyboardKey.escape]);
    await tester.pumpAndSettle();

    expect(viewModel.selectedVariantId, isNull);
    expect(searchFocusRequests, greaterThan(0));
  });

  testWidgets('a product bought in several units stops on its unit', (
    tester,
  ) async {
    final viewModel = await pumpLines(tester, [water]);
    viewModel.requestLineEntry(water.id);
    await tester.pumpAndSettle();
    expect(guideStep(tester), PurchaseLineEntryStep.quantity);

    await typeKeys(tester, [
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.enter,
    ]);
    await tester.pumpAndSettle();
    expect(viewModel.draft.single.quantity, 4);
    expect(guideStep(tester), PurchaseLineEntryStep.unit);

    // The arrows change the unit there, and the cost follows it.
    final before = viewModel.draft.single.unitFactor;
    await typeKeys(tester, [LogicalKeyboardKey.arrowDown]);
    await tester.pumpAndSettle();
    expect(viewModel.draft.single.unitFactor, isNot(before));
    expect(viewModel.draft.single.quantity, 4);
    await typeKeys(tester, [LogicalKeyboardKey.arrowUp]);
    await tester.pumpAndSettle();
    expect(viewModel.draft.single.unitFactor, before);

    await typeKeys(tester, [LogicalKeyboardKey.enter]);
    await tester.pumpAndSettle();
    expect(guideStep(tester), PurchaseLineEntryStep.cost);
    expect(focusedField(), isNotNull);
  });

  testWidgets('left and right flip the unit without leaving the quantity', (
    tester,
  ) async {
    final viewModel = await pumpLines(tester, [water]);
    viewModel.requestLineEntry(water.id);
    await tester.pumpAndSettle();
    final before = viewModel.draft.single.unitFactor;

    await typeKeys(tester, [LogicalKeyboardKey.arrowRight]);
    await tester.pumpAndSettle();

    expect(viewModel.draft.single.unitFactor, isNot(before));
    expect(guideStep(tester), PurchaseLineEntryStep.quantity);
  });

  testWidgets('up and down step between lines from the quantity', (
    tester,
  ) async {
    final viewModel = await pumpLines(tester, [paper, medicine]);
    // Newest first: the medicine is the top line.
    viewModel.requestLineEntry(medicine.id);
    await tester.pumpAndSettle();

    await typeKeys(tester, [LogicalKeyboardKey.arrowDown]);
    await tester.pumpAndSettle();
    expect(viewModel.selectedVariantId, paper.id);
    expect(guideStep(tester), PurchaseLineEntryStep.quantity);

    // The typed quantity lands on the line the arrow reached.
    await typeKeys(tester, [
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.enter,
    ]);
    await tester.pumpAndSettle();
    expect(
      viewModel.draft.firstWhere((l) => l.variant.id == paper.id).quantity,
      7,
    );

    await typeKeys(tester, [LogicalKeyboardKey.escape]);
    await tester.pumpAndSettle();
    viewModel.requestLineEntry(paper.id);
    await tester.pumpAndSettle();
    await typeKeys(tester, [LogicalKeyboardKey.arrowUp]);
    await tester.pumpAndSettle();
    expect(viewModel.selectedVariantId, medicine.id);
  });

  testWidgets('up and down inside a cost go down the column of costs', (
    tester,
  ) async {
    final viewModel = await pumpLines(tester, [paper, medicine]);
    viewModel.requestLineEntry(medicine.id);
    await tester.pumpAndSettle();
    await typeKeys(tester, [LogicalKeyboardKey.enter]);
    await tester.pumpAndSettle();
    final first = focusedField();
    expect(guideStep(tester), PurchaseLineEntryStep.cost);

    await typeKeys(tester, [LogicalKeyboardKey.arrowDown]);
    await tester.pumpAndSettle();

    final second = focusedField();
    expect(second.controller, isNot(same(first.controller)));
    expect(viewModel.selectedVariantId, paper.id);
    expect(guideStep(tester), PurchaseLineEntryStep.cost);
    tester.testTextInput.enterText('9');
    await tester.pump();
    expect(
      viewModel.draft.firstWhere((l) => l.variant.id == paper.id).unitCost,
      9,
    );

    await typeKeys(tester, [LogicalKeyboardKey.arrowUp]);
    await tester.pumpAndSettle();
    expect(focusedField().controller, same(first.controller));
    expect(viewModel.selectedVariantId, medicine.id);
  });

  testWidgets('the guide leaves with the walk', (tester) async {
    final viewModel = await pumpLines(tester, [paper]);
    expect(guideStep(tester), isNull);
    viewModel.requestLineEntry(paper.id);
    await tester.pumpAndSettle();
    expect(guideStep(tester), PurchaseLineEntryStep.quantity);

    await typeKeys(tester, [LogicalKeyboardKey.escape]);
    await tester.pumpAndSettle();
    expect(guideStep(tester), isNull);
  });

  testWidgets('a scanner burst never becomes the quantity', (tester) async {
    final viewModel = await pumpLines(tester, [paper]);
    viewModel.requestLineEntry(paper.id);
    await tester.pumpAndSettle();

    for (final key in [
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit9,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.enter,
    ]) {
      now = now.add(const Duration(milliseconds: 15));
      await tester.sendKeyEvent(key);
    }
    await tester.pumpAndSettle();

    expect(viewModel.draft.single.quantity, 1);
  });

  testWidgets('Page Down walks to the next line, newest first', (tester) async {
    final viewModel = await pumpLines(tester, [paper, medicine]);
    expect(viewModel.selectAdjacentLine(forward: true), isTrue);
    await tester.pumpAndSettle();
    final first = viewModel.selectedVariantId;
    expect(viewModel.selectAdjacentLine(forward: true), isTrue);
    await tester.pumpAndSettle();
    expect(viewModel.selectedVariantId, isNot(first));
    expect({first, viewModel.selectedVariantId}, {paper.id, medicine.id});
  });
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Error(Exception('product $id not found'));
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => const Ok(2);
}
